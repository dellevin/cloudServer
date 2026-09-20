/// 冒烟测试: 流式预览 (v5) 播放侧的稀疏缓存 + 拉取调度 + HTTP Range 服务
/// 用法: dart run tool/stream_smoke.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/stream_server.dart';

/// 造一个带规律的假远程文件内容 (1MB + 100B: 4 整块 + 1 尾块, 跨 2 组)
final int size = kStreamGroup + 100;
late final Uint8List source = Uint8List.fromList(
  List.generate(size, (i) => i % 251),
);

/// 模拟宿主: 记录请求, 异步按块回帧 (组内乱序, 验证偏移寻址而非顺序假设)
class FakeHost {
  final StreamSession session;
  final List<(int, int)> reqs = [];
  FakeHost(this.session);
  void onReq(int offset, int length) {
    reqs.add((offset, length));
    // 组内倒序投递, 模拟跨通道乱序
    final frames = <(int, Uint8List)>[];
    var off = offset;
    final end = offset + length;
    while (off < end) {
      final n =
          off + kStreamBlock <= end ? kStreamBlock : end - off;
      frames.add((off, Uint8List.sublistView(source, off, off + n)));
      off += n;
    }
    for (final f in frames.reversed) {
      unawaited(Future(() => session.onFrame(f.$1, f.$2)));
    }
  }
}

