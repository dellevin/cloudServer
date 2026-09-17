import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import 'file_preview_page.dart';

class TransfersPage extends StatefulWidget {
  /// embedded=true 时嵌入主界面 (不带 Scaffold/AppBar)
  final bool embedded;
  const TransfersPage({super.key, this.embedded = false});

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  bool _selecting = false;
  final Set<String> _selected = {};

  void _exitSelect() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  Future<void> _deleteOne(RelayClient c, FileTransfer t) async {
    final choice = await confirmDeleteTransfer(context, t);
    if (choice == null) return;
    await c.deleteTransfer(t, deleteFile: choice == 'both');
  }

  Future<void> _deleteSelected(RelayClient c) async {
    final targets = c.transfers
        .where((t) => _selected.contains(t.transferId))
        .toList();
    if (targets.isEmpty) return;
    final choice = await confirmDeleteDialog(
      context,
      title: '删除 ${targets.length} 条传输记录',
    );
    if (choice == null) return;
    await c.deleteTransfers(targets, deleteFile: choice == 'both');
    _exitSelect();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final list = c.transfers.reversed.toList();
    // 可选择的: 非传输中的记录
    final selectable = list
        .where(
          (t) =>
              t.status != TransferStatus.accepted &&
              t.status != TransferStatus.transferring,
        )
        .toList();
    final allSelected =
        selectable.isNotEmpty && _selected.length == selectable.length;

    final body = list.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.lineOf(context)),
                  ),
                  child: const Icon(
                    Icons.folder_open,
                    size: 26,
                    color: AppTheme.grey,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '暂无传输记录',
                  style: TextStyle(
                    color: AppTheme.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final t = list[i];
              final busy =
                  t.status == TransferStatus.accepted ||
                  t.status == TransferStatus.transferring;
              final checked = _selected.contains(t.transferId);
              final card = TransferCard(
                t: t,
                selecting: _selecting,
                selected: checked,
                onSelectToggle: busy
                    ? null
                    : () => setState(() {
                        if (checked) {
                          _selected.remove(t.transferId);
                        } else {
                          _selected.add(t.transferId);
                        }
                      }),
              );
              if (_selecting || busy) return card;
              // 左滑露出删除按钮, 点击按钮再确认删除
              return Slidable(
                key: Key('transfer_${t.transferId}'),
                endActionPane: ActionPane(
                  motion: const DrawerMotion(),
                  extentRatio: 0.24,
                  children: [
                    CustomSlidableAction(
                      onPressed: (_) => _deleteOne(c, t),
                      backgroundColor: Colors.transparent,
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.red,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        alignment: Alignment.center,
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.delete_outline,
                              size: 22,
                              color: Colors.white,
                            ),
                            SizedBox(height: 3),
                            Text(
                              '删除',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                child: card,
              );
            },
          );

    // 选择模式工具条 (embedded 时内嵌显示; 独立页面时放 AppBar)
    final toolbar = list.isEmpty
        ? null
        : _selecting
        ? Row(
            children: [
              Text(
                '已选 ${_selected.length} 条',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkOf(context),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(selectable.map((t) => t.transferId));
                  }
                }),
                child: Text(allSelected ? '取消全选' : '全选'),
              ),
              TextButton(
                onPressed: _selected.isEmpty ? null : () => _deleteSelected(c),
                child: const Text('删除'),
              ),
              IconButton(
                tooltip: '退出选择',
                icon: const Icon(Icons.close, size: 20),
                onPressed: _exitSelect,
              ),
            ],
          )
        : null;

    if (widget.embedded) {
      return Column(
        children: [
          if (toolbar != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: toolbar,
            )
          else if (list.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: Row(
                children: [
                  Text(
                    '共 ${list.length} 条',
                    style: const TextStyle(fontSize: 12, color: AppTheme.grey),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '选择',
                    icon: const Icon(Icons.checklist, size: 20),
                    onPressed: () => setState(() => _selecting = true),
                  ),
                ],
              ),
            ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length} 条' : '传输记录'),
        actions: [
          if (list.isNotEmpty)
            _selecting
                ? Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          if (allSelected) {
                            _selected.clear();
                          } else {
                            _selected
                              ..clear()
                              ..addAll(selectable.map((t) => t.transferId));
                          }
                        }),
                        child: Text(allSelected ? '取消全选' : '全选'),
                      ),
                      TextButton(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => _deleteSelected(c),
                        child: const Text('删除'),
                      ),
                      IconButton(
                        tooltip: '退出选择',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: _exitSelect,
                      ),
                      const SizedBox(width: 4),
                    ],
                  )
                : IconButton(
                    tooltip: '选择',
                    icon: const Icon(Icons.checklist, size: 20),
                    onPressed: () => setState(() => _selecting = true),
                  ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: body,
    );
  }
}

