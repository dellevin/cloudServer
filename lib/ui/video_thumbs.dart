import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// 视频缩略图工具:
/// - Android/iOS/macOS: video_thumbnail 插件
/// - Windows: 尝试调用系统 ffmpeg 抽帧 (无 ffmpeg 则返回 null, 调用方回退到占位图标)
/// 结果按 路径+大小+修改时间 缓存 (同路径同名新文件不会错用旧帧);
/// 缓存的是 Future, 同一文件的并发请求只抽一次帧
class VideoThumbs {
  static final Map<String, Future<Uint8List?>> _cache = {};

  static Future<Uint8List?> get(String path) async {
    if (_cache.length > 200) _cache.clear(); // 兜底上限, 防常驻内存无限涨
    final st = await FileStat.stat(path);
    if (st.type != FileSystemEntityType.file) return null;
    final key = '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
    return _cache.putIfAbsent(key, () => _load(path));
  }

  static Future<Uint8List?> _load(String path) async {
    // 文件已不在 (传输记录里的旧文件被手动清理): 直接回退占位图,
    // 否则 Android 插件内部抛 FileNotFoundException 刷一屏堆栈日志
    if (!await File(path).exists()) return null;
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
    // 临时名带 路径hash+长度+mtime: 同路径同名新文件不会错用旧帧
    final st = await FileStat.stat(path);
    if (st.type != FileSystemEntityType.file) return null;
    final out =
        '${dir.path}${Platform.pathSeparator}cs_thumb_${path.hashCode.abs()}_${st.size}_${st.modified.millisecondsSinceEpoch}.png';
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
