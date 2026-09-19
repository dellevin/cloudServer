import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';

/// 选项弹窗的一个选项。
/// [label] 主文案; [sub] 副说明 (有值时整行左对齐双行); [value] 点选返回值;
/// [danger] 标红 (删除类); [check] 右侧绿色勾 (标记当前选中项)
class AppDialogAction<T> {
  final String label;
  final String? sub;
  final T value;
  final bool danger;
  final bool check;

  const AppDialogAction(
    this.label,
    this.value, {
    this.sub,
    this.danger = false,
    this.check = false,
  });
}

/// 全应用统一弹窗: 所有弹窗只从这里出, 调样式只改这一个文件。
/// 风格: 大圆角卡片 (20) + 底部胶囊按钮 (灰底取消 / 绿底确认 / 红底危险)。
///
/// 四种用法:
/// ```dart
/// AppDialog.actions(ctx, title: ..., actions: [AppDialogAction('选项', 1)]); // 选项列表
/// AppDialog.confirm(ctx, title: ..., message: ...);                          // 确认框
/// AppDialog.input(ctx, title: ..., hint: ...);                               // 输入框
/// AppDialog.custom(ctx, title: ..., child: ...);                             // 自定义内容
/// ```
class AppDialog {
  AppDialog._();

  // ---------- 外壳 ----------

