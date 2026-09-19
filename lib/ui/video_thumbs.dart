import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// 视频缩略图工具:
/// - Android/iOS/macOS: video_thumbnail 插件
/// - Windows: 尝试调用系统 ffmpeg 抽帧 (无 ffmpeg 则返回 null, 调用方回退到占位图标)
/// 结果按文件路径缓存; 缓存的是 Future, 同一路径的并发请求只抽一次帧
class VideoThumbs {
  static final Map<String, Future<Uint8List?>> _cache = {};

  static Future<Uint8List?> get(String path) {
    if (_cache.length > 200) _cache.clear(); // 兜底上限, 防常驻内存无限涨
    return _cache.putIfAbsent(path, () => _load(path));
  }

  static Future<Uint8List?> _load(String path) async {
    Uint8List? bytes;
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        // 不限尺寸会抽全分辨率帧, PNG 下 quality 无效, 200 条缓存直接 OOM;
        // 与 ffmpeg 路径一致缩到 320, JPEG 才能吃上 quality
        bytes = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 320,
          quality: 60,
        );
      } else {
        bytes = await _ffmpegFrame(path);
      }
    } catch (_) {
      bytes = null;
    }
    return bytes;
  }

  /// Windows: ffmpeg 抽第 1 秒帧
  static Future<Uint8List?> _ffmpegFrame(String path) async {
    final dir = await getTemporaryDirectory();
    // 临时名带 路径hash+文件长度: 纯 hashCode 碰撞时会错用他文件的帧
    final len = await File(path).length().catchError((_) => -1);
    if (len < 0) return null;
    final out =
        '${dir.path}${Platform.pathSeparator}cs_thumb_${path.hashCode.abs()}_$len.png';
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
