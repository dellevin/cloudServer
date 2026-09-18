// Luban 压缩冒烟测试: 生成几张特征不同的图, 跑 lubanCompress 验证行为
// 运行: dart run tool/luban_smoke.dart
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';

import 'package:cloudsend/image_compress.dart';
import 'package:image/image.dart' as img;

int _failures = 0;

void _check(bool cond, String label) {
  if (cond) {
    print('[PASS] $label');
  } else {
    _failures++;
    print('[FAIL] $label');
  }
}

/// 造一张带噪点的图 (纯色图压完必小, 噪点才接近真实照片)
String _makePhoto(String path, int w, int h) {
  final rng = Random(42);
  final im = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final r = 100 + rng.nextInt(156);
      final g = 100 + rng.nextInt(156);
      final b = 100 + rng.nextInt(156);
      im.setPixelRgb(x, y, r, g, b);
    }
  }
  File(path).writeAsBytesSync(img.encodeJpg(im, quality: 92));
  return path;
}

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('luban_smoke');
  final outDir = '${tmp.path}${Platform.pathSeparator}out';
  print('tmp: ${tmp.path}\n');

  // 1) 普通 4000x3000 照片 → 应压缩且明显变小, 短边压到 1440
  final p1 = _makePhoto('${tmp.path}/photo.jpg', 4000, 3000);
  final r1 = await lubanCompress(p1, outDir);
  _check(r1 != null, '4000x3000 photo compressed');
  if (r1 != null) {
    print('       ${r1.origBytes ~/ 1024}KB -> ${r1.newBytes ~/ 1024}KB');
    _check(r1.newBytes < r1.origBytes, 'smaller than original');
    final im = img.decodeImage(File(r1.path).readAsBytesSync())!;
    final short = min(im.width, im.height);
    _check(short <= 1440, 'short side <= 1440 (got ${im.width}x${im.height})');
  }

  // 2) 长图 800x8000 (ratio 0.1 <= 0.5) → 长图二分质量路径
  final p2 = _makePhoto('${tmp.path}/long.jpg', 800, 8000);
  final r2 = await lubanCompress(p2, outDir);
  _check(r2 != null, '800x8000 long image compressed');
  if (r2 != null) {
    print('       ${r2.origBytes ~/ 1024}KB -> ${r2.newBytes ~/ 1024}KB');
    final im = img.decodeImage(File(r2.path).readAsBytesSync())!;
    print('       resized to ${im.width}x${im.height}');
    _check(im.height > im.width, 'still portrait long image');
  }

  // 3) 小图 600x400 → 目标尺寸不小于原图, 不缩放; 若 q60 结果 >= 原图则返回 null
  final p3 = _makePhoto('${tmp.path}/small.jpg', 600, 400);
  final s3 = File(p3).lengthSync();
  final r3 = await lubanCompress(p3, outDir);
  print('       small: ${s3 ~/ 1024}KB, result: '
      '${r3 == null ? "null (kept original)" : "${r3.newBytes ~/ 1024}KB"}');
  if (r3 != null) {
    final im = img.decodeImage(File(r3.path).readAsBytesSync())!;
    _check(im.width == 600 && im.height == 400, 'small image not upscaled');
  }

  // 4) 非图片文件 → 解码失败返回 null
  final p4 = '${tmp.path}/fake.jpg';
  File(p4).writeAsBytesSync(List<int>.generate(2048, (i) => i % 256));
  final r4 = await lubanCompress(p4, outDir);
  _check(r4 == null, 'garbage bytes -> null (fallback to original)');

  tmp.deleteSync(recursive: true);
  print(_failures == 0 ? '\nALL PASS' : '\n$_failures FAILED');
  exitCode = _failures == 0 ? 0 : 1;
}