  /// 统一外壳: 20 大圆角卡片, 平底无阴影, 裁剪溢出
  static Future<T?> _show<T>(
    BuildContext context,
    Widget child, {
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.cardOf(ctx),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  /// 标题区: 居中 17 号半粗; 可带副说明; trailing = 标题行右侧挂件 (如「添加」按钮)
  static Widget _header(
    BuildContext ctx,
    String title, {
    String? message,
    Widget? trailing,
  }) {
    final t = Text(
      title,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppTheme.inkOf(ctx),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
      child: Column(
        children: [
          if (trailing == null)
            Center(child: t)
          else
            // 带右侧挂件的标题栏 (如「添加」按钮): 标题左对齐更像管理页
            Row(
              children: [
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: t),
                ),
                trailing,
              ],
            ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.inkOf(ctx).withValues(alpha: 0.6),
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------- 胶囊按钮 ----------

  /// 单个胶囊按钮: 实心 (bg/fg) 或描边 (border)
  static Widget _capsule(
    BuildContext ctx, {
    required String label,
    required Color fg,
    required VoidCallback onTap,
    Color? bg,
    Border? border,
  }) {
    return Material(
      color: bg ?? Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: border?.top ?? BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }

  /// 标准 取消|确认 双胶囊行 (confirm/input 自带; custom 内容需要时也可拼)
  /// onOk/onCancel 自定义动作; 默认 确认 pop true / 取消 pop null (无结果,
  /// 不带值才能兼容 String? 等任意路由泛型), 自定义时需自行 pop
  static Widget buttons(
    BuildContext ctx, {
    String? okLabel,
    String? cancelLabel,
    bool danger = false,
    void Function(BuildContext dctx)? onOk,
    void Function(BuildContext dctx)? onCancel,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: _capsule(
              ctx,
              label: cancelLabel ?? tr('cancel'),
              bg: AppTheme.softOf(ctx),
              fg: AppTheme.inkOf(ctx),
              onTap: () => (onCancel ?? (dctx) => Navigator.pop(dctx))(ctx),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _capsule(
              ctx,
              label: okLabel ?? tr('ok'),
              bg: danger ? AppTheme.red : AppTheme.green,
              fg: Colors.white,
              onTap: () => (onOk ?? (dctx) => Navigator.pop(dctx, true))(ctx),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 1. 选项列表 ----------

  /// 选项弹窗: 标题在上, 选项为圆角灰块竖排, 底部描边胶囊「取消」。
  /// 返回被点选项的 value; 点取消/遮罩返回 null。
  static Future<T?> actions<T>(
    BuildContext context, {
    required String title,
    String? message,
    required List<AppDialogAction<T>> actions,
    String? cancelLabel,
  }) {
    return _show<T>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(context, title, message: message),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final a in actions) _optionTile(context, a),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: _capsule(
                context,
                label: cancelLabel ?? tr('cancel'),
                fg: AppTheme.inkOf(context),
                border: Border.all(color: AppTheme.lineOf(context)),
                onTap: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个选项: 圆角灰块 (danger 换浅红底), 单行居中或双行左对齐
  static Widget _optionTile(BuildContext ctx, AppDialogAction<dynamic> a) {
    final color = a.danger ? AppTheme.red : AppTheme.inkOf(ctx);
    final bg = a.danger
        ? AppTheme.red.withValues(alpha: 0.08)
        : AppTheme.softOf(ctx);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pop(ctx, a.value),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            alignment: Alignment.center,
            child: a.sub == null
                ? Text(
                    a.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.label,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w500,
                                color: color,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              a.sub!,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.grey,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (a.check)
                        const Icon(
                          Icons.check,
                          size: 18,
                          color: AppTheme.green,
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  // ---------- 2. 确认框 ----------

  /// 确认弹窗: 标题+说明, 底部双胶囊; danger 时确认键红底 (删除/清空类)。
  /// 点确认返回 true, 其他情况 (取消/遮罩) 返回 false。
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    String? message,
    String? okLabel,
    String? cancelLabel,
    bool danger = false,
    bool barrierDismissible = true,
  }) async {
    final r = await _show<bool>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(context, title, message: message),
          buttons(
            context,
            okLabel: okLabel,
            cancelLabel: cancelLabel,
            danger: danger,
          ),
        ],
      ),
      barrierDismissible: barrierDismissible,
    );
    return r ?? false;
  }

  // ---------- 3. 输入框 ----------

  /// 输入弹窗: 标题+圆角填充输入框 (+可选灰色说明), 底部双胶囊。
  /// 返回 trim 后的输入; 取消/为空 (且 !allowEmpty) 返回 null。
  static Future<String?> input(
    BuildContext context, {
    required String title,
    String? hint,
    String? desc,
    String initial = '',
    String? okLabel,
    bool obscure = false,
    bool allowEmpty = false,
    TextInputType? keyboardType,
  }) async {
    final ctrl = TextEditingController(text: initial);
    String? r;
    try {
      r = await _show<String>(
        context,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(context, title),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    obscureText: obscure,
                    keyboardType: keyboardType,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppTheme.inkOf(context),
                    ),
                    cursorColor: AppTheme.green,
                    decoration: InputDecoration(
                      hintText: hint,
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.softOf(context),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      hintStyle: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.grey,
                      ),
                    ),
                    onSubmitted: (_) =>
                        Navigator.pop(context, ctrl.text.trim()),
                  ),
                  if (desc != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      desc,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.grey,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            buttons(
              context,
              okLabel: okLabel,
              onOk: (dctx) => Navigator.pop(dctx, ctrl.text.trim()),
            ),
          ],
        ),
      );
    } finally {
      // showDialog 完成时退出动画仍在播放, TextField 还在树里;
      // 立即 dispose 会让动画重建崩 "used after disposed", 延迟到动画结束
      Future<void>.delayed(const Duration(milliseconds: 300), ctrl.dispose);
    }
    if (r != null && (allowEmpty || r.isNotEmpty)) return r;
    return null;
  }

  // ---------- 4. 自定义内容 ----------

  /// 自定义内容弹窗: 统一外壳 (+可选标题栏/标题右侧挂件), 内容自己排。
  /// 底部按钮用 [buttons] 拼, 保持全应用一致。
  static Future<T?> custom<T>(
    BuildContext context, {
    String? title,
    Widget? trailing,
    required Widget child,
    bool barrierDismissible = true,
  }) {
    return _show<T>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) _header(context, title, trailing: trailing),
          Flexible(child: child),
        ],
      ),
      barrierDismissible: barrierDismissible,
    );
  }
}
