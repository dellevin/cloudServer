import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../models.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';

/// 视频全屏播放页 (media_kit, 支持 Windows / Android)
/// 交互: 单击=显隐控制层 (3s 自动隐藏), 双击=播放/暂停,
/// 长按=2 倍速 (松手恢复), 拖动进度条实时 seek + 目标时间气泡,
/// 缓冲中画面中央转圈
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  bool _ready = false;

  bool _controlsVisible = true;
  Timer? _hideTimer;

  bool _fastForward = false; // 长按倍速中
  static const _ffRate = 2.0;

  Duration? _dragTarget; // 拖动进度条时的目标位置 (松手前不进 player)
  bool _dragging = false;

  String? _streamTid; // 远程流式预览的会话 id (退出时断流删缓存)
  RelayClient? _client;

  // 流式预览中点「下载」另起的整文件传输状态
  bool _downloading = false;
  int _dlSince = 0; // 拉取发起时间 (毫秒), 匹配本次传输用
  bool _dlHandled = true; // 防多帧 build 重复调度落盘/toast

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _armHideTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final (path, _, streamTid) = parseViewerArgs(
      ModalRoute.of(context)!.settings.arguments,
    );
    _streamTid = streamTid;
    if (streamTid != null) _client = context.read<RelayClient>();
    _player.open(Media(path));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // 退出时恢复常速, 防 player 析构时还带着 2x (流回调乱序)
    _player.setRate(1.0);
    _player.dispose();
    // 流式预览: 先停播放器 (HTTP 读取中断), 再关会话断流删缓存
    final st = _streamTid;
    final c = _client;
    if (st != null && c != null) unawaited(c.fsStreamClose(st));
    super.dispose();
  }

  /// 3 秒无操作自动隐藏控制层
  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_dragging) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _armHideTimer();
  }

  void _startFastForward() {
    if (_fastForward) return;
    setState(() => _fastForward = true);
    _player.setRate(_ffRate);
  }

  void _stopFastForward() {
    if (!_fastForward) return;
    setState(() => _fastForward = false);
    _player.setRate(1.0);
  }

  static String _fmtTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 流式预览中的「下载」: 按原路径另起一整文件传输 (免确认拉取存缓存),
  /// 完成后由 _watchDownload 复制到下载目录真正落盘
  void _startDownload(RelayClient c) {
    final st = _streamTid;
    if (st == null || _downloading) return;
    if (!c.fsStreamDownload(st)) {
      AppToast.show(context, tr('fs_offline'));
      return;
    }
    setState(() {
      _downloading = true;
      _dlHandled = false;
      _dlSince = DateTime.now().millisecondsSinceEpoch;
    });
  }

  /// 找本次下载对应的传入传输记录 (发起后新建的最新一条)
  FileTransfer? _dlTransfer(RelayClient c) {
    final st = _streamTid;
    if (st == null) return null;
    final s = c.streamSession(st);
    if (s == null) return null;
    for (final t in c.transfers.reversed) {
      if (!t.outgoing &&
          t.peerId == s.peerId &&
          t.fileName == s.name &&
          t.ts >= _dlSince) {
        return t;
      }
    }
    return null;
  }

  /// 盯下载传输状态: 完成落盘, 失败提示; build 中调用 (传输变更触发),
  /// 状态清理推到帧后, 避免 build 期 setState
  void _watchDownload(RelayClient c) {
    if (!_downloading || _dlHandled) return;
    final t = _dlTransfer(c);
    if (t == null) return;
    if (t.status == TransferStatus.done && t.savePath != null) {
      _dlHandled = true;
      final src = t.savePath!;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // 复制到下载目录 = 真正落盘 (自带已保存提示)
        await downloadTempPreview(context, src);
        if (!mounted) return;
        setState(() => _downloading = false);
      });
    } else if (t.status == TransferStatus.failed ||
        t.status == TransferStatus.canceled ||
        t.status == TransferStatus.rejected) {
      _dlHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _downloading = false);
        AppToast.show(context, tr('st_failed'));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final (path, tempPreview, _) = parseViewerArgs(
      ModalRoute.of(context)!.settings.arguments,
    );
    final c = context.watch<RelayClient>();
    _watchDownload(c);
    // 流式 URL 的路径段是 tid/token, 真实文件名放在 query 里
    var name = path.split(RegExp(r'[\\/]')).last;
    if (path.startsWith('http')) {
      final qn = Uri.tryParse(path)?.queryParameters['n'];
      if (qn != null && qn.isNotEmpty) name = qn;
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTap: () => _player.playOrPause(),
        onLongPressStart: (_) => _startFastForward(),
        onLongPressEnd: (_) => _stopFastForward(),
        onLongPressCancel: _stopFastForward,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 画面 (缩放会穿透手势, 手势层放 Stack 外层);
            // controls: null 关掉 media_kit 自带的进度条, 用我们自己的控制层
            Center(
              child: Video(
                controller: _controller,
                fit: BoxFit.contain,
                controls: null,
              ),
            ),
            // 缓冲指示
            StreamBuilder<bool>(
              stream: _player.stream.buffering,
              initialData: _player.state.buffering,
              builder: (_, snap) => snap.data == true
                  ? const Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white70,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            // 长按倍速提示 (顶部胶囊)
            if (_fastForward)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 16,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${_ffRate.toStringAsFixed(0)}x',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              ),
            // 控制层 (顶栏 + 底栏), 3s 自动隐藏; 拖动进度条时不隐藏
            if (_controlsVisible) ...[
              // 顶栏: 返回 + 文件名
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Expanded(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        // 远程浏览的临时预览: 「下载」复制到下载目录真正落盘
                        if (tempPreview)
                          IconButton(
                            tooltip: tr('download'),
                            icon: const Icon(
                              Icons.save_alt,
                              color: Colors.white,
                            ),
                            onPressed: () =>
                                downloadTempPreview(context, path),
                          ),
                        // 流式预览: 「下载」按原路径另起整文件传输, 完成后落盘;
                        // 传输中图标换成进度环 (订阅轻量 tick, 不整页重建)
                        if (_streamTid != null)
                          _downloading
                              ? Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: ValueListenableBuilder<int>(
                                    valueListenable: c.progressTick,
                                    builder: (_, _, _) => SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        value: () {
                                          final p =
                                              _dlTransfer(c)?.progress ?? 0.0;
                                          return p > 0 ? p : null;
                                        }(),
                                        strokeWidth: 2,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                )
                              : IconButton(
                                  tooltip: tr('download'),
                                  icon: const Icon(
                                    Icons.save_alt,
                                    color: Colors.white,
                                  ),
                                  onPressed: () => _startDownload(c),
                                ),
                      ],
                    ),
                  ),
                ),
              ),
              // 底栏: 播放/暂停 + 进度 + 时间
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 24, 16, 0),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        StreamBuilder<bool>(
                          stream: _player.stream.playing,
                          initialData: _player.state.playing,
                          builder: (_, snap) => IconButton(
                            icon: Icon(
                              snap.data == true
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              size: 36,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              _player.playOrPause();
                              _armHideTimer();
                            },
                          ),
                        ),
                        Expanded(
                          child: StreamBuilder<Duration>(
                            stream: _player.stream.position,
                            initialData: _player.state.position,
                            builder: (_, posSnap) =>
                                StreamBuilder<Duration>(
                                  stream: _player.stream.duration,
                                  initialData: _player.state.duration,
                                  builder: (_, durSnap) {
                                    final pos = posSnap.data ?? Duration.zero;
                                    final dur = durSnap.data ?? Duration.zero;
                                    final max = dur.inMilliseconds.toDouble();
                                    // 拖动中显示拖到的目标位置, 松开才真正 seek
                                    final shown = _dragTarget ?? pos;
                                    return Row(
                                      children: [
                                        Expanded(
                                          child: Slider(
                                            value: max > 0
                                                ? shown.inMilliseconds
                                                      .toDouble()
                                                      .clamp(0, max)
                                                : 0,
                                            max: max > 0 ? max : 1,
                                            onChangeStart: max > 0
                                                ? (_) => setState(
                                                    () => _dragging = true,
                                                  )
                                                : null,
                                            // 拖动中实时 seek (media_kit seek 开销小)
                                            onChanged: max > 0
                                                ? (v) {
                                                    final target = Duration(
                                                      milliseconds: v.round(),
                                                    );
                                                    setState(
                                                      () =>
                                                          _dragTarget = target,
                                                    );
                                                    _player.seek(target);
                                                  }
                                                : null,
                                            onChangeEnd: max > 0
                                                ? (_) {
                                                    setState(() {
                                                      _dragging = false;
                                                      _dragTarget = null;
                                                    });
                                                    _armHideTimer();
                                                  }
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${_fmtTime(shown)} / ${_fmtTime(dur)}',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11.5,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
