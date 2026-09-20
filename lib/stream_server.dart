import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 远程视频流式预览 (协议 v5, 接收/播放侧):
/// 远程浏览页点开视频时不起整文件传输, 而是把远程文件映射成只绑回环的
/// 本地 HTTP 流交给播放器 (media_kit/mpv)。播放器的 Range 请求落到哪个
/// 字节区间, 就向对端拉哪个区间 (fs_stream_req), 写进稀疏缓存文件复用。
/// 任意拖动 = 新 Range 请求 = 改拉对应区间; mpv 开播前会主动探文件尾,
/// 因此 moov 后置的 MP4 也能立即开播 (顺序整文件传输做不到这一点)。
///
/// 数据帧格式: 36 字节 streamId + 8 字节大端偏移 + 负载 (一帧恰好一块),
/// 帧自带偏移因此跨通道乱序无害; 拉取由播放节奏驱动 (pull), 不需要
/// 文件传输那套窗口背压。缓存只活在会话期间, 播放器关闭即删。

/// 拉取块大小: 与文件传输分块一致 (服务器/局域网帧上限内)
const int kStreamBlock = 256 * 1024;

/// 一次 fs_stream_req 拉取的字节数 (4 块 = 1MB)
const int kStreamGroup = 4 * kStreamBlock;

/// 播放点之后的预读量 (播放器停顿 = HTTP 读取停顿, 预读随之自然停止)
const int kStreamReadAhead = 8 * 1024 * 1024;

/// 等一个组到齐的超时 (超时后该组可重新请求)
const Duration kStreamTimeout = Duration(seconds: 30);

/// 一次流式预览会话的稀疏缓存与拉取调度 (浏览器/播放侧)
class StreamSession {
  final String tid;
  final String peerId;
  final String name;

  /// 对端原始路径 (播放中点「下载」时按它另起一整文件传输)
  final String path;
  final int size;
  final File file; // 稀疏缓存文件
  final String token; // URL 凭证, 防本机其他进程蹭读

  /// 向对端请求 [offset, offset+length) 区间; priority=true 表示急需
  /// (播放点/seek 目标), 对端提到队首, false = 预读排队尾
  final void Function(int offset, int length, bool priority) sendReq;

  /// 通知对端丢弃完全早于 before 的排队请求 (大跨度 seek 时省带宽)
  final void Function(int before) sendSkip;

  RandomAccessFile? _raf;
  late final Uint8List _bitmap = Uint8List(_blockCount); // 块位图
  final Map<int, Completer<void>> _groupWaiters = {}; // 组号 -> 到齐信号
  final Set<int> _reqPending = {}; // 已请求未收齐的组号
  Future<void> _ioChain = Future<void>.value(); // RAF 读写串行链
  bool closed = false;

  /// 已向播放器送出的最大字节位置 (大跨度 seek 判定的参照点)
  int maxServed = 0;

  /// 挂到本地 HTTP 服务后的播放地址 (mount 时回填)
  String url = '';

  StreamSession({
    required this.tid,
    required this.peerId,
    required this.name,
    required this.path,
    required this.size,
    required this.file,
    required this.token,
    required this.sendReq,
    required this.sendSkip,
  });

  int get _blockCount => (size + kStreamBlock - 1) ~/ kStreamBlock;
  int _blockLen(int b) => min(kStreamBlock, size - b * kStreamBlock);
  int get _groupCount => (size + kStreamGroup - 1) ~/ kStreamGroup;
  int _groupLen(int g) => min(kStreamGroup, size - g * kStreamGroup);

  bool _groupComplete(int g) {
    final b0 = g * (kStreamGroup ~/ kStreamBlock);
    final b1 = min(b0 + (kStreamGroup ~/ kStreamBlock), _blockCount);
    for (var b = b0; b < b1; b++) {
      if (_bitmap[b] == 0) return false;
    }
    return true;
  }

  Completer<void> _waiter(int g) => _groupWaiters.putIfAbsent(g, () {
    final w = Completer<void>();
    // 预读创建的等待者可能无人 await, 挂个吞错监听防 unhandled
    unawaited(w.future.catchError((_) {}));
    return w;
  });

