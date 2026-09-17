// 一次性工具: 将 assets/icon.svg 渲染为 assets/icon.png (1024x1024)
// 运行: flutter test tool/icon_render_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';

void main() {
  test('render svg to png', () async {
    final info = await vg.loadPicture(SvgFileLoader(File('assets/icon.svg')), null);
    final img = await info.picture.toImage(1024, 1024);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('assets/icon.png').writeAsBytes(bytes!.buffer.asUint8List());
    info.picture.dispose();
  });
}
