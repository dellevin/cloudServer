import 'dart:async';

import 'package:flutter/material.dart';

/// 可缩放图片视图 (Telegram 风格): 双指捏合缩放 (最高 maxScale),
/// 双击在 1x / 2.5x 间切换 (以点击处为焦点, 带过渡动画),
/// 单击回调 (上层用来显隐控制层)
class ZoomableImage extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double maxScale;
  const ZoomableImage({
    super.key,
    required this.child,
    this.onTap,
    this.maxScale = 8,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  AnimationController? _anim;

  void _onDoubleTap(TapDownDetails d) {
    // 已放大 → 双击回 1x; 否则以点击处为焦点放大 2.5x
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.05;
    final Matrix4 end;
    if (zoomed) {
      end = Matrix4.identity();
    } else {
      const s = 2.5;
      final f = d.localPosition;
      // T(f) · S · T(-f): 焦点保持不动
      end = Matrix4.identity()
        ..translateByDouble(f.dx, f.dy, 0, 0)
        ..scaleByDouble(s, s, s, 1)
        ..translateByDouble(-f.dx, -f.dy, 0, 0);
    }
    _anim?.dispose();
    final a = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final tween = Matrix4Tween(begin: _tc.value, end: end);
    a.addListener(() => _tc.value = tween.transform(a.value));
    unawaited(a.forward());
    _anim = a;
  }

  @override
  void dispose() {
    _anim?.dispose();
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        maxScale: widget.maxScale,
        child: SizedBox.expand(child: Center(child: widget.child)),
      ),
    );
  }
}
