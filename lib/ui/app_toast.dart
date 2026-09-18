import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';

/// 全局轻提示 (替换 SnackBar): 宽度随内容自适应, 带关闭按钮,
/// 默认 2.5s 自动消失; sticky=true 时不自动消失, 需手动 AppToast.hide()。
/// 同时只显示一条, 新提示会顶掉旧的。
class AppToast {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String msg, {
    bool sticky = false,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    hide();
    final entry = OverlayEntry(
      builder: (_) => _ToastPill(
        msg: msg,
        onClose: hide,
        actionLabel: actionLabel,
        onAction: onAction == null
            ? null
            : () {
                hide();
                onAction();
              },
      ),
    );
    _entry = entry;
    Overlay.of(context).insert(entry);
    if (!sticky) {
      // 带操作的提示多留一会儿, 给用户点按的时间
      final d = duration ??
          Duration(milliseconds: actionLabel != null ? 4000 : 2500);
      _timer = Timer(d, hide);
    }
  }

  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _ToastPill extends StatelessWidget {
  final String msg;
  final VoidCallback onClose;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _ToastPill({
    required this.msg,
    required this.onClose,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 亮主题用黑胶囊, 暗主题用浅灰胶囊 (与微信 toast 思路一致)
    final dark = AppTheme.isDark(context);
    final bg = dark ? const Color(0xF2D9D9D9) : const Color(0xE61A1A1A);
    final fg = dark ? Colors.black87 : Colors.white;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 88 + mq.padding.bottom,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 160),
          builder: (_, v, child) => Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - v)),
              child: child,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: BoxConstraints(maxWidth: mq.size.width * 0.75),
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      msg,
                      style: TextStyle(fontSize: 13, color: fg, height: 1.3),
                    ),
                  ),
                  if (actionLabel != null) ...[
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: onAction,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Text(
                          actionLabel!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.green,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: onClose,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: fg.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