void main() async {
  final results = <(String, bool)>[];
  final dir = await Directory.systemTemp.createTemp('stream_smoke');

  Future<StreamSession> newSession(String name) async {
    late StreamSession s;
    s = StreamSession(
      tid: 't' * 36,
      peerId: 'peer',
      name: name,
      path: '/fake/$name',
      size: size,
      file: File('${dir.path}${Platform.pathSeparator}$name.cache'),
      token: 'tok',
      sendReq: (o, l, p) => FakeHost(s).onReq(o, l),
      sendSkip: (_) {},
    );
    return s;
  }

  // ---- T1: 缺块请求 -> 到齐后可读, 内容正确 ----
  {
    final s = await newSession('t1');
    await s.ensureRange(0, kStreamBlock); // 触发组0请求并等到齐
    final data = await s.readAt(0, kStreamBlock);
    var ok = data.length == kStreamBlock;
    for (var i = 0; ok && i < 1000; i++) {
      ok = data[i] == source[i];
    }
    results.add(('T1 缺块拉取后内容正确', ok));
    await s.close();
  }

  // ---- T2: 尾块/尾组: 部分块也算齐, 内容正确 ----
  {
    final s = await newSession('t2');
    await s.ensureRange(kStreamGroup, 100); // 尾块 (组1, 仅 100B)
    final data = await s.readAt(kStreamGroup, 100);
    var ok = data.length == 100;
    for (var i = 0; ok && i < 100; i++) {
      ok = data[i] == source[kStreamGroup + i];
    }
    results.add(('T2 尾块拉取内容正确', ok));
    await s.close();
  }

  // ---- T3: 预读去重: 同一组重复 prefetch 只发一次请求 ----
  {
    late final StreamSession s;
    final reqs = <(int, int)>[];
    s = StreamSession(
      tid: 't' * 36,
      peerId: 'peer',
      name: 't3',
      path: '/fake/t3',
      size: size,
      file: File('${dir.path}${Platform.pathSeparator}t3.cache'),
      token: 'tok',
      sendReq: (o, l, p) {
        reqs.add((o, l));
        // 不投递: 只验证请求去重
      },
      sendSkip: (_) {},
    );
    s.prefetch(0, kStreamGroup * 2);
    s.prefetch(0, kStreamGroup * 2);
    s.prefetch(kStreamBlock, kStreamGroup * 2);
    results.add(('T3 预读请求去重', reqs.length == 2));
    await s.close(error: true);
  }

  // ---- T4: 畸形帧 (非块对齐/长度不符) 被拒, 不污染缓存 ----
  {
    final s = await newSession('t4');
    s.onFrame(123, Uint8List(10)); // 非块对齐
    s.onFrame(0, Uint8List(10)); // 长度不符 (块0应 256KB)
    await Future.delayed(const Duration(milliseconds: 50));
    // 只有畸形帧 -> 缓存文件不应被创建 (RAF 只在有效帧到达时懒开)
    results.add(('T4 畸形帧被拒不落盘', !await s.file.exists()));
    await s.close();
  }

  // ---- T5: HTTP Range 端到端: 206 + Content-Range + 字节正确 ----
  {
    final s = await newSession('t5');
    final http = StreamHttpServer();
    final url = await http.mount(s);
    final start = kStreamBlock; // 跨组请求 (组0 的块1)
    final end = kStreamBlock + 999;
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('range', 'bytes=$start-$end');
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    final ok =
        res.statusCode == 206 &&
        res.headers.value('content-range') == 'bytes $start-$end/$size' &&
        body.length == end - start + 1 &&
        () {
          for (var i = 0; i < body.length; i++) {
            if (body[i] != source[start + i]) return false;
          }
          return true;
        }();
    results.add(('T5 HTTP Range 端到端', ok));
    client.close();
    await s.close();
    await http.dispose();
  }

  // ---- T6: 会话关闭: 等待者报错放行, 缓存文件删除 ----
  {
    late final StreamSession s;
    s = StreamSession(
      tid: 't' * 36,
      peerId: 'peer',
      name: 't6',
      path: '/fake/t6',
      size: size,
      file: File('${dir.path}${Platform.pathSeparator}t6.cache'),
      token: 'tok',
      sendReq: (o, l, p) {}, // 永不投递
      sendSkip: (_) {},
    );
    final waiting = s.ensureRange(0, kStreamBlock);
    var errored = false;
    unawaited(waiting.catchError((_) => errored = true));
    await Future.delayed(const Duration(milliseconds: 20));
    await s.close(error: true);
    await Future.delayed(const Duration(milliseconds: 50));
    results.add(('T6 关闭报错放行+删缓存', errored && !await s.file.exists()));
  }

  // ---- T7: 急需升级: 预读在途的组, ensureRange 仍发请求且带优先级 ----
  {
    late final StreamSession s;
    final reqs = <(int, int, bool)>[];
    s = StreamSession(
      tid: 't' * 36,
      peerId: 'peer',
      name: 't7',
      path: '/fake/t7',
      size: size,
      file: File('${dir.path}${Platform.pathSeparator}t7.cache'),
      token: 'tok',
      sendReq: (o, l, p) {
        reqs.add((o, l, p));
        // 不投递: 只验证升级请求
      },
      sendSkip: (_) {},
    );
    s.prefetch(0, kStreamGroup); // 预读发起组0 (非急需)
    final waiting = s.ensureRange(0, kStreamBlock); // 组0在途, 应再发急需
    unawaited(waiting.catchError((_) {}));
    await Future.delayed(const Duration(milliseconds: 20));
    final ok =
        reqs.length == 2 &&
        reqs[0] == (0, kStreamGroup, false) &&
        reqs[1] == (0, kStreamGroup, true);
    results.add(('T7 急需升级提队首', ok));
    await s.close(error: true);
  }

  // ---- T8: 跨组界的非对齐 Range: 切片不跨块界, 读不到邻组空洞 ----
  // (回归: seek 到组末块中间时, 旧切片会跨进未拉取的邻组, 响应截断/坏数据)
  {
    final s = await newSession('t8');
    final http = StreamHttpServer();
    final url = await http.mount(s);
    // 起点在组0最后一块的中间, 一直读到文件尾 (跨组界进组1)
    final start = kStreamGroup - kStreamBlock + 1000;
    final end = size - 1;
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('range', 'bytes=$start-$end');
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    var ok = res.statusCode == 206 && body.length == end - start + 1;
    for (var i = 0; ok && i < body.length; i++) {
      ok = body[i] == source[start + i];
    }
    results.add(('T8 跨组界非对齐读无坏数据', ok));
    client.close();
    await s.close();
    await http.dispose();
  }

  await dir.delete(recursive: true);
  var allOk = true;
  for (final (name, ok) in results) {
    print('${ok ? "PASS" : "FAIL"} $name');
    allOk = allOk && ok;
  }
  exit(allOk ? 0 : 1);
}
