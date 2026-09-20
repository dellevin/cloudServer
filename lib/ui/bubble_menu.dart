import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';

/// 取 widget 在屏幕上的全局矩形 (长按菜单定位用)
Rect rectOf(BuildContext ctx) {
  final box = ctx.findRenderObject() as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 微信风格: 长按气泡后菜单浮在气泡正上方 (上方空间不够时放下面),
/// 深色圆角横排, 带指向气泡的小三角; 点外部/返回键关闭
void showBubbleMenu(
  BuildContext context,
  Rect anchor,
  List<({String label, VoidCallback onTap})> actions,
) {
  if (actions.isEmpty) return;
  // Windows 自定义标题栏把导航区压低 38px: localToGlobal 是相对窗口的,
  // 换算成 Overlay (弹窗绘制区) 的坐标, 否则菜单整体偏低
  final overlayBox =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final overlayOrigin = overlayBox.localToGlobal(Offset.zero);
  anchor = anchor.shift(-overlayOrigin);
  final mq = MediaQuery.of(context);
  const menuH = 44.0;
  // 估算宽度仅用于把菜单钳制在屏幕内, 实际居中由 FractionalTranslation 保证
  final estW = actions.fold<double>(
    0,
    (s, a) => s + a.label.length * 14.0 + 28,
  );
  final cx = anchor.center.dx.clamp(
    estW / 2 + 8,
    mq.size.width - estW / 2 - 8,
  );
  final above = anchor.top - mq.padding.top > menuH + 24;
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('close'),
    barrierColor: Colors.transparent,
    pageBuilder: (dlgCtx, _, _) => Stack(
      children: [
        // 指向气泡的小三角
        Positioned(
          left: cx - 5,
          top: above ? anchor.top - 13 : anchor.bottom + 3,
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 10,
              height: 10,
              color: const Color(0xFF4C4C4C),
            ),
          ),
        ),
        Positioned(
          left: cx,
          top: above ? anchor.top - menuH - 8 : anchor.bottom + 8,
          child: FractionalTranslation(
            translation: const Offset(-0.5, 0),
            child: Material(
              color: const Color(0xFF4C4C4C),
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: menuH,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0)
                        Container(
                          width: 0.5,
                          height: 18,
                          color: Colors.white24,
                        ),
                      InkWell(
                        onTap: () {
                          Navigator.pop(dlgCtx);
                          actions[i].onTap();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Text(
                            actions[i].label,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
