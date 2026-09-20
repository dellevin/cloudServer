import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../db.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_dialog.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';
import 'slidable_close.dart';

/// 剪贴板 tab (与设备/聊天/设置同级): 按日期分组, 可按日筛选;
/// 文本点按复制 / 文件点按打开; 左滑露红色删除按钮 (点按钮弹确认框),
/// 长按进多选 (可全选批量删除)
/// (订阅 client.clipChanges 独立事件流 — 不走 ChangeNotifier,
/// 传输进度的高频通知不会触发本页重载)
class ClipboardPage extends StatefulWidget {
  const ClipboardPage({super.key});

  @override
  State<ClipboardPage> createState() => ClipboardPageState();
}

class ClipboardPageState extends State<ClipboardPage> {
  static const int _pageSize = 50; // 每页条数

  List<ClipItem> _items = []; // 当前页的记录
  final Set<int> _missing = {}; // 文件已被移走/删除的记录 id
  final Map<int, int> _sizes = {}; // 文件记录 id -> 字节数
  StreamSubscription<void>? _sub;

  bool _selecting = false;
  final Set<int> _selected = {};

  /// 日期筛选: 只显示这一天 (本地 0 点); null = 全部
  DateTime? _filterDay;

  /// 分页: 当前页(从 0 开始) / 符合条件的总条数
  int _page = 0;
  int _total = 0;