  /// 保证 [pos, pos+len) 已落到缓存 (len <= kStreamBlock, 即单块内);
  /// 缺则请求并等到齐, 超时/会话关闭抛异常 (调用方中断 HTTP 响应)
  Future<void> ensureRange(int pos, int len) async {
    final b = pos ~/ kStreamBlock;
    if (_bitmap[b] == 1) return;
    if (closed) throw StateError('stream closed');
    final g = b ~/ (kStreamGroup ~/ kStreamBlock);
    final w = _waiter(g);
    // 急需请求总是发送: 组已在途 (预读发起) 时让对端把它提到队首,
    // 否则 seek 目标排在旧位置的预读 backlog 后面, 长时间卡缓冲
    _reqPending.add(g);
    sendReq(g * kStreamGroup, _groupLen(g), true);
    try {
      await w.future.timeout(kStreamTimeout);
    } on TimeoutException {
      _reqPending.remove(g); // 允许后续重试
      rethrow;
    }
    if (closed) throw StateError('stream closed');
    if (_bitmap[b] == 0) throw StateError('block missing');
  }

  /// 后台预读 [fromByte, toByte) 覆盖的组 (已齐/在途自动去重)
  void prefetch(int fromByte, int toByte) {
    if (closed) return;
    final gEnd = min(toByte, size);
    for (
      var g = fromByte ~/ kStreamGroup;
      g * kStreamGroup < gEnd && g < _groupCount;
      g++
    ) {
      if (_groupComplete(g) || !_reqPending.add(g)) continue;
      _waiter(g);
      sendReq(g * kStreamGroup, _groupLen(g), false);
    }
  }

  /// 对端数据帧到达: 写入稀疏文件并标记块 (一帧恰好一块, 帧自带偏移)
  void onFrame(int offset, Uint8List data) {
    if (closed) return;
    final b = offset ~/ kStreamBlock;
    // 非块对齐/长度不符的帧是异常对端发的, 丢弃 (不写坏缓存)
    if (b >= _blockCount || offset != b * kStreamBlock) return;
    if (data.length != _blockLen(b)) return;
    _ioChain = _ioChain.then((_) async {
      try {
        final raf = await _openRaf();
        await raf.setPosition(offset);
        await raf.writeFrom(data);
        _bitmap[b] = 1;
        final g = b ~/ (kStreamGroup ~/ kStreamBlock);
        if (_groupComplete(g)) {
          _reqPending.remove(g);
          final w = _groupWaiters.remove(g);
          if (w != null && !w.isCompleted) w.complete();
        }
      } catch (_) {}
    });
  }

