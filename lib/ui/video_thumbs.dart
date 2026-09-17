import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// 视频缩略图工具:
/// - Android/iOS/macOS: video_thumbnail 插件
/// - Windows: 尝试调用系统 ffmpeg 抽帧 (无 ffmpeg 则返回 null, 调用方回退到占位图标)
/// 结果按文件路径缓存
class VideoThumbs {
  static final Map<String, Uint8List?> _cache = {};

  static Future<Uint8List?> get(String path) async {
    if (_cache.containsKey(path)) return _cache[path];
    Uint8List? bytes;
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        bytes = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.PNG,
          quality: 60,
        );
      } else {
        bytes = await _ffmpegFrame(path);
      }
    } catch (_) {
      bytes = null;
    }
    _cache[path] = bytes;
    return bytes;
  }

  /// Windows: ffmpeg 抽第 1 秒帧
  static Future<Uint8List?> _ffmpegFrame(String path) async {
    final dir = await getTemporaryDirectory();
    final out =
        '${dir.path}${Platform.pathSeparator}cs_thumb_${path.hashCode.abs()}.png';
    final f = File(out);
    if (await f.exists() && await f.length() > 0) return await f.readAsBytes();
    final r = await Process.run('ffmpeg', [
      '-y',
      '-ss',
      '1',
      '-i',
      path,
      '-frames:v',
      '1',
      '-vf',
      'scale=320:-1',
      out,
    ]);
    if (r.exitCode != 0 || !await f.exists()) return null;
    return await f.readAsBytes();
  }
}