  /// 搜索
  bool _searching = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce; // 搜索输入防抖, 停止敲字 300ms 后才查库
  int _reloadSeq = 0; // 重载序号: 防止慢的旧查询覆盖新结果

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = context.read<RelayClient>().clipChanges.listen((_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 日期筛选对应的 ts 范围 [start, end)
  (int?, int?) _dayRange() {
    final f = _filterDay;
    if (f == null) return (null, null);
    return (
      DateTime(f.year, f.month, f.day).millisecondsSinceEpoch,
      DateTime(f.year, f.month, f.day + 1).millisecondsSinceEpoch,
    );
  }

  int get _pageCount => _total == 0 ? 0 : ((_total + _pageSize - 1) ~/ _pageSize);

  /// 供 AppBar 按钮调用 (main.dart 经 GlobalKey): 刷新列表
  Future<void> reload() => _reload();

  /// 供 AppBar 按钮调用: 展开搜索框 (退出多选)
  void openSearch() {
    setState(() {
      _selecting = false;
      _selected.clear();
      _searching = true;
    });
  }

  Future<void> _reload() async {
    final seq = ++_reloadSeq;
    final (dayStart, dayEnd) = _dayRange();
    final q = _query.isEmpty ? null : _query;
    final total = await ChatDb.clipCount(
      query: q,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    if (seq != _reloadSeq) return; // 期间又发起了新查询, 丢弃本次结果
    final pageCount = total == 0 ? 0 : ((total + _pageSize - 1) ~/ _pageSize);
    var page = _page;
    if (page >= pageCount) page = pageCount - 1; // 删除后总页数可能变少
    if (page < 0) page = 0;
    final items = await ChatDb.clipHistory(
      limit: _pageSize,
      offset: page * _pageSize,
      query: q,
      dayStart: dayStart,
      dayEnd: dayEnd,
    );
    if (seq != _reloadSeq) return;
    // 文件存在性/大小检查: 单次 stat 并发做完 (原来 exists+length 串行
    // 两次往返, 一页 50 条最多 100 次排队 IO, 是日期筛选卡顿的主因)
    final fileItems = [
      for (final it in items)
        if (it.kind == 'file' && it.id != null) it,
    ];
    final stats = await Future.wait([
      for (final it in fileItems) FileStat.stat(it.content),
    ]);
    if (seq != _reloadSeq) return;
    final missing = <int>{};
    final sizes = <int, int>{};
    for (var i = 0; i < fileItems.length; i++) {
      final st = stats[i];
      if (st.type == FileSystemEntityType.file) {
        sizes[fileItems[i].id!] = st.size;
      } else {
        missing.add(fileItems[i].id!);
      }
    }
    if (mounted) {
      setState(() {
        _total = total;
        _page = page;
        _items = items;
        _missing
          ..clear()
          ..addAll(missing);
        _sizes
          ..clear()
          ..addAll(sizes);
        // 记录可能已被清空, 丢掉失效的选择
        final ids = _items.map((it) => it.id).toSet();
        _selected.removeWhere((id) => !ids.contains(id));
      });
    }
  }

  void _goPage(int p) {
    if (p < 0 || p >= _pageCount || p == _page) return;
    _page = p;
    _reload();
  }

  void _setQuery(String v) {
    _query = v.trim();
    _page = 0;
    // 防抖: 每敲一个字都查库会连续触发 IO, 停笔 300ms 后再查
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _reload);
  }

  void _closeSearch() {
    setState(() => _searching = false);
    if (_query.isNotEmpty) {
      _searchCtrl.clear();
      _query = '';
      _page = 0;
      _reload();
    }
  }

  // ---------- 删除 ----------

  /// 删一条记录(只删数据库条目, 文件由用户自己管理)
  Future<void> _deleteOne(ClipItem it) async {
    if (it.id == null) return;
    await ChatDb.deleteClip(it.id!);
  }

  /// 删除确认框: 文本/文件一致, 单选项
  Future<void> _confirmDelete(ClipItem it) async {
    final r = await AppDialog.actions<String>(
      context,
      title: tr('clip_del_title'),
      message: it.kind == 'file'
          ? _fileName(it.content)
          : (it.content.length > 80
              ? '${it.content.substring(0, 80)}…'
              : it.content),
      actions: [AppDialogAction(tr('delete'), 'record', danger: true)],
    );
    if (r == null || !mounted) return;
    await _deleteOne(it);
    await _reload();
  }

  Future<void> _deleteSelected() async {
    final targets = _items
        .where((it) => it.id != null && _selected.contains(it.id))
        .toList();
    if (targets.isEmpty) return;
    final choice = await AppDialog.actions<String>(
      context,
      title: trf('clip_del_n_title', {'n': targets.length}),
      actions: [AppDialogAction(tr('delete'), 'record', danger: true)],
    );
    if (choice == null) return;
    for (final it in targets) {
      await _deleteOne(it);
    }
    _exitSelect();
    await _reload();
  }

  // ---------- 选择模式 ----------

  void _enterSelect(ClipItem it) {
    if (it.id == null) return;
    setState(() {
      _selecting = true;
      _selected.add(it.id!);
    });
  }

  void _exitSelect() {
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(ClipItem it) {
    if (it.id == null) return;
    setState(() {
      if (!_selected.remove(it.id!)) _selected.add(it.id!);
    });
  }

  // ---------- 日期筛选 ----------

  /// 系统日历选择器, 用户可自由选择任意一天 (跟随应用语言中/英)
  Future<void> _pickFilterDay() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _filterDay ?? now,
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (d != null && mounted) {
      setState(() {
        _filterDay = DateTime(d.year, d.month, d.day);
        _page = 0;
      });
      _reload();
    }
  }

  // ---------- 交互 ----------

  Future<void> _onTap(ClipItem it) async {
    if (_selecting) {
      _toggleSelect(it);
      return;
    }
    final c = context.read<RelayClient>();
    if (it.kind == 'text') {
      // 走 client.writeClipText: 登记回环抑制, 这份文本不会被再传回对方
      c.writeClipText(it.content);
      AppToast.show(context, tr('copied'));
      return;
    }
    if (_missing.contains(it.id)) {
      AppToast.show(context, tr('file_gone'));
      return;
    }
    await openPath(context, it.content, _fileName(it.content));
  }

  /// 长文本全文查看 (可选择/复制)
  void _showFullText(ClipItem it) {
    AppDialog.custom(
      context,
      title: tr('clip_view_full'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: SelectableText(
                  it.content,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: AppTheme.inkOf(context),
                  ),
                ),
              ),
            ),
          ),
          AppDialog.buttons(
            context,
            okLabel: tr('copy'),
            cancelLabel: tr('close'),
            onOk: (dctx) {
              context.read<RelayClient>().writeClipText(it.content);
              Navigator.pop(dctx);
              AppToast.show(context, tr('copied'));
            },
          ),
        ],
      ),
    );
  }

  // ---------- 展示辅助 ----------

  static String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

  static String _hm(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 日期分组标签 (与传输记录页一致: 今天/昨天/x月x日/x年x月x日)
  static String _dayLabelTs(int ts) =>
      _dayLabelDay(DateTime.fromMillisecondsSinceEpoch(ts));

  static String _dayLabelDay(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return tr('today');
    if (day == today.subtract(const Duration(days: 1))) {
      return tr('yesterday');
    }
    if (d.year == now.year) return trf('date_md', {'m': d.month, 'd': d.day});
    return trf('date_ymd', {'y': d.year, 'm': d.month, 'd': d.day});
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final visible = _items; // 已是 DB 端筛选+分页后的当前页
    final allSelected = visible.isNotEmpty &&
        visible.every((it) => _selected.contains(it.id));

    // 按日期分组: 列表项为 String (日期头) / ClipItem / _Div (组内分隔线)
    final rows = <Object>[];
    String? lastLabel;
    var firstInGroup = true;
    for (final it in visible) {
      final label = _dayLabelTs(it.ts);
      if (label != lastLabel) {
        rows.add(label);
        lastLabel = label;
        firstInGroup = true;
      }
      if (!firstInGroup) rows.add(const _Div());
      firstInGroup = false;
      rows.add(it);
    }

    return Container(
      color: AppTheme.softOf(context),
      child: Column(
        children: [
          if (_items.isNotEmpty || _searching || _filterDay != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: _selecting
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
                                ..addAll(visible.map((it) => it.id!));
                            }
                          }),
                          child: Text(
                            allSelected
                                ? tr('unselect_all')
                                : tr('select_all'),
                          ),
                        ),
                        TextButton(
                          onPressed: _selected.isEmpty ? null : _deleteSelected,
                          child: Text(
                            tr('delete'),
                            style: TextStyle(
                              color: _selected.isEmpty
                                  ? AppTheme.grey
                                  : AppTheme.red,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('exit_select'),
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: _exitSelect,
                        ),
                      ],
                    )
                  : _searching
                      ? Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 34,
                                child: TextField(
                                  controller: _searchCtrl,
                                  autofocus: true,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.inkOf(context),
                                  ),
                                  cursorColor: AppTheme.green,
                                  decoration: InputDecoration(
                                    hintText: tr('clip_search_hint'),
                                    hintStyle: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.grey,
                                    ),
                                    isDense: true,
                                    filled: true,
                                    fillColor: AppTheme.green
                                        .withValues(alpha: 0.06),
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.search_rounded,
                                      size: 18,
                                      color: AppTheme.grey,
                                    ),
                                    prefixIconConstraints:
                                        const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 34,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(17),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                  onChanged: _setQuery,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: tr('close'),
                              icon: const Icon(Icons.close_rounded, size: 20),
                              onPressed: _closeSearch,
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            if (_filterDay != null)
                              _FilterChip(
                                label: _dayLabelDay(_filterDay!),
                                onClear: () {
                                  setState(() {
                                    _filterDay = null;
                                    _page = 0;
                                  });
                                  _reload();
                                },
                              )
                            else
                              Text(
                                trf('total_n', {'n': _total}),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.grey,
                                ),
                              ),
                            const Spacer(),
                            IconButton(
                              tooltip: tr('clip_filter_date'),
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                Icons.event_rounded,
                                size: 19,
                                color: _filterDay != null
                                    ? AppTheme.green
                                    : AppTheme.inkOf(context),
                              ),
                              onPressed: _pickFilterDay,
                            ),
                            IconButton(
                              tooltip: tr('select'),
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.playlist_add_check_circle_rounded,
                                size: 20,
                              ),
                              onPressed: () =>
                                  setState(() => _selecting = true),
                            ),
                          ],
                        ),
            ),
          Expanded(
            child: visible.isEmpty
                ? _EmptyState(
                    message: _query.isNotEmpty
                        ? tr('clip_no_match')
                        : _filterDay != null
                            ? tr('clip_none_that_day')
                            : tr('clip_empty'),
                  )
                : SlidableCloseOnOutsideTap(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final row = rows[i];
                        if (row is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                            child: Text(
                              row,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.grey,
                              ),
                            ),
                          );
                        }
                        if (row is _Div) {
                          return Container(
                            color: AppTheme.cardOf(context),
                            child: Divider(
                              height: 1,
                              indent: 56,
                              color: AppTheme.lineOf(context),
                            ),
                          );
                        }
                        final it = row as ClipItem;
                        final tile = _ClipTile(
                          item: it,
                          missing: _missing.contains(it.id),
                          size: _sizes[it.id],
                          selecting: _selecting,
                          selected: _selected.contains(it.id),
                          sourceName: it.fromMe
                              ? tr('me')
                              : c.peerName(it.peerId),
                          onTap: () => _onTap(it),
                          onLongPress: () =>
                              _selecting ? null : _enterSelect(it),
                          onShowFull: () => _showFullText(it),
                        );
                        // 选择模式下禁用滑动删除, 避免手势冲突
                        if (_selecting) return tile;
                        return Slidable(
                          key: Key('clip_${it.id}'),
                          endActionPane: ActionPane(
                            motion: const DrawerMotion(),
                            extentRatio: 0.22,
                            children: [
                              CustomSlidableAction(
                                onPressed: (_) => _confirmDelete(it),
                                backgroundColor: AppTheme.red,
                                padding: EdgeInsets.zero,
                                child: Center(
                                  child: Text(
                                    tr('delete'),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          child: tile,
                        );
                      },
                    ),
                  ),
          ),
          // ---------- 分页栏 (页数 > 1 时显示) ----------
          if (_pageCount > 1)
            Container(
              decoration: BoxDecoration(
                color: AppTheme.cardOf(context),
                border: Border(
                  top: BorderSide(color: AppTheme.lineOf(context), width: 0.5),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: tr('prev_page'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.chevron_left_rounded, size: 22),
                    color: AppTheme.inkOf(context),
                    disabledColor: AppTheme.grey.withValues(alpha: 0.4),
                    onPressed: _page > 0 ? () => _goPage(_page - 1) : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '${_page + 1} / $_pageCount',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.inkOf(context),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('next_page'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.chevron_right_rounded, size: 22),
                    color: AppTheme.inkOf(context),
                    disabledColor: AppTheme.grey.withValues(alpha: 0.4),
                    onPressed: _page < _pageCount - 1
                        ? () => _goPage(_page + 1)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 组内分隔线占位 (rows 列表里的哨兵类型)
class _Div {
  const _Div();
}

/// 当前日期筛选的 chip (点 ✕ 清除筛选)
class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onClear;
  const _FilterChip({required this.label, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClear,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.green.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.green),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.close, size: 13, color: AppTheme.green),
          ],
        ),
      ),
    );
  }
}

