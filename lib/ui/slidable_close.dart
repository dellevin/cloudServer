import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

/// 左滑列表统一行为: 包住含 Slidable 的列表
///  - 打开一个条目时自动关闭其他 (SlidableAutoCloseBehavior)
///  - 有点开时, 点击列表空白处/其他条目都会关闭
class SlidableCloseOnOutsideTap extends StatefulWidget {
  final Widget child;
  const SlidableCloseOnOutsideTap({super.key, required this.child});

  @override
  State<SlidableCloseOnOutsideTap> createState() =>
      _SlidableCloseOnOutsideTapState();
}

class _SlidableCloseOnOutsideTapState extends State<SlidableCloseOnOutsideTap>
    with TickerProviderStateMixin {
  // 组通知要求带一个 controller (匹配逻辑只看 groupTag/closeSelf, 不会用到它)。
  // 不能用 late final: 若从未点开过条目, dispose 时才首次初始化会在
  // 已失效的 element 上创建 Ticker 而抛异常, 故改为可空 + 用时创建
  SlidableController? _dummy;

  @override
  void dispose() {
    _dummy?.dispose();
    super.dispose();
  }

  void _closeAll(BuildContext ctx) {
    final dummy = _dummy ??= SlidableController(this);
    SlidableGroupNotification.dispatch(
      ctx,
      SlidableAutoCloseNotification(
        groupTag: null,
        controller: dummy,
        closeSelf: true,
      ),
      assertParentExists: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SlidableAutoCloseBehavior(
      child: Builder(
        builder: (ctx) => GestureDetector(
          // 子节点不响应的空白区域才落到这里 (卡片点击由条目内的 barrier 处理)
          behavior: HitTestBehavior.translucent,
          onTap: () => _closeAll(ctx),
          child: widget.child,
        ),
      ),
    );
  }
}
