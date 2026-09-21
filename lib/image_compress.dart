/// Luban 图片压缩算法的 Dart 移植 (参考 top.zibin.luban 的
/// CompressionCalculator / JpegCompressor):
///
/// 尺寸阶梯:
///  - 短边基准 1440, 按比例推长边; 长边 >= 10800 且比例 > 0.4 的巨图反过来定长边
///  - 像素 > 4096万 触发 trap (短边 0.25x); 最终像素封顶 1024万
/// 编码策略:
///  - 普通图 (短边/长边 > 0.5): 固定 JPEG 质量 60
///  - 长图 (比例 <= 0.5): 按目标像素估算大小, 二分质量 5..95 逼近目标
///  - 压缩结果不小于原文件 → 返回 null (调用方回退发原图)
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:image/image.dart' as img;

/// 压缩结果: 输出路径 + 原图字节数 + 压缩后字节数
typedef LubanResult = ({String path, int origBytes, int newBytes});

class _Target {
  final int width;
  final int height;
  final int estimatedSizeKb;
  final bool isLongImage;
  final int? targetSizeKb;
  _Target(
    this.width,
    this.height,
    this.estimatedSizeKb,
    this.isLongImage,
    this.targetSizeKb,
  );
}

/// CompressionCalculator.calculateTarget 的逐行等价实现
_Target _calcTarget(int width, int height) {
  if (width <= 0 || height <= 0) return _Target(0, 0, 0, false, null);
  const baseShort = 1440;
  const wallLong = 10800;
  const wallRatio = 0.4;
  const trapPixels = 40960000;
  const capPixels = 10240000;

  final shortSide = min(width, height);
  final longSide = max(width, height);
  final ratio = shortSide / longSide;
  final pixelCount = width * height;

  var targetShort = baseShort;
  var targetLong = (targetShort / ratio).toInt();

  if (longSide >= wallLong && ratio > wallRatio) {
    targetLong = baseShort;
    targetShort = (targetLong * ratio).toInt();
  }

  if (pixelCount > trapPixels) {
    final trapShort = (shortSide * 0.25).toInt();
    if (trapShort < targetShort) {
      targetShort = trapShort;
      targetLong = (targetShort / ratio).toInt();
    }
  }

  if (targetShort > shortSide) {
    targetShort = shortSide;
    targetLong = longSide;
  }

  final currentPixels = targetShort * targetLong;
  if (currentPixels > capPixels) {
    final scale =
        (sqrt(capPixels / currentPixels) * 1000).floorToDouble() / 1000.0;
    targetShort = (targetShort * scale).toInt();
    targetLong = (targetLong * scale).toInt();
  }

  targetShort = (targetShort ~/ 2) * 2;
  targetLong = (targetLong ~/ 2) * 2;
  targetShort = max(2, targetShort);
  targetLong = max(2, targetLong);

  final (finalW, finalH) = width < height
      ? (targetShort, targetLong)
      : (targetLong, targetShort);
  final finalPixels = finalW * finalH;

  final factor = finalPixels < 500000
      ? 0.0005
      : finalPixels < 1000000
      ? 0.00015
      : finalPixels < 3000000
      ? 0.00011
      : 0.000025;

  var estimated = (finalPixels * factor).toInt();
  estimated = max(20, estimated);
  if (ratio < 0.2 && estimated < 400) {
    estimated = max(estimated, 250);
  }

  final isLong = ratio <= 0.5;
  return _Target(finalW, finalH, estimated, isLong, isLong ? estimated : null);
}

/// JpegCompressor: 普通图固定 q60; 长图先试 q95, 超目标则二分 5..95 找最优
List<int> _compressJpg(img.Image im, int? targetSizeKb) {
  if (targetSizeKb == null) {
    return img.encodeJpg(im, quality: 60);
  }
  final q95 = img.encodeJpg(im, quality: 95);
  if (q95.length / 1024.0 <= targetSizeKb) return q95;

  var low = 5;
  var high = 95;
  List<int>? best;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    final data = img.encodeJpg(im, quality: mid);
    if (data.length / 1024.0 <= targetSizeKb) {
      best = data;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return best ?? img.encodeJpg(im, quality: 5);
}

/// isolate 入口: 读图 → 计算目标尺寸 → 缩放 → (带透明通道则铺白底) → JPEG 编码
/// 返回 null 表示不应压缩 (解码失败 / 压缩后更大), 调用方回退发原文件
LubanResult? _lubanEntry((String inputPath, String outDir) args) {
  final (inputPath, outDir) = args;
  try {
    // 超过 100MB 放弃: 整文件读入内存 + 解码会 OOM
    // (与 client.dart _imageThumbJob 的守卫一致), 调用方回退发原文件
    final input = File(inputPath);
    if (input.lengthSync() > 100 * 1024 * 1024) return null;
    final origBytes = input.readAsBytesSync();
    var im = img.decodeImage(origBytes);
    if (im == null) return null;
    // 相机 JPEG 常带 EXIF 旋转标记, 先按标记转正再缩放
    im = img.bakeOrientation(im);
    final t = _calcTarget(im.width, im.height);
    if (t.width <= 0) return null;

    var work = im;
    if (t.width != im.width || t.height != im.height) {
      work = img.copyResize(
        im,
        width: t.width,
        height: t.height,
        interpolation: img.Interpolation.average,
      );
    }
    // PNG/WebP 截图可能带透明通道: 铺白底再转 JPEG, 避免透底变黑
    if (work.numChannels == 4) {
      final bg = img.Image(
        width: work.width,
        height: work.height,
        numChannels: 3,
      );
      img.fill(bg, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(bg, work);
      work = bg;
    }

    final outBytes = _compressJpg(work, t.targetSizeKb);
    if (outBytes.length >= origBytes.length) return null;

    final dir = Directory(outDir)..createSync(recursive: true);
    final name =
        'luban_${DateTime.now().millisecondsSinceEpoch}_'
        '${Random().nextInt(0x7fffffff)}.jpg';
    final outPath = '${dir.path}${Platform.pathSeparator}$name';
    File(outPath).writeAsBytesSync(outBytes, flush: true);
    return (path: outPath, origBytes: origBytes.length, newBytes: outBytes.length);
  } catch (_) {
    return null;
  }
}

/// Luban 压缩一张图片 (在独立 isolate 中执行, 不阻塞 UI)。
/// [outDir] 为输出目录; 返回 null 表示不适合压缩, 调用方应直接发原文件。
Future<LubanResult?> lubanCompress(String inputPath, String outDir) {
  return Isolate.run(() => _lubanEntry((inputPath, outDir)));
}