/// 失败/取消后的重试按钮: 外发重发文件请求, 接收从 .part 断点续传
class _RetryButton extends StatelessWidget {
  final FileTransfer t;
  const _RetryButton({required this.t});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final isResume = !t.outgoing && t.bytesDone > 0;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () async {
        final ok = t.outgoing
            ? await c.retrySend(t)
            : await c.retryReceive(t);
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t.outgoing ? '对方不在线或本地文件已不存在' : '对方不在线, 无法续传',
              ),
            ),
          );
        }
      },
      child: Text(
        t.outgoing
            ? '重发'
            : (isResume ? '续传 (${(t.progress * 100).toStringAsFixed(0)}%)' : '重试'),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

class TransferCard extends StatelessWidget {
  final FileTransfer t;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelectToggle;
  const TransferCard({
    super.key,
    required this.t,
    this.selecting = false,
    this.selected = false,
    this.onSelectToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: selecting
          ? onSelectToggle
          : (t.status == TransferStatus.done
                ? () => openTransfer(context, t)
                : null),
      onLongPress: t.status == TransferStatus.done && !selecting
          ? () => openTransferWith(context, t)
          : null,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? (AppTheme.isDark(context)
                    ? const Color(0xFF0E3B24)
                    : const Color(0xFFE7F6EC))
              : null,
          border: Border.all(
            color: selected ? AppTheme.green : AppTheme.lineOf(context),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (selecting) ...[
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? AppTheme.green : AppTheme.grey,
                  ),
                  const SizedBox(width: 10),
                ],
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppTheme.softOf(context),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.lineOf(context)),
                  ),
                  child: Icon(
                    t.outgoing ? Icons.north_east : Icons.south_west,
                    size: 16,
                    color: AppTheme.green,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.fileName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: AppTheme.inkOf(context),
                        ),
                      ),
                      Text(
                        '${t.outgoing ? "发给" : "来自"} ${c.peerName(t.peerId)} · ${_fmt(t.fileSize)}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _statusLabel(t.status),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.grey,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            if (t.status == TransferStatus.transferring ||
                t.status == TransferStatus.accepted) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: t.progress, minHeight: 3),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_fmt(t.bytesDone)} / ${_fmt(t.fileSize)} (${(t.progress * 100).toStringAsFixed(0)}%)',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.grey,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => c.cancelTransfer(t),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: Text(
                        '取消',
                        style: TextStyle(fontSize: 12, color: AppTheme.red),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (t.status == TransferStatus.failed ||
                t.status == TransferStatus.canceled ||
                (t.outgoing && t.status == TransferStatus.rejected)) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (!t.outgoing && t.bytesDone > 0)
                    Expanded(
                      child: Text(
                        '已收 ${_fmt(t.bytesDone)} / ${_fmt(t.fileSize)}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.grey,
                          fontFamily: 'monospace',
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  _RetryButton(t: t),
                ],
              ),
            ],
            if (!t.outgoing && t.status == TransferStatus.waiting) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                    ),
                    onPressed: () => c.rejectFile(t),
                    child: const Text('拒绝'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                    ),
                    onPressed: () => c.acceptFile(t),
                    child: const Text('接受'),
                  ),
                ],
              ),
            ],
            if (t.savePath != null && t.status == TransferStatus.done) ...[
              const SizedBox(height: 10),
              Text(
                t.savePath!,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppTheme.grey,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabel(TransferStatus s) => switch (s) {
    TransferStatus.waiting => '等待确认',
    TransferStatus.accepted => '已接受',
    TransferStatus.transferring => '传输中',
    TransferStatus.done => '已完成',
    TransferStatus.rejected => '已拒绝',
    TransferStatus.failed => '失败',
    TransferStatus.canceled => '已取消',
  };

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024)
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
