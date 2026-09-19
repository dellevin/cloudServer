import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../l10n.dart';
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
    final (path, _) = parseViewerArgs(
      ModalRoute.of(context)!.settings.arguments,
    );
    _player.open(Media(path));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // 退出时恢复常速, 防 player 析构时还带着 2x (流回调乱序)
    _player.setRate(1.0);
    _player.dispose();
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

  @override
  Widget build(BuildContext context) {
    final (path, tempPreview) = parseViewerArgs(
      ModalRoute.of(context)!.settings.arguments,
    );
    final name = path.split(RegExp(r'[\\/]')).last;
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
