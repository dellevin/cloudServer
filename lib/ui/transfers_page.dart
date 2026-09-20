import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';
import 'app_dialog.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';
import 'slidable_close.dart';
import 'video_thumbs.dart';

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

  /// exists 结果缓存: key = path|status, 传输状态变化自动失效重查。
  /// build 里绝不同步 stat: 大文件合并/写盘的 IO 高峰时, 同步 stat 能把
  /// UI 线程卡出 ANR; 未命中先按 false 渲染, 异步查完再 setState 刷新
  final Map<String, bool> _existsCache = {};

  bool _fileExists(String path, TransferStatus st, int bytes) {
    if (_existsCache.length > 500) _existsCache.clear(); // 兜底上限
    final key = '$path|${st.name}';
    final hit = _existsCache[key];
    if (hit != null) return hit;
    _existsCache[key] = false;
    File(path).exists().then((v) {
      if (!mounted || _existsCache[key] == v) return;
      setState(() => _existsCache[key] = v);
    });
    return false;
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_ctrl.hasClients) return;
    if (_ctrl.position.pixels < _ctrl.position.maxScrollExtent - 240) return;
    final total = context.read<RelayClient>().visibleTransfers.length;
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

  /// 列表里的「删除」= 仅对列表隐藏 (不动文件, 聊天页文件消息保留),
  /// 所以只弹简单确认框, 不再有「同时删除文件」选项
  Future<void> _deleteOne(RelayClient c, FileTransfer t) async {
    final ok = await AppDialog.confirm(
      context,
      title: tr('del_transfer_title'),
      message: trf('file_quoted', {'name': t.fileName}),
      danger: true,
    );
    if (!ok || !mounted) return;
    await c.hideTransfers([t]);
  }

  Future<void> _deleteSelected(RelayClient c) async {
    final targets = c.visibleTransfers
        .where((t) => _selected.contains(t.transferId))
        .toList();
    if (targets.isEmpty) return;
    final ok = await AppDialog.confirm(
      context,
      title: trf('del_transfers_title', {'n': targets.length}),
      danger: true,
    );
    if (!ok || !mounted) return;
    await c.hideTransfers(targets);
    _exitSelect();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final full = c.visibleTransfers.reversed.toList();
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
                  Text(
                    tr('no_transfers'),
                    style: const TextStyle(
                      color: AppTheme.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          // 左滑互斥: 开一个关其他; 点空白/其他条目关闭
          : SlidableCloseOnOutsideTap(
              child: RefreshIndicator(
                color: AppTheme.green,
                onRefresh: () => c.refreshPeers(),
                child: ListView.builder(
                  controller: _ctrl,
                  // 列表不足一屏时也能下拉
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 12),
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
                    // 日期分组头 (微信账单风格: 灰底小字)
                    if (item is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Text(
                          item,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.grey,
                          ),
                        ),
                      );
                    }
                    final t = item as FileTransfer;
                    final busy =
                        t.status == TransferStatus.accepted ||
                        t.status == TransferStatus.transferring ||
                        t.status == TransferStatus.verifying;
                    final checked = _selected.contains(t.transferId);
                    // 组内行间细分隔线, 组尾/列表尾不画
                    final showDivider =
                        i + 1 < items.length && items[i + 1] is! String;
                    final card = TransferCard(
                      t: t,
                      selecting: _selecting,
                      selected: checked,
                      showDivider: showDivider,
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
                    // / 删除; 按钮为正方形 (边长≈条目高), 面板宽度按按钮个数换算
                    // existsSync 走缓存 (key 含状态/进度, 完成/续传变化时自动重查),
                    // 否则 5Hz 进度通知下每行每次都同步 stat 磁盘
                    final openable =
                        t.savePath != null &&
                        _fileExists(t.savePath!, t.status, t.bytesDone) &&
                        (t.outgoing || t.status == TransferStatus.done);
                    final n = 1 + (openable ? 1 : 0);
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
                              child: _SquareAction(
                                color: const Color(0xFF4C8DFF),
                                icon: Icons.visibility_outlined,
                                label: tr('open'),
                              ),
                            ),
                          CustomSlidableAction(
                            onPressed: (_) => _deleteOne(c, t),
                            backgroundColor: Colors.transparent,
                            padding: EdgeInsets.zero,
                            child: _SquareAction(
                              color: AppTheme.red,
                              icon: Icons.delete_outline,
                              label: tr('delete'),
                            ),
                          ),
                        ],
                      ),
                      child: card,
                    );
                  },
                ),
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
                trf('selected_n', {'n': _selected.length}),
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
                child: Text(
                  allSelected ? tr('unselect_all') : tr('select_all'),
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty ? null : () => _deleteSelected(c),
                child: Text(tr('delete')),
              ),
              IconButton(
                tooltip: tr('exit_select'),
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
                      trf('total_n', {'n': list.length}),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.grey,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: tr('select'),
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
        title: Text(
          _selecting
              ? trf('selected_n', {'n': _selected.length})
              : tr('seg_transfers'),
        ),
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
                        child: Text(
                          allSelected ? tr('unselect_all') : tr('select_all'),
                        ),
                      ),
                      TextButton(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => _deleteSelected(c),
                        child: Text(tr('delete')),
                      ),
                      IconButton(
                        tooltip: tr('exit_select'),
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: _exitSelect,
                      ),
                      const SizedBox(width: 4),
                    ],
                  )
                : IconButton(
                    tooltip: tr('select'),
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
    if (day == today) return tr('today');
    if (day == today.subtract(const Duration(days: 1))) return tr('yesterday');
    if (d.year == now.year) return trf('date_md', {'m': d.month, 'd': d.day});
    return trf('date_ymd', {'y': d.year, 'm': d.month, 'd': d.day});
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
          AppToast.show(
            context,
            t.outgoing ? tr('retry_fail_out') : tr('resume_fail'),
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
              ? tr('resend')
              : (isResume
                    ? trf('resume_pct', {
                        'pct': (t.progress * 100).toStringAsFixed(0),
                      })
                    : tr('retry')),
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

/// 左滑操作按钮: 通高纯色块 (微信样式)
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
      color: color,
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

/// 传输记录行 (微信账单风格: 通栏白块 + 行间细分隔线)
class TransferCard extends StatelessWidget {
  final FileTransfer t;
  final bool selecting;
  final bool selected;
  final bool showDivider;
  final VoidCallback? onSelectToggle;
  const TransferCard({
    super.key,
    required this.t,
    this.selecting = false,
    this.selected = false,
    this.showDivider = true,
    this.onSelectToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return Material(
      color: selected
          ? (AppTheme.isDark(context)
                ? const Color(0xFF0E3B24)
                : const Color(0xFFE7F6EC))
          : AppTheme.cardOf(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            // 不再点击预览 (改在左滑「打开」里); 仅多选模式响应点击
            onTap: selecting ? onSelectToggle : null,
            onLongPress: t.status == TransferStatus.done && !selecting
                ? () => openTransferWith(context, t)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                      // 图片/视频显示缩略图, 其他为彩色软底类型图标
                      _leading(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.fileName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 15,
                                color: AppTheme.inkOf(context),
                              ),
                            ),
                            const SizedBox(height: 3),
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
                                    '${t.outgoing ? trf('sent_to', {'name': c.peerName(t.peerId)}) : trf('recv_from', {'name': c.peerName(t.peerId)})} · ${_fmt(t.fileSize)} · ${_hm(t.ts)}',
                                    style: const TextStyle(
                                      fontSize: 12,
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
                            ? tr('queued')
                            : _statusLabel(t.status),
                        style: TextStyle(
                          fontSize: 12,
                          color: _statusColor(t.status),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  if (t.status == TransferStatus.transferring ||
                      t.status == TransferStatus.accepted ||
                      t.status == TransferStatus.verifying) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          // 进度区订阅轻量 tick: 5Hz 进度刷新只重建这一小块,
                          // 不再触发整页 rebuild (bytesDone/speed 读的是同一对象, 拿到即最新)
                          child: ValueListenableBuilder<int>(
                            valueListenable: c.progressTick,
                            builder: (context, _, _) {
                              return Column(
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
                                        '${_fmt(t.speedBps.round())}/s · ${trf('eta_left', {'eta': _etaText(t.etaSeconds)})}',
                                    ].join(' · '),
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppTheme.grey,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 校验中不显示取消: 合并 isolate 不可中断,
                        // 此时取消只会删掉正在合并的分片
                        if (t.status != TransferStatus.verifying)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => c.cancelTransfer(t),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: Text(
                                tr('cancel'),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.red,
                                ),
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
                              trf('received_n', {
                                'n':
                                    '${_fmt(t.bytesDone)} / ${_fmt(t.fileSize)}',
                              }),
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
                          child: Text(
                            tr('reject'),
                            style: const TextStyle(fontSize: 12),
                          ),
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
                          child: Text(
                            tr('accept'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (showDivider)
            Divider(height: 1, indent: 66, color: AppTheme.lineOf(context)),
        ],
      ),
    );
  }

  /// 文件类型图标: 彩色软底方块
  Widget _iconBox() {
    final (icon, iconColor) = _fileVisual(t.fileName);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 20, color: iconColor),
    );
  }

  /// 已完成的图片/视频本地文件显示缩略图; 失败/缺失回退类型图标
  Widget _leading() {
    final path = t.savePath;
    final canThumb = path != null && t.status == TransferStatus.done;
    if (canThumb && isImageFile(t.fileName)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          cacheWidth: 120,
          errorBuilder: (_, _, _) => _iconBox(),
        ),
      );
    }
    if (canThumb && isVideoFile(t.fileName)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 40,
          height: 40,
          child: FutureBuilder<Uint8List?>(
            future: VideoThumbs.get(path),
            builder: (_, snap) {
              final bytes = snap.data;
              if (bytes == null) return _iconBox();
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes, fit: BoxFit.cover),
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      size: 18,
                      color: Colors.white70,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    }
    return _iconBox();
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
    TransferStatus.waiting => tr('st_waiting_confirm'),
    TransferStatus.accepted => tr('st_accepted'),
    TransferStatus.transferring => tr('st_transferring'),
    TransferStatus.verifying => tr('st_verifying'),
    TransferStatus.done => tr('st_done'),
    TransferStatus.rejected => tr('st_rejected'),
    TransferStatus.failed => tr('st_failed'),
    TransferStatus.canceled => tr('st_canceled'),
  };

  static Color _statusColor(TransferStatus s) => switch (s) {
    TransferStatus.done => AppTheme.green,
    TransferStatus.failed => AppTheme.red,
    TransferStatus.waiting => const Color(0xFFFF9500),
    TransferStatus.transferring ||
    TransferStatus.accepted ||
    TransferStatus.verifying => const Color(0xFF576B95),
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
    if (secs < 60) return trf('eta_secs', {'n': secs.ceil()});
    if (secs < 3600) return trf('eta_mins', {'n': (secs / 60).ceil()});
    return tr('eta_hour');
  }
}