  /// 读缓存区间 (与写入同一条串行链, 保证读到最新落盘内容)
  Future<Uint8List> readAt(int pos, int len) {
    final c = Completer<Uint8List>();
    _ioChain = _ioChain.then((_) async {
      try {
        final raf = await _openRaf();
        await raf.setPosition(pos);
        c.complete(await raf.read(len));
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }

  Future<RandomAccessFile> _openRaf() async =>
      _raf ??= await file.open(mode: FileMode.write);

  /// 关闭会话: 等待者全部放行 (error=true 时报错), 关句柄删缓存
  Future<void> close({bool error = false}) async {
    if (closed) return;
    closed = true;
    for (final w in _groupWaiters.values) {
      if (w.isCompleted) continue;
      if (error) {
        w.completeError(StateError('stream closed'));
      } else {
        w.complete();
      }
    }
    _groupWaiters.clear();
    _reqPending.clear();
    await _ioChain.then((_) async {
      try {
        await _raf?.close();
      } catch (_) {}
      _raf = null;
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });
  }
}

/// 只绑回环的 HTTP 服务: 把各流式会话的稀疏缓存按 Range 提供给播放器
class StreamHttpServer {
  HttpServer? _server;
  final Map<String, StreamSession> sessions = {}; // tid -> 会话

  /// 登记会话并返回播放 URL (服务惰性启动)
  Future<String> mount(StreamSession s) async {
    if (_server == null) {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_handle);
    }
    sessions[s.tid] = s;
    // 文件名放 query 里: HTTP 处理只看路径段, 播放页从 query 取真实文件名显示
    return 'http://127.0.0.1:${_server!.port}/s/${s.tid}/${s.token}'
        '?n=${Uri.encodeComponent(s.name)}';
  }

  void unmount(String tid) => sessions.remove(tid);

  static final _rangeRe = RegExp(r'bytes=(\d*)-(\d*)');

  void _handle(HttpRequest req) {
    () async {
      final res = req.response;
      Future<void> reject(int code) async {
        res.statusCode = code;
        await res.close();
      }

      final segs = req.uri.pathSegments;
      if ((req.method != 'GET' && req.method != 'HEAD') ||
          segs.length != 3 ||
          segs[0] != 's') {
        await reject(404);
        return;
      }
      final s = sessions[segs[1]];
      if (s == null || s.closed || s.token != segs[2]) {
        await reject(404);
        return;
      }
      // Range 解析 (单区间; 无 Range 视为从头开始的完整 GET)
      final size = s.size;
      var start = 0;
      var end = size - 1;
      var partial = false;
      final rh = req.headers.value('range');
      if (rh != null) {
        final m = _rangeRe.firstMatch(rh);
        if (m != null) {
          partial = true;
          if (m.group(1)!.isEmpty) {
            final n = int.tryParse(m.group(2)!) ?? 0; // 尾部 N 字节
            start = n >= size ? 0 : size - n;
          } else {
            start = int.tryParse(m.group(1)!) ?? 0;
            if (m.group(2)!.isNotEmpty) {
              end = min(int.parse(m.group(2)!), size - 1);
            }
          }
        }
      }
      if (start < 0 || start >= size || start > end) {
        res.statusCode = 416;
        res.headers.set('Content-Range', 'bytes */$size');
        await res.close();
        return;
      }
      // 向前大跨度 seek: 让对端丢弃排在旧播放点之前的排队请求
      if (start > s.maxServed + 32 * 1024 * 1024) s.sendSkip(start);
      res.statusCode = partial ? 206 : 200;
      res.headers.set('Accept-Ranges', 'bytes');
      res.headers.set('Content-Type', _mimeOf(s.name));
      res.headers.contentLength = end - start + 1;
      if (partial) res.headers.set('Content-Range', 'bytes $start-$end/$size');
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      try {
        var pos = start;
        while (pos <= end && !s.closed) {
          // 切片绝不跨块界: ensureRange 只保证首块在缓存, 跨块会读到邻组
          // 还没拉到的空洞 — 稀疏文件空洞短读 (响应截断) 或补零 (坏数据),
          // 播放器都按流结束处理 (seek 后跳到结尾就是这个引起的)
          final pieceLen = min(
            kStreamBlock - pos % kStreamBlock,
            end - pos + 1,
          );
          await s.ensureRange(pos, pieceLen); // 缺块则等拉取到齐
          if (s.closed) break;
          res.add(await s.readAt(pos, pieceLen));
          await res.flush(); // 背压: 播放器读多快就拉多快
          pos += pieceLen;
          if (pos > s.maxServed) s.maxServed = pos;
          // 预读播放点之后一段 (去重后近乎无成本; 播放器暂停则此处自然停)
          s.prefetch(pos, pos + kStreamReadAhead);
        }
        await res.close();
      } catch (_) {
        // 拉取超时/会话关闭/播放器断开: 提前关响应 (已声明的 Content-Length
        // 未写满, 播放器按截断处理 — 自会重连或报错)
        try {
          await res.close();
        } catch (_) {}
      }
    }();
  }

  static String _mimeOf(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    return switch (ext) {
      'mp4' || 'm4v' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'avi' => 'video/x-msvideo',
      'mov' => 'video/quicktime',
      'ts' || 'm2ts' => 'video/mp2t',
      'flv' => 'video/x-flv',
      '3gp' => 'video/3gpp',
      'wmv' => 'video/x-ms-wmv',
      _ => 'application/octet-stream',
    };
  }

  Future<void> dispose() async {
    await _server?.close();
    _server = null;
  }
}
