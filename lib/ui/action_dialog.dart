import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';

/// 微信动作面板风格的确认弹窗: 标题+说明在上, 选项整行竖排,
/// 危险操作标红, 「取消」用间隔带隔开。
/// 返回被点选项的 value; 点取消/遮罩返回 null。
Future<T?> showActionDialog<T>(
  BuildContext context, {
  required String title,
  String? message,
  required List<({String label, T value, bool danger})> actions,
  String? cancelLabel,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppTheme.cardOf(ctx),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Column(
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: AppTheme.grey),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: AppTheme.lineOf(ctx)),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) Divider(height: 1, color: AppTheme.lineOf(ctx)),
            _actionRow(
              ctx,
              actions[i].label,
              () => Navigator.pop(ctx, actions[i].value),
              color: actions[i].danger ? AppTheme.red : null,
            ),
          ],
          Container(height: 8, color: AppTheme.softOf(ctx)),
          _actionRow(ctx, cancelLabel ?? tr('cancel'), () => Navigator.pop(ctx)),
        ],
      ),
    ),
  );
}

Widget _actionRow(
  BuildContext ctx,
  String label,
  VoidCallback onTap, {
  Color? color,
}) {
  return InkWell(
    onTap: onTap,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 13),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(fontSize: 15, color: color ?? AppTheme.inkOf(ctx)),
      ),
    ),
  );
}
