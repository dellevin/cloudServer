import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import 'file_preview_page.dart';
import 'slidable_close.dart';

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

  // 分页加载: 默认显示前 20 条, 滚动接近底部时每次再加载 20 条
  static const _pageSize = 20;
  int _shown = _pageSize;
  final ScrollController _ctrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_ctrl.hasClients) return;
    if (_ctrl.position.pixels < _ctrl.position.maxScrollExtent - 240) return;
    final total = context.read<RelayClient>().transfers.length;
    if (_shown >= total) return;
    setState(() => _shown += _pageSize);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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
    final full = c.transfers.reversed.toList();
    final list = full.take(_shown).toList();
    final hasMore = full.length > list.length;
    // 可选择的: 已加载且非传输中的记录
    final selectable = list
        .where(
          (t) =>
              t.status != TransferStatus.accepted &&
              t.status != TransferStatus.transferring,
        )
        .toList();
    final allSelected =
        selectable.isNotEmpty && _selected.length == selectable.length;

    // 按日期分组: 列表项为 String (日期头) 或 FileTransfer
    final items = <Object>[];
    String? lastLabel;
    for (final t in list) {
      final label = _dayLabel(t.ts);
      if (label != lastLabel) {
        items.add(label);
        lastLabel = label;
      }
      items.add(t);
    }

    final body = Container(
      color: AppTheme.softOf(context),
      child: list.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.cardOf(context),
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
          // 左滑互斥: 开一个关其他; 点空白/其他条目关闭
          : SlidableCloseOnOutsideTap(
              child: ListView.builder(
                controller: _ctrl,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                // 有未加载的记录时, 底部多一行加载指示
                itemCount: items.length + (hasMore ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i >= items.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.grey,
                          ),
                        ),
                      ),
                    );
                  }
                  final item = items[i];
                  // 日期分组头 (微信聊天时间分隔风格)
                  if (item is String) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                      child: Text(
                        item,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.grey,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                        ),
                      ),
                    );
                  }
                  final t = item as FileTransfer;
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
                  // 左滑露出操作按钮: 打开(收到需已完成, 发出的本地有文件即可)
                  // 位置(文件在本地) / 删除; 按钮为正方形 (边长≈条目高), 面板宽度按按钮个数换算
                  final revealable =
                      t.savePath != null && File(t.savePath!).existsSync();
                  final openable = revealable &&
                      (t.outgoing || t.status == TransferStatus.done);
                  final n = 1 + (revealable ? 1 : 0) + (openable ? 1 : 0);
                  final sw = MediaQuery.of(context).size.width;
                  final ratio = (n * 76.0) / sw;
                  return Slidable(
                    key: Key('transfer_${t.transferId}'),
                    endActionPane: ActionPane(
                      motion: const DrawerMotion(),
                      extentRatio: ratio.clamp(0.0, 0.8),
                      children: [
                        if (openable)
                          CustomSlidableAction(
                            onPressed: (_) => openTransfer(context, t),
                            backgroundColor: Colors.transparent,
                            padding: EdgeInsets.zero,
                            child: const _SquareAction(
                              color: Color(0xFF4C8DFF),
                              icon: Icons.visibility_outlined,
                              label: '打开',
                            ),
                          ),
                        if (revealable)
                          CustomSlidableAction(
                            onPressed: (_) =>
                                revealTransferInFolder(context, t),
                            backgroundColor: Colors.transparent,
                            padding: EdgeInsets.zero,
                            child: _SquareAction(
                              color: AppTheme.green,
                              icon: Icons.folder_open,
                              label: '位置',
                            ),
                          ),
                        CustomSlidableAction(
                          onPressed: (_) => _deleteOne(c, t),
                          backgroundColor: Colors.transparent,
                          padding: EdgeInsets.zero,
                          child: _SquareAction(
                            color: AppTheme.red,
                            icon: Icons.delete_outline,
                            label: '删除',
                          ),
                        ),
                      ],
                    ),
                    child: card,
                  );
                },
              ),
            ),
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
      return Container(
        color: AppTheme.softOf(context),
        child: Column(
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.grey,
                      ),
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
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
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

  /// 日期分组标签 (微信风格: 今天/昨天/x月x日/x年x月x日)
  static String _dayLabel(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return '今天';
    if (day == today.subtract(const Duration(days: 1))) return '昨天';
    if (d.year == now.year) return '${d.month}月${d.day}日';
    return '${d.year}年${d.month}月${d.day}日';
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
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: () async {
        final ok = t.outgoing ? await c.retrySend(t) : await c.retryReceive(t);
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t.outgoing ? '对方不在线或本地文件已不存在' : '对方不在线, 无法续传'),
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppTheme.green),
        ),
        child: Text(
          t.outgoing
              ? '重发'
              : (isResume
                    ? '续传 ${(t.progress * 100).toStringAsFixed(0)}%'
                    : '重试'),
          style: const TextStyle(
            fontSize: 11.5,
            color: AppTheme.green,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 左滑操作按钮: 填满格子 (与消息列表删除按钮同款)
class _SquareAction extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  const _SquareAction({
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// 传输卡片 (微信风格: 灰底白卡, 文件类型彩色图标, 状态着色)
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
    final (icon, iconColor) = _fileVisual(t.fileName);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected
            ? (AppTheme.isDark(context)
                  ? const Color(0xFF0E3B24)
                  : const Color(0xFFE7F6EC))
            : AppTheme.cardOf(context),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          // 不再点击预览 (改在左滑「打开」里); 仅多选模式响应点击
          onTap: selecting ? onSelectToggle : null,
          onLongPress: t.status == TransferStatus.done && !selecting
              ? () => openTransferWith(context, t)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
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
                        size: 18,
                        color: selected ? AppTheme.green : AppTheme.grey,
                      ),
                      const SizedBox(width: 8),
                    ],
                    // 文件类型图标: 彩色软底方块
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(icon, size: 18, color: iconColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.fileName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: AppTheme.inkOf(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                t.outgoing
                                    ? Icons.north_east
                                    : Icons.south_west,
                                size: 10,
                                color: AppTheme.grey,
                              ),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  '${t.outgoing ? "发给" : "来自"} ${c.peerName(t.peerId)} · ${_fmt(t.fileSize)} · ${_hm(t.ts)}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.grey,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      c.isSendQueued(t.transferId)
                          ? '排队中'
                          : _statusLabel(t.status),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: _statusColor(t.status),
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                if (t.status == TransferStatus.transferring ||
                    t.status == TransferStatus.accepted) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: t.progress,
                                minHeight: 4,
                                color: AppTheme.green,
                                backgroundColor: AppTheme.lineOf(context),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              [
                                '${_fmt(t.bytesDone)} / ${_fmt(t.fileSize)} · ${(t.progress * 100).toStringAsFixed(0)}%',
                                // 传输中显示实时速度与预计剩余时间
                                if (t.status == TransferStatus.transferring &&
                                    t.speedBps > 0)
                                  '${_fmt(t.speedBps.round())}/s · 剩余 ${_etaText(t.etaSeconds)}',
                              ].join(' · '),
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.grey,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
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
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => c.rejectFile(t),
                        child: const Text('拒绝', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => c.acceptFile(t),
                        child: const Text('接受', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 文件类型图标与配色
  static (IconData, Color) _fileVisual(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    if (isImageFile(name)) {
      return (Icons.image_outlined, const Color(0xFF4C8DFF));
    }
    if (isVideoFile(name)) {
      return (Icons.videocam_outlined, const Color(0xFF8A5CF6));
    }
    if (isArchiveFile(name) || const {'rar', '7z', 'tar', 'gz'}.contains(ext)) {
      return (Icons.folder_zip_outlined, const Color(0xFFC9A227));
    }
    if (const {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'}.contains(ext)) {
      return (Icons.audiotrack_outlined, const Color(0xFFFF7A45));
    }
    if (ext == 'pdf') {
      return (Icons.picture_as_pdf_outlined, const Color(0xFFFA5151));
    }
    if (const {'doc', 'docx', 'md'}.contains(ext)) {
      return (Icons.description_outlined, const Color(0xFF4C8DFF));
    }
    if (const {'xls', 'xlsx', 'csv'}.contains(ext)) {
      return (Icons.table_chart_outlined, const Color(0xFF07C160));
    }
    if (const {'ppt', 'pptx'}.contains(ext)) {
      return (Icons.slideshow_outlined, const Color(0xFFFF7A45));
    }
    if (const {
      'txt',
      'log',
      'json',
      'xml',
      'yaml',
      'yml',
      'js',
      'ts',
      'py',
      'java',
      'c',
      'cpp',
      'h',
      'cs',
      'go',
      'rs',
      'html',
      'css',
      'sql',
      'vue',
      'jsx',
      'tsx',
    }.contains(ext)) {
      return (Icons.code, const Color(0xFF576B95));
    }
    return (Icons.insert_drive_file_outlined, const Color(0xFF576B95));
  }

  static String _statusLabel(TransferStatus s) => switch (s) {
    TransferStatus.waiting => '等待确认',
    TransferStatus.accepted => '已接受',
    TransferStatus.transferring => '传输中',
    TransferStatus.done => '已完成',
    TransferStatus.rejected => '已拒绝',
    TransferStatus.failed => '失败',
    TransferStatus.canceled => '已取消',
  };

  static Color _statusColor(TransferStatus s) => switch (s) {
    TransferStatus.done => AppTheme.green,
    TransferStatus.failed => AppTheme.red,
    TransferStatus.waiting => const Color(0xFFFF9500),
    TransferStatus.transferring ||
    TransferStatus.accepted => const Color(0xFF576B95),
    _ => AppTheme.grey,
  };

  static String _hm(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 剩余时间文案: <60s 显秒, <60min 显分, 否则 >1小时
  static String _etaText(double? secs) {
    if (secs == null) return '--';
    if (secs < 60) return '${secs.ceil()}秒';
    if (secs < 3600) return '${(secs / 60).ceil()}分钟';
    return '>1小时';
  }
}
