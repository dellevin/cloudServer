import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频全屏播放页 (media_kit, 支持 Windows / Android)
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final path = ModalRoute.of(context)!.settings.arguments as String;
    _player.open(Media(path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  static String _fmtTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final path = ModalRoute.of(context)!.settings.arguments as String;
    final name = path.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, style: const TextStyle(fontSize: 14)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Video(controller: _controller, fit: BoxFit.contain),
            ),
          ),
          // 控制条: 播放/暂停 + 进度 + 时间
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
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
                      onPressed: () => _player.playOrPause(),
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
                              return Row(
                                children: [
                                  Expanded(
                                    child: Slider(
                                      value: max > 0
                                          ? pos.inMilliseconds
                                                .toDouble()
                                                .clamp(0, max)
                                          : 0,
                                      max: max > 0 ? max : 1,
                                      onChanged: max > 0
                                          ? (v) => _player.seek(
                                              Duration(
                                                milliseconds: v.round(),
                                              ),
                                            )
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_fmtTime(pos)} / ${_fmtTime(dur)}',
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
        ],
      ),
    );
  }
}