/// 空态: 无记录 / 筛选或搜索无结果
class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.content_paste_outlined,
            size: 44,
            color: AppTheme.grey.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.grey,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条记录: 通栏白底行 (34px 彩色图标块/图片缩略图 + 内容 + 时间/来源)
class _ClipTile extends StatelessWidget {
  final ClipItem item;
  final bool missing;
  final int? size;
  final bool selecting;
  final bool selected;
  final String sourceName;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onShowFull;

  const _ClipTile({
    required this.item,
    required this.missing,
    required this.size,
    required this.selecting,
    required this.selected,
    required this.sourceName,
    required this.onTap,
    required this.onLongPress,
    required this.onShowFull,
  });

  static (IconData, Color) _iconFor(String name) {
    if (isImageFile(name)) return (Icons.image_outlined, Colors.teal);
    if (isVideoFile(name)) return (Icons.videocam_outlined, Colors.deepOrange);
    if (isArchiveFile(name)) return (Icons.folder_zip_outlined, Colors.brown);
    if (isTextFile(name)) return (Icons.description_outlined, Colors.indigo);
    return (Icons.insert_drive_file_outlined, Colors.blueGrey);
  }

  @override
  Widget build(BuildContext context) {
    final isText = item.kind == 'text';
    final name = isText ? null : ClipboardPageState._fileName(item.content);
    final isImage = !isText && isImageFile(name!);
    final gone = !isText && missing;
    final longText = isText && item.content.length > 120;

    // 前导: 图片文件显示缩略图, 其他显示彩色图标块
    Widget leading;
    if (isImage && !gone) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.file(
          File(item.content),
          width: 34,
          height: 34,
          fit: BoxFit.cover,
          cacheWidth: 102,
          errorBuilder: (_, _, _) =>
              _iconBlock(Icons.broken_image_outlined, Colors.grey),
        ),
      );
    } else {
      final (icon, color) = isText
          ? (Icons.notes_rounded, AppTheme.green)
          : _iconFor(name!);
      leading = _iconBlock(icon, gone ? Colors.grey : color);
    }

    return Container(
      color: AppTheme.cardOf(context),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: 10),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: selected ? AppTheme.green : AppTheme.grey,
                  ),
                ),
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isText ? item.content : name!,
                      maxLines: isText ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: gone ? AppTheme.grey : AppTheme.inkOf(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          ClipboardPageState._hm(item.ts),
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppTheme.grey,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            sourceName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppTheme.grey,
                            ),
                          ),
                        ),
                        if (size != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            ClipboardPageState._fmtBytes(size!),
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppTheme.grey,
                            ),
                          ),
                        ],
                        if (gone) ...[
                          const SizedBox(width: 6),
                          Text(
                            tr('clip_file_missing'),
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppTheme.red,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (isText && !selecting && longText)
                IconButton(
                  tooltip: tr('clip_view_full'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.unfold_more,
                    size: 16,
                    color: AppTheme.grey,
                  ),
                  onPressed: onShowFull,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 34px 圆角浅色底彩色图标块
  static Widget _iconBlock(IconData icon, Color color) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 17, color: color),
    );
  }
}
