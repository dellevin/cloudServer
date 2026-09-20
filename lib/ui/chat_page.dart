import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../client.dart';
import '../db.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';
import 'app_dialog.dart';
import 'app_toast.dart';
import 'bubble_menu.dart';
import 'file_preview_page.dart';
import 'slidable_close.dart';
import 'video_thumbs.dart';

/// 聊天标签页: 显示有会话记录的对端列表 (微信风格通栏列表)
class ChatsTabPage extends StatelessWidget {
  const ChatsTabPage({super.key});

  /// 会话最后一条预览: 文件消息显示 [图片]/[视频]/[文件] 样式
  static String _lastPreview(
    String peerId,
    List<ChatMessage> msgs,
    FileTransfer? lastFile,
  ) {
    final lastMsgTs = msgs.isNotEmpty ? msgs.last.ts : 0;
    if (lastFile != null && lastFile.ts > lastMsgTs) {
      final name = lastFile.fileName;
      if (isImageFile(name)) return tr('img_tag');
      if (isVideoFile(name)) return tr('video_tag');
      return trf('file_tag', {'name': name});
    }
    return msgs.isNotEmpty ? msgs.last.text : '';
  }

  /// 各对端的最后一条文件传输 (每帧只扫一次 transfers,
  /// 代替每行都全表扫的 O(会话数×传输数))
  static Map<String, FileTransfer> _lastFileByPeer(RelayClient c) {
    final map = <String, FileTransfer>{};
    for (final t in c.transfers) {
      if (t.ephemeral) continue; // 预览临时传输不进会话列表
      final cur = map[t.peerId];
      if (cur == null || t.ts > cur.ts) map[t.peerId] = t;
    }
    return map;
  }

  /// 各会话最后活动时间 (消息与文件取最新), 列表按此降序排列
  static Map<String, int> _lastTsMap(RelayClient c) {
    final map = <String, int>{
      for (final e in c.chats.entries)
        e.key: e.value.isNotEmpty ? e.value.last.ts : 0,
    };
    for (final t in c.transfers) {
      if (t.ephemeral) continue;
      final cur = map[t.peerId];
      if (cur != null && t.ts > cur) map[t.peerId] = t.ts;
    }
    return map;
  }

  /// 微信风格时间: 今天 HH:mm / 昨天 / 一周内显示星期 / 今年 M月d日 / 更早全日期
  static String _listTime(int ts) {
    if (ts == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == today) return hm;
    if (day == today.subtract(const Duration(days: 1))) return tr('yesterday');
    if (today.difference(day).inDays < 7) return tr('wk_${d.weekday}');
    if (day.year == now.year) {
      return trf('date_md', {'m': d.month, 'd': d.day});
    }
    return trf('date_ymd', {'y': d.year, 'm': d.month, 'd': d.day});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final lastTs = _lastTsMap(c);
    final lastFiles = _lastFileByPeer(c);
    final ids = lastTs.keys.toList()
      // 在线的排前面, 组内再按最后活动时间倒序 (上下线变化会触发重排)
      ..sort((a, b) {
        final onlineA = c.isOnline(a);
        final onlineB = c.isOnline(b);
        if (onlineA != onlineB) return onlineA ? -1 : 1;
        return lastTs[b]!.compareTo(lastTs[a]!);
      });
    return RefreshIndicator(
      color: AppTheme.green,
      onRefresh: () => c.refreshPeers(),
      child: ids.isEmpty
          // 空态用可滚动容器包一层, 否则无法下拉; 收藏入口固定在最上面
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Material(
                  color: AppTheme.cardOf(context),
                  child: const _CollectionEntry(),
                ),
                SizedBox(height: MediaQuery.of(context).size.height * 0.2),
                _Empty(icon: Icons.forum_outlined, text: tr('no_chats')),
              ],
            )
          : SlidableCloseOnOutsideTap(
              child: Material(
                color: AppTheme.cardOf(context),
                child: ListView.separated(
                  // 列表不足一屏时也能下拉
                  physics: const AlwaysScrollableScrollPhysics(),
                  // 第 0 项是固定的「收藏」入口 (不可滑动/删除), 后面才是会话
                  itemCount: ids.length + 1,
                  // 分隔线从名字左缘开始 (16 边距 + 48 头像 + 12 间距)
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    indent: 76,
                    color: AppTheme.lineOf(context),
                  ),
                  itemBuilder: (_, i) {
                    if (i == 0) return const _CollectionEntry();
                    final id = ids[i - 1];
                    final msgs = c.chats[id]!;
                    final last = _lastPreview(id, msgs, lastFiles[id]);
                    final n = c.unread[id] ?? 0;
                    final name = c.peerName(id);
                    // 左滑露出操作: 有未读时「标记已读」(灰) + 通高红色删除
                    return Slidable(
                      key: Key('conv_$id'),
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        extentRatio: n > 0 ? 0.42 : 0.22,
                        children: [
                          if (n > 0)
                            CustomSlidableAction(
                              onPressed: (_) => c.markConversationRead(id),
                              backgroundColor: AppTheme.grey,
                              padding: EdgeInsets.zero,
                              child: Center(
                                child: Text(
                                  tr('mark_read'),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          CustomSlidableAction(
                            onPressed: (_) => _confirmDeleteConversation(
                              context,
                              c,
                              id,
                              name,
                            ),
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
                      child: InkWell(
                        onTap: () => Navigator.pushNamed(
                          context,
                          '/chat',
                          arguments: id,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ConversationAvatar(
                                client: c,
                                peerId: id,
                                name: name,
                                unread: n,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 1),
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        color: AppTheme.inkOf(context),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      last,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: AppTheme.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  _listTime(lastTs[id]!),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }

  static void _confirmDeleteConversation(
    BuildContext context,
    RelayClient c,
    String peerId,
    String name,
  ) async {
    final choice = await AppDialog.actions<String>(
      context,
      title: tr('del_conv_title'),
      message: trf('del_conv_message', {'name': name}),
      actions: [
        AppDialogAction(tr('del_conv_hide'), 'hide'),
        AppDialogAction(tr('del_conv_all'), 'delete', danger: true),
      ],
    );
    if (choice == 'hide') c.hideConversation(peerId);
    if (choice == 'delete') await c.deleteConversation(peerId);
  }
}

/// 会话列表头像: 48px 圆角方形, 未读数红色角标在右上角 (微信样式);
/// 对端不在线时灰底 + 灰度滤镜 (与设备页的离线设备同款)
class _ConversationAvatar extends StatelessWidget {
  final RelayClient client;
  final String peerId;
  final String name;
  final int unread;
  const _ConversationAvatar({
    required this.client,
    required this.peerId,
    required this.name,
    required this.unread,
  });

  // 灰度滤镜: 离线对端的彩色头像去色 (与设备页离线设备一致)
  static const _greyscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final bytes = client.peerAvatarBytes(peerId);
    final online = client.isOnline(peerId);
    Widget avatar = Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: online ? const Color(0xFF576B95) : AppTheme.grey,
        borderRadius: BorderRadius.circular(4),
        image: bytes != null
            ? DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover)
            : null,
      ),
      child: bytes != null
          ? null
          : Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 19,
              ),
            ),
    );
    if (!online) {
      avatar = ColorFiltered(colorFilter: _greyscale, child: avatar);
    }
    if (unread <= 0) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          top: -5,
          right: -8,
          child: Container(
            constraints: const BoxConstraints(minWidth: 17),
            height: 17,
            padding: const EdgeInsets.symmetric(horizontal: 4.5),
            decoration: BoxDecoration(
              color: AppTheme.red,
              borderRadius: BorderRadius.circular(8.5),
            ),
            alignment: Alignment.center,
            child: Text(
              unread > 99 ? '99+' : '$unread',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 会话列表顶部固定的「收藏」入口: 不可滑动/删除, 星星图标 + 最新收藏预览
class _CollectionEntry extends StatelessWidget {
  const _CollectionEntry();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    // 最新一条收藏做副标题预览; 没有收藏时显示提示语
    final latest = c.collection.isNotEmpty ? c.collection.first : null;
    final preview = latest == null
        ? tr('collection_hint')
        : latest.kind == 'text'
            ? latest.content
            : latest.fileName;
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/collection'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 图标用 assets/collection.png, 底色统一中性灰 (不用多彩底色)
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.softOf(context),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Image.asset(
                'assets/collection.png',
                width: 26,
                height: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 1),
                  Text(
                    tr('collection'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.inkOf(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: AppTheme.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Empty({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    return Center(
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
            child: Icon(icon, size: 26, color: AppTheme.grey),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            style: const TextStyle(
              color: AppTheme.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _ctrl = TextEditingController();
  final _itemScrollCtrl = ItemScrollController();
  final _posListener = ItemPositionsListener.create();
  String? peerId;
  int? _highlightTs; // 搜索跳转定位的消息时间戳
  bool _showPanel = false; // + 号功能面板
  bool _dragging = false; // 桌面端拖入文件中
  bool _loadingMore = false; // 正在抓取更早一页历史
  List<ChatMessage>? _pendingOlder; // 已抓取待拼接的一页 (等滚动停止)
  bool _scrollActive = false; // 列表正在拖动/惯性滑动
  bool _userScrolled = false; // 上次拼接后用户是否滚动过 (防止静置时连续自动翻页)
  int _lastItemCount = 0; // 上次 build 的列表项数 (含顶部加载行)
  bool _atBottom = true; // 是否停留在消息列表底部
  int _newBelowCount = 0; // 不在底部时新到的消息数 (回到底部按钮角标)
  int _prevNewestTs = 0; // 上次 build 看到的最新消息时间戳
  RelayClient? _client; // 缓存引用, dispose 阶段不能再 context.read

  /// 桌面平台支持拖拽文件发送
  static final _dropEnabled =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _posListener.itemPositions.addListener(_onPositions);
  }

  void _onPositions() {
    // reverse 列表 index 0 = 底部 (最新消息)
    final positions = _posListener.itemPositions.value;
    if (positions.isNotEmpty) {
      final atBottom = positions.any((p) => p.index == 0);
      if (atBottom != _atBottom && mounted) {
        setState(() {
          _atBottom = atBottom;
          if (atBottom) _newBelowCount = 0;
        });
      }
    }
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    if (_loadingMore || _pendingOlder != null || peerId == null) return;
    final c = _client;
    if (c == null || c.hasMoreHistory[peerId] != true) return;
    final positions = _posListener.itemPositions.value;
    if (positions.isEmpty) return;
    // 预取: 可视区最顶部一条距列表顶端不足 10 项就开始加载,
    // 不等加载行完全露出, 滑到顶部时内容往往已拼好
    final maxIndex = positions.fold<int>(
      0,
      (m, p) => p.index > m ? p.index : m,
    );
    if (maxIndex < _lastItemCount - 1 - 10) return;
    // 必须有过真实滚动才翻页 (拼接后若加载行仍可见, 不自动连翻)
    if (!_userScrolled) return;
    _userScrolled = false;
    _loadingMore = true;
    final started = DateTime.now();
    // 只抓取不拼接: 滚动结束后再拼, 否则惯性滑动中列表变长会穿透多页
    c.fetchOlderHistory(peerId!).then((older) async {
      // 加载动画至少显示 500ms, 让加载过程可感知
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      if (elapsed < 500) {
        await Future.delayed(Duration(milliseconds: 500 - elapsed));
      }
      _loadingMore = false;
      if (older.isNotEmpty) {
        _pendingOlder = older;
        _flushPendingOlder();
      }
    });
  }

  /// 滚动停止后把待拼接的一页拼到列表前面
  void _flushPendingOlder() {
    final pending = _pendingOlder;
    if (pending == null || _scrollActive || !mounted) return;
    _pendingOlder = null;
    _client?.applyOlderHistory(peerId!, pending);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _client ??= context.read<RelayClient>();
    if (peerId == null) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is Map) {
        peerId = args['peerId'] as String;
        _highlightTs = args['highlightTs'] as int?;
      } else {
        peerId = args as String;
      }
      final c = _client!;
      c.activePeerId = peerId; // 正在查看此会话: 新消息不计未读
      c.loadHistory(peerId!).then((_) {
        if (!mounted) return; // 加载期间已退出页面 (跳转定位更不能跑)
        _prevNewestTs = _newestTsOf(c); // 已有历史不计入「新消息」角标
        _jumpToHighlight();
        c.sendReadReceipt(peerId!); // 打开会话即回已读 (以对方最新消息 ts 为已读位置)
      });
    }
  }

  /// 当前会话最新消息(含文件)的时间戳
  int _newestTsOf(RelayClient c) {
    var ts = 0;
    final msgs = c.chats[peerId] ?? <ChatMessage>[];
    if (msgs.isNotEmpty) ts = msgs.last.ts;
    for (final t in c.transfers) {
      if (!t.ephemeral && t.peerId == peerId && t.ts > ts) ts = t.ts;
    }
    return ts;
  }

  bool _badgePending = false; // 本帧已安排角标结算 (同帧多次 build 只结算一次)

  /// build 中不改状态: 列表项数记录与「回到底部」角标的累计推迟到帧后
  /// 执行; 数据在回调内重新读取, _atBottom 也按回调时刻判断 (更准确)
  void _scheduleBadgeUpdate(int itemCount) {
    if (_badgePending) return;
    _badgePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _badgePending = false;
      if (!mounted) return;
      final c = _client;
      if (c == null || peerId == null) return;
      _lastItemCount = itemCount;
      final newestTs = _newestTsOf(c);
      if (newestTs <= _prevNewestTs) return;
      var changed = false;
      if (_prevNewestTs != 0 && !_atBottom) {
        final msgs = c.chats[peerId] ?? <ChatMessage>[];
        final n =
            msgs.where((m) => m.ts > _prevNewestTs).length +
            c.transfers
                .where(
                  (t) =>
                      !t.ephemeral &&
                      t.peerId == peerId &&
                      t.ts > _prevNewestTs,
                )
                .length;
        if (n > 0) {
          _newBelowCount += n;
          changed = true;
        }
      }
      _prevNewestTs = newestTs;
      if (changed) setState(() {}); // 角标数字变化, 补一次重绘
    });
  }

  /// 当前应显示的文件传输记录。
  /// 文字消息还有更早的页没翻到时, 早于当前页边界的文件先不显示:
  /// 这样翻页拼接的新内容永远只出现在列表最前面, 已有内容索引不变,
  /// 视口不会跳动 (否则夹在中间的文件会让新拼的消息插到列表中部)
  List<FileTransfer> _visibleTransfers(RelayClient c) {
    final msgs = c.chats[peerId] ?? <ChatMessage>[];
    var boundary = 0;
    if (msgs.isNotEmpty && c.hasMoreHistory[peerId] == true) {
      boundary = msgs.first.ts;
    }
    return c.transfers
        .where((t) => !t.ephemeral && t.peerId == peerId && t.ts >= boundary)
        .toList();
  }

  @override
  void dispose() {
    _posListener.itemPositions.removeListener(_onPositions);
    final c = _client;
    if (c != null && c.activePeerId == peerId) c.activePeerId = null;
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _jumpToHighlight() async {
    if (_highlightTs == null) {
      _scrollToBottom();
      return;
    }
    final c = _client!;
    var target = -1;
    var items = <Object>[];
    // 目标消息可能不在已加载的页里: 逐页向上加载直到找到 (上限 40 页防极端卡死)
    for (var page = 0; page < 40; page++) {
      final msgs = c.chats[peerId] ?? <ChatMessage>[];
      final transfers = _visibleTransfers(c);
      items = _buildItems(msgs, transfers);
      // 找到目标在 items 中的位置(正序), 再换算成 reverse 列表的 index
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final ts = it is ChatMessage
            ? it.ts
            : (it is FileTransfer ? it.ts : null);
        if (ts == _highlightTs) {
          target = i;
          break;
        }
      }
      if (target >= 0 || c.hasMoreHistory[peerId] != true) break;
      await c.loadMoreHistory(peerId!);
    }
    if (target >= 0 && _itemScrollCtrl.isAttached) {
      _itemScrollCtrl.scrollTo(
        index: items.length - 1 - target,
        duration: const Duration(milliseconds: 300),
        alignment: 0.4,
      );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_itemScrollCtrl.isAttached) _itemScrollCtrl.jumpTo(index: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final msgs = c.chats[peerId] ?? <ChatMessage>[];
    final name = c.peerName(peerId!);
    final online = c.isOnline(peerId!);
    final transfers = _visibleTransfers(c);
    final items = _buildItems(msgs, transfers);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              online ? tr('online') : tr('offline'),
              style: TextStyle(
                fontSize: 11,
                color: online ? AppTheme.inkOf(context) : AppTheme.grey,
              ),
            ),
          ],
        ),
        actions: [
          // 远程文件浏览: Android (共享存储) 和 Windows (磁盘分区) 支持
          if (c.peers.any(
            (p) =>
                p.id == peerId &&
                (p.platform == 'android' || p.platform == 'windows'),
          ))
            IconButton(
              tooltip: tr('fs_title_short'),
              icon: const Icon(Icons.folder_open, size: 20),
              onPressed: () =>
                  Navigator.pushNamed(context, '/remote_fs', arguments: peerId),
            ),
          IconButton(
            tooltip: tr('search'),
            icon: const Icon(Icons.search, size: 20),
            onPressed: () =>
                Navigator.pushNamed(context, '/chat_search', arguments: peerId),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: _buildDropTarget(_buildChatBody(c, msgs, transfers, items, name)),
    );
  }

  /// 桌面端: 拖文件进窗口直接发送
  Widget _buildDropTarget(Widget child) {
    if (!_dropEnabled) return child;
    // 离线不能传文件: 整个拖放目标不启用 (系统直接显示禁止光标)
    if (!context.read<RelayClient>().isOnline(peerId!)) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        if (details.files.isEmpty) return;
        final c = context.read<RelayClient>();
        var sent = 0;
        for (final f in details.files) {
          if (await c.sendFile(peerId!, f.path)) sent++;
        }
        if (mounted) {
          AppToast.show(
            context,
            sent > 0 ? trf('sent_files', {'n': sent}) : tr('offline_files'),
          );
        }
      },
      child: Stack(
        children: [
          child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.isDark(context)
                        ? const Color(0xCC101010)
                        : const Color(0xCCFFFFFF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.green, width: 2),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.file_upload_outlined,
                          size: 40,
                          color: AppTheme.green,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tr('drop_to_send'),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.green,
                          ),
                        ),
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

  Widget _buildChatBody(
    RelayClient c,
    List<ChatMessage> msgs,
    List<FileTransfer> transfers,
    List<Object> items,
    String name,
  ) {
    // 有更早历史时, 顶部多一行加载指示 (reverse 列表的最后一个 index)
    final itemCount = items.length + (c.hasMoreHistory[peerId] == true ? 1 : 0);
    _scheduleBadgeUpdate(itemCount);
    // 离线: 文本可发 (排队补发), + 号文件面板禁用
    final online = c.isOnline(peerId!);
    return Container(
      color: AppTheme.chatBgOf(context),
      child: Column(
        children: [
          Expanded(
            // 点击消息区域 (面板外) 收起 + 号面板
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_showPanel) setState(() => _showPanel = false);
              },
              child: Stack(
                children: [
                  msgs.isEmpty && transfers.isEmpty
                      ? Center(
                          child: Text(
                            trf('say_hello', {'name': name}),
                            style: const TextStyle(
                              color: AppTheme.grey,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n is ScrollStartNotification) {
                              _scrollActive = true;
                            } else if (n is ScrollUpdateNotification) {
                              _userScrolled = true;
                            } else if (n is ScrollEndNotification) {
                              _scrollActive = false;
                              // 滚动停稳后才拼接更早的一页, 防止惯性穿透
                              _flushPendingOlder();
                            }
                            return false;
                          },
                          child: ScrollablePositionedList.builder(
                            itemScrollController: _itemScrollCtrl,
                            itemPositionsListener: _posListener,
                            reverse: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            // 有更早历史时, 顶部多一行加载指示 (reverse 列表的最后一个 index)
                            itemCount: itemCount,
                            itemBuilder: (_, i) {
                              // 顶部加载行 (仅 hasMore 时存在, 为最后一个 index)
                              if (i >= items.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 10),
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
                              final item = items[items.length - 1 - i];
                              if (item is String) return _TimeHeader(item);
                              if (item is FileTransfer) {
                                return _FileBubble(
                                  t: item,
                                  highlight: item.ts == _highlightTs,
                                  onLongPress: (r) =>
                                      _showTransferActions(context, c, item, r),
                                );
                              }
                              final m = item as ChatMessage;
                              return _Bubble(
                                message: m,
                                highlight: m.ts == _highlightTs,
                                onLongPress: (r) =>
                                    _showActions(context, c, m, r),
                              );
                            },
                          ),
                        ),
                  // 不在底部时: 右下角「回到底部」按钮, 带新消息角标
                  if (!_atBottom)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: _BackToBottomButton(
                        count: _newBelowCount,
                        onTap: () {
                          if (_itemScrollCtrl.isAttached) {
                            _itemScrollCtrl.jumpTo(index: 0);
                          }
                          setState(() {
                            _atBottom = true;
                            _newBelowCount = 0;
                          });
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          Container(
            color: AppTheme.softOf(context),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 文本消息离线也能发 (本地留存, 对方上线自动重发);
                  // 只有 + 号文件面板必须在线 (文件传输无法排队补发)
                  Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: Focus(
                                  onKeyEvent: (node, event) {
                                    // 桌面端: 回车发送, Shift+回车换行
                                    if (!_dropEnabled) {
                                      return KeyEventResult.ignored;
                                    }
                                    if (event is KeyDownEvent &&
                                        (event.logicalKey ==
                                                LogicalKeyboardKey.enter ||
                                            event.logicalKey ==
                                                LogicalKeyboardKey
                                                    .numpadEnter) &&
                                        !HardwareKeyboard
                                            .instance
                                            .isShiftPressed) {
                                      _send();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppTheme.bubbleOf(context),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: TextField(
                                      controller: _ctrl,
                                      minLines: 1,
                                      maxLines: 5,
                                      keyboardType: TextInputType.multiline,
                                      // 点输入框/开始输入时收起 + 号面板
                                      onTap: () {
                                        if (_showPanel) {
                                          setState(() => _showPanel = false);
                                        }
                                      },
                                      onChanged: (_) {
                                        if (_showPanel) {
                                          setState(() => _showPanel = false);
                                        }
                                      },
                                      decoration: InputDecoration(
                                        hintText: tr('input_hint'),
                                        hintStyle: const TextStyle(
                                          color: AppTheme.grey,
                                          fontSize: 15,
                                        ),
                                        filled: false,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  // 离线时 + 号不可点: 文件传输不能排队,
                                  // 面板开着也会被收起 (下面 panel 构建处)
                                  onTap: online
                                      ? () {
                                          FocusScope.of(context).unfocus();
                                          setState(
                                            () => _showPanel = !_showPanel,
                                          );
                                        }
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(
                                      _showPanel && online
                                          ? Icons.cancel_outlined
                                          : Icons.add_circle_outline,
                                      size: 30,
                                      color: !online
                                          ? AppTheme.grey.withValues(
                                              alpha: 0.35,
                                            )
                                          : AppTheme.isDark(context)
                                          ? AppTheme.grey
                                          : const Color(0xFF555555),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: _send,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF07C160),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      tr('send'),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                  // + 号面板: 展开/收起带高度+淡入动画
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) => SizeTransition(
                      sizeFactor: anim,
                      axisAlignment: -1,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    // 离线时 + 号不可点, 已展开的面板也一并收起
                    child: _showPanel && online
                        ? KeyedSubtree(
                            key: const ValueKey('panel'),
                            child: _buildPanel(),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 微信风格 + 号面板: 相册 / 拍照 / 拍视频 / 文件 / 文件夹
  Widget _buildPanel() {
    final picker = ImagePicker();
    // 开启压缩时先让选择器预缩到 2048 (Luban 再压更快); 关闭时拿真原图
    final maxW = context.read<RelayClient>().compressImages ? 2048.0 : null;
    final items = <(IconData, String, VoidCallback)>[
      (Icons.photo_outlined, tr('album'), _pickFromAlbum),
      (
        Icons.camera_alt_outlined,
        tr('take_photo'),
        () => _sendMedia(
          () => picker.pickImage(source: ImageSource.camera, maxWidth: maxW),
          tr('label_image'),
          image: true,
        ),
      ),
      (
        Icons.videocam_outlined,
        tr('take_video'),
        () => _sendMedia(
          () => picker.pickVideo(source: ImageSource.camera),
          tr('label_video'),
        ),
      ),
      (
        Icons.description_outlined,
        tr('files'),
        () {
          setState(() => _showPanel = false);
          _attachFiles();
        },
      ),
      (
        Icons.folder_outlined,
        tr('folder'),
        () {
          setState(() => _showPanel = false);
          _attachFolder();
        },
      ),
    ];
    final dark = AppTheme.isDark(context);
    Widget cell((IconData, String, VoidCallback) it) => InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: it.$3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF2A2A2A) : Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              it.$1,
              size: 30,
              color: dark ? const Color(0xFFAAAAAA) : const Color(0xFF555555),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            it.$2,
            style: TextStyle(
              fontSize: 12,
              color: dark ? const Color(0xFF888888) : const Color(0xFF777777),
            ),
          ),
        ],
      ),
    );
    // 固定每行 4 个均分宽度, 与设备屏宽无关 (Wrap 定宽排在窄屏会掉成 3 个)
    final rows = <Widget>[
      for (var i = 0; i < items.length; i += 4) ...[
        if (i > 0) const SizedBox(height: 26),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = i; j < i + 4; j++)
              Expanded(
                child: j < items.length ? cell(items[j]) : const SizedBox(),
              ),
          ],
        ),
      ],
    ];
    return Container(
      height: 278, // 两排图标的高度 (单元格 87x2 + 行距 26 + 上下 padding 74)
      padding: const EdgeInsets.fromLTRB(28, 34, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  /// 构建显示列表: 消息 + 文件传输记录 + 时间分隔 (>5分钟间隔显示时间,微信风格)
  List<Object> _buildItems(
    List<ChatMessage> msgs,
    List<FileTransfer> transfers,
  ) {
    final timed = <Object>[...msgs, ...transfers];
    timed.sort((a, b) {
      final ta = a is ChatMessage ? a.ts : (a as FileTransfer).ts;
      final tb = b is ChatMessage ? b.ts : (b as FileTransfer).ts;
      return ta.compareTo(tb);
    });
    final items = <Object>[];
    int? lastTs;
    for (final it in timed) {
      final ts = it is ChatMessage ? it.ts : (it as FileTransfer).ts;
      if (lastTs == null || ts - lastTs > 5 * 60 * 1000) {
        items.add(_timeLabel(DateTime.fromMillisecondsSinceEpoch(ts)));
      }
      lastTs = ts;
      items.add(it);
    }
    return items;
  }

  String _timeLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == today) return hm;
    if (day == today.subtract(const Duration(days: 1))) {
      return '${tr('yesterday')} $hm';
    }
    if (day.year == now.year) {
      return '${trf('date_md', {'m': d.month, 'd': d.day})} $hm';
    }
    return '${trf('date_ymd', {'y': d.year, 'm': d.month, 'd': d.day})} $hm';
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    final c = context.read<RelayClient>();
    // 不在线时消息留在本地, 对方上线 (中继或局域网) 后自动重发
    if (!c.isOnline(peerId!)) {
      AppToast.show(context, tr('offline_may_fail'));
    }
    c.sendChat(peerId!, t);
    _ctrl.clear();
    _scrollToBottom();
  }

  /// 发送文件 (可多选)
  Future<void> _attachFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths =
        r?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isEmpty || !mounted) return;
    final c = context.read<RelayClient>();
    var sent = 0;
    for (final p in paths) {
      if (await c.sendFile(peerId!, p)) sent++;
    }
    if (mounted) {
      AppToast.show(
        context,
        sent > 0 ? trf('sent_files', {'n': sent}) : tr('offline_files'),
      );
    }
  }

  /// 发送文件夹: 先打包成 zip (流式写盘), 发送完成后自动删除临时包
  Future<void> _attachFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;
    final c = context.read<RelayClient>();
    AppToast.show(context, tr('zipping'), sticky: true);
    try {
      final zip = await c.zipFolder(dir);
      final name =
          '${dir.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).last}.zip';
      final ok = await c.sendFile(
        peerId!,
        zip,
        isTemp: true,
        displayName: name,
      );
      if (mounted) {
        AppToast.show(
          context,
          ok ? trf('sent_folder', {'name': name}) : tr('offline_send'),
        );
      }
    } catch (_) {
      if (mounted) AppToast.show(context, tr('zip_fail'));
    }
  }

  /// 发送图片/视频 (从相册或拍摄拿到路径后走文件传输); image=true 走压缩通道
  Future<void> _sendMedia(
    Future<XFile?> Function() pick,
    String label, {
    bool image = false,
  }) async {
    setState(() => _showPanel = false);
    try {
      final f = await pick();
      final path = f?.path;
      if (path != null && mounted) {
        final c = context.read<RelayClient>();
        final ok = image
            ? await c.sendImage(peerId!, path)
            : await c.sendFile(peerId!, path);
        if (mounted) {
          AppToast.show(
            context,
            ok ? trf('sent_label', {'label': label}) : tr('offline_send'),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        AppToast.show(context, tr('unsupported'));
      }
    }
  }

  /// 相册: 手机端用应用内的微信风格图片选择器 (绕开系统文件选择器);
  /// 桌面端没有相册概念, 用带媒体类型过滤的文件对话框兜底
  Future<void> _pickFromAlbum() async {
    setState(() => _showPanel = false);
    List<String> paths;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final assets = await AssetPicker.pickAssets(
          context,
          pickerConfig: AssetPickerConfig(
            maxAssets: 20,
            requestType: RequestType.common, // 图片 + 视频
            themeColor: AppTheme.green,
            // 选择器界面语言跟随应用语言 (默认中文)
            textDelegate: l10n.isEn
                ? const EnglishAssetPickerTextDelegate()
                : const AssetPickerTextDelegate(),
          ),
        );
        if (assets == null || assets.isEmpty || !mounted) return;
        paths = [];
        for (final e in assets) {
          final f = await e.file;
          if (f != null) paths.add(f.path);
        }
      } else {
        final r = await FilePicker.platform.pickFiles(
          type: FileType.media,
          allowMultiple: true,
        );
        if (r == null || !mounted) return;
        paths = r.paths.whereType<String>().toList();
      }
    } catch (_) {
      if (mounted) {
        AppToast.show(context, tr('unsupported'));
      }
      return;
    }
    if (paths.isEmpty || !mounted) return;
    await _sendMediaPaths(paths, tr('media'));
  }

  /// 多选图片/视频发送: 图片走压缩通道, 视频发原文件
  Future<void> _sendMediaPaths(List<String> paths, String label) async {
    final c = context.read<RelayClient>();
    // 多选里只要带图片且开了压缩, 先提示一下 (大图压缩要一两秒)
    final compressing = c.compressImages && paths.any(isImageFile);
    if (compressing) {
      AppToast.show(context, tr('compressing'), sticky: true);
    }
    var sent = 0;
    for (final p in paths) {
      final ok = isImageFile(p)
          ? await c.sendImage(peerId!, p)
          : await c.sendFile(peerId!, p);
      if (ok) sent++;
    }
    if (mounted) {
      AppToast.show(
        context,
        sent > 0
            ? trf('sent_n_label', {'n': sent, 'label': label})
            : tr('offline_send'),
      );
    }
  }

  void _showTransferActions(
    BuildContext context,
    RelayClient c,
    FileTransfer t,
    Rect anchor,
  ) {
    // waiting 状态可取消删除; 传输中/校验中都禁止 (校验时删记录会毁掉合并)
    final busy =
        t.status == TransferStatus.accepted ||
        t.status == TransferStatus.transferring ||
        t.status == TransferStatus.verifying;
    showBubbleMenu(context, anchor, [
      // 收藏: 已完成的文件复制进收藏目录 (源文件没了会提示失败)
      if (t.status == TransferStatus.done && t.savePath != null)
        (
          label: tr('collect'),
          onTap: () async {
            final ok = await c.collectTransfer(
              t,
              t.outgoing ? tr('me') : c.peerName(t.peerId),
              peerId: t.outgoing ? '' : t.peerId,
              fromMe: t.outgoing,
            );
            if (context.mounted) {
              AppToast.show(context, tr(ok ? 'collected' : 'collect_fail'));
            }
          },
        ),
      if (!busy)
        (
          label: t.status == TransferStatus.waiting
              ? tr('cancel_and_delete')
              : tr('delete_record'),
          onTap: () => c.deleteTransfer(t),
        ),
    ]);
  }

  void _showActions(
    BuildContext context,
    RelayClient c,
    ChatMessage m,
    Rect anchor,
  ) {
    showBubbleMenu(context, anchor, [
      (
        label: tr('copy'),
        onTap: () {
          Clipboard.setData(ClipboardData(text: m.text));
          AppToast.show(context, tr('copied'));
        },
      ),
      (
        label: tr('collect'),
        onTap: () async {
          await c.collectText(
            m.text,
            m.fromMe ? tr('me') : c.peerName(m.peerId),
            peerId: m.fromMe ? '' : m.peerId,
            fromMe: m.fromMe,
          );
          if (context.mounted) AppToast.show(context, tr('collected'));
        },
      ),
      // 撤回: 仅我方 2 分钟内的消息 (与微信一致)
      if (c.canRecall(m))
        (
          label: tr('recall'),
          onTap: () async {
            final ok = await c.recallMessage(peerId!, m);
            if (!ok && context.mounted) {
              AppToast.show(context, tr('recall_too_late'));
            }
          },
        ),
      (label: tr('delete'), onTap: () => c.deleteMessage(peerId!, m)),
    ]);
  }
}

/// 微信风格时间分隔
class _TimeHeader extends StatelessWidget {
  final String label;
  const _TimeHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
      ),
    );
  }
}

/// 微信风格头像
class _Avatar extends StatelessWidget {
  final String name;
  final bool me;
  final String? peerId;
  const _Avatar({required this.name, required this.me, this.peerId});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    ImageProvider? imgProvider;
    if (me) {
      // 96px 缓存字节, 不再每条气泡全尺寸解码原图
      final bytes = c.ownAvatarBytes();
      if (bytes != null) imgProvider = MemoryImage(bytes);
    } else if (peerId != null) {
      final bytes = c.peerAvatarBytes(peerId!);
      if (bytes != null) imgProvider = MemoryImage(bytes);
    }
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: me ? const Color(0xFF07C160) : const Color(0xFF576B95),
        borderRadius: BorderRadius.circular(6),
        image: imgProvider != null
            ? DecorationImage(image: imgProvider, fit: BoxFit.cover)
            : null,
      ),
      child: imgProvider != null
          ? null
          : Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
    );
  }
}

/// 气泡小尾巴
class _Tail extends StatelessWidget {
  final Color color;
  final bool left;
  const _Tail({required this.color, required this.left});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(6, 10),
      painter: _TailPainter(color, left),
    );
  }
}

class _TailPainter extends CustomPainter {
  final Color color;
  final bool left;
  _TailPainter(this.color, this.left);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    if (left) {
      path.moveTo(size.width, 0);
      path.lineTo(0, size.height / 2);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width, size.height / 2);
      path.lineTo(0, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 聊天内的文件传输气泡 (微信风格)
class _FileBubble extends StatelessWidget {
  final FileTransfer t;
  final ValueChanged<Rect>? onLongPress; // 参数为气泡的全局矩形 (用于菜单定位)
  final bool highlight;
  const _FileBubble({
    required this.t,
    this.onLongPress,
    this.highlight = false,
  });

  /// exists 结果缓存: key = path|status, 状态翻转时自动重查。
  /// 不同步 stat (IO 高峰同步 stat 会卡 UI 线程出 ANR); 未命中先按
  /// false 渲染, 异步查好入缓存, 下一次自然重建 (进度 tick/状态变化) 生效
  static final Map<String, bool> _existsCache = {};

  static bool _fileExists(String path, TransferStatus st) {
    if (_existsCache.length > 500) _existsCache.clear(); // 兜底上限 (静态存活期长)
    final key = '$path|${st.name}';
    final hit = _existsCache[key];
    if (hit != null) {
      // 命中也后台复核: 文件可能后来被手动删掉, 翻回 false 下次重建生效
      File(path).exists().then((v) {
        if (_existsCache[key] != v) _existsCache[key] = v;
      });
      return hit;
    }
    _existsCache[key] = false;
    File(path).exists().then((v) {
      // 双向更新: 文件后来被删掉也要翻回 false, 否则气泡永远显示可打开
      if (_existsCache[key] != v) _existsCache[key] = v;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final fromMe = t.outgoing;
    final peerName = c.peerName(t.peerId);
    // 图片/视频本地预览 (仅传输完成且文件还在)
    final localPath = t.savePath;
    final hasLocal =
        t.status == TransferStatus.done &&
        localPath != null &&
        _fileExists(localPath, t.status);
    final showImg = hasLocal && isImageFile(t.fileName);
    final showVideo = hasLocal && isVideoFile(t.fileName);
    final showMedia = showImg || showVideo;

    // 媒体消息: 裸图显示, 不用气泡包裹; 文件消息: 描边卡片, 与文本气泡区分
    final Widget content;
    if (showMedia) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: showImg
            ? Image.file(
                File(localPath),
                width: 200,
                height: 140,
                fit: BoxFit.cover,
                // 限制解码分辨率: 4000px 原图全尺寸解码约 48MB, 列表多张会 OOM
                cacheWidth: 600,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              )
            : SizedBox(
                width: 200,
                height: 110,
                child: FutureBuilder<Uint8List?>(
                  future: VideoThumbs.get(localPath),
                  builder: (_, snap) => Stack(
                    fit: StackFit.expand,
                    children: [
                      if (snap.data != null)
                        Image.memory(snap.data!, fit: BoxFit.cover)
                      else
                        Container(color: Colors.black87),
                      const Center(
                        child: Icon(
                          Icons.play_circle_outline,
                          size: 42,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      );
    } else {
      content = Container(
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.62,
        ),
        decoration: BoxDecoration(
          color: AppTheme.cardOf(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.lineOf(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.isDark(context)
                        ? const Color(0xFF0E3B24)
                        : const Color(0xFFE7F6EC),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 20,
                    color: AppTheme.green,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.fileName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.bubbleInkOf(context),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_fmt(t.fileSize)} · ${_status(t.status)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (t.status == TransferStatus.transferring ||
                t.status == TransferStatus.accepted ||
                t.status == TransferStatus.verifying) ...[
              const SizedBox(height: 10),
              // 订阅轻量进度 tick: 5Hz 刷新只重建进度条, 不重建整个聊天列表
              ValueListenableBuilder<int>(
                valueListenable: c.progressTick,
                builder: (context, _, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: t.progress,
                    minHeight: 3,
                    color: AppTheme.green,
                    backgroundColor: AppTheme.lineOf(context),
                  ),
                ),
              ),
            ],
            if (!fromMe && t.status == TransferStatus.waiting) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _chip(context, tr('reject'), onTap: () => c.rejectFile(t)),
                  const SizedBox(width: 8),
                  _chip(
                    context,
                    tr('accept'),
                    filled: true,
                    onTap: () => c.acceptFile(t),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    }

    final bubble = Container(
      color: highlight ? const Color(0x3307C160) : null,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: fromMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!fromMe) ...[
            _Avatar(name: peerName, me: false, peerId: t.peerId),
            const SizedBox(width: 10),
          ],
          // 发出的文件被对方拒收 (对方已拉黑本机): 红色感叹号放气泡左侧, 点击重发
          if (fromMe && t.status == TransferStatus.rejected)
            Padding(
              padding: const EdgeInsets.only(top: 13, right: 4),
              child: GestureDetector(
                onTap: () => c.retrySend(t),
                child: const Icon(Icons.error, size: 17, color: AppTheme.red),
              ),
            ),
          Builder(
            builder: (bubbleCtx) => GestureDetector(
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress!(rectOf(bubbleCtx)),
              // 发出的文件本地本来就有, 任何状态都可打开; 收到的要等完成
              onTap: (t.outgoing || t.status == TransferStatus.done)
                  ? () => openTransfer(context, t)
                  : null,
              child: content,
            ),
          ),
          if (fromMe) ...[
            const SizedBox(width: 10),
            _Avatar(name: tr('me'), me: true),
          ],
        ],
      ),
    );
    // 被对方拉黑: 气泡下方加一条微信风格系统提示 (居中灰字)
    if (!fromMe || t.status != TransferStatus.rejected) return bubble;
    return Column(
      children: [
        bubble,
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            tr('blocked_notice'),
            style: const TextStyle(fontSize: 12, color: AppTheme.grey),
          ),
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context,
    String label, {
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: filled ? const Color(0xFF07C160) : null,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: filled ? const Color(0xFF07C160) : AppTheme.grey,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: filled ? Colors.white : AppTheme.bubbleInkOf(context),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  String _status(TransferStatus s) => switch (s) {
    TransferStatus.waiting => tr('st_waiting_confirm'),
    TransferStatus.accepted => tr('st_accepted'),
    TransferStatus.transferring => tr('st_transferring'),
    TransferStatus.verifying => tr('st_verifying'),
    TransferStatus.done => tr('st_done'),
    TransferStatus.rejected => tr('st_rejected'),
    TransferStatus.failed => tr('st_failed'),
    TransferStatus.canceled => tr('st_canceled'),
  };

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 微信风格文字气泡
class _Bubble extends StatefulWidget {
  final ChatMessage message;
  final ValueChanged<Rect> onLongPress; // 参数为气泡的全局矩形 (用于菜单定位)
  final bool highlight;
  const _Bubble({
    required this.message,
    required this.onLongPress,
    this.highlight = false,
  });

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  static const green = Color(0xFF95EC69);
  static final _urlRe = RegExp(r'(https?://[^\s]+)');

  // 每个 URL 一个手势识别器, 必须随 widget 生命周期 dispose;
  // TextSpan 按文本缓存, 重建时不变就不重新分配 (也不重建识别器)
  final List<TapGestureRecognizer> _recognizers = [];
  TextSpan? _span;
  String? _spanText;

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final c = context.read<RelayClient>();
    // 已撤回: 居中灰色占位条 (微信风格), 不显示气泡
    if (m.recalled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            m.fromMe ? tr('recalled_me') : tr('recalled_peer'),
            style: const TextStyle(fontSize: 12, color: AppTheme.grey),
          ),
        ),
      );
    }
    final bubbleColor = m.fromMe ? green : AppTheme.bubbleOf(context);
    final bubble = Container(
      color: widget.highlight ? const Color(0x3307C160) : null,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: m.fromMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!m.fromMe) ...[
            _Avatar(name: c.peerName(m.peerId), me: false, peerId: m.peerId),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _Tail(color: AppTheme.bubbleOf(context), left: true),
            ),
          ],
          // 被对方拒收 (对方已拉黑本机): 红色感叹号, 点击重发 (微信样式)
          // 状态图标放气泡左侧, 不挤在气泡和头像中间
          if (m.fromMe && m.rejected)
            Padding(
              padding: const EdgeInsets.only(top: 13, right: 4),
              child: GestureDetector(
                onTap: () => c.resendChat(m.peerId, m),
                child: const Icon(Icons.error, size: 17, color: AppTheme.red),
              ),
            )
          // 未送达标记 (对方上线后会自动重发)
          else if (m.fromMe && !m.delivered)
            const Padding(
              padding: EdgeInsets.only(top: 16, right: 4),
              child: Icon(Icons.schedule, size: 14, color: AppTheme.grey),
            )
          // 已读回执: 已送达未读=「未读」, 对方已读=「已读」
          else if (m.fromMe)
            Padding(
              padding: const EdgeInsets.only(top: 16, right: 4),
              child: Text(
                m.read ? tr('msg_read') : tr('msg_unread'),
                style: TextStyle(
                  fontSize: 10,
                  color: m.read ? AppTheme.green : AppTheme.grey,
                ),
              ),
            ),
          Flexible(
            child: Builder(
              builder: (bubbleCtx) => GestureDetector(
                onLongPress: () => widget.onLongPress(rectOf(bubbleCtx)),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text.rich(
                    _linkify(m.text),
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.35,
                      color: m.fromMe
                          ? Colors.black87
                          : AppTheme.bubbleInkOf(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (m.fromMe) ...[
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: _Tail(color: green, left: false),
            ),
            const SizedBox(width: 8),
            _Avatar(name: tr('me'), me: true),
          ],
        ],
      ),
    );
    // 被对方拉黑: 气泡下方加一条微信风格系统提示 (居中灰字)
    if (!m.fromMe || !m.rejected) return bubble;
    return Column(
      children: [
        bubble,
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            tr('blocked_notice'),
            style: const TextStyle(fontSize: 12, color: AppTheme.grey),
          ),
        ),
      ],
    );
  }

  TextSpan _linkify(String text) {
    if (_span != null && _spanText == text) return _span!;
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final spans = <TextSpan>[];
    var pos = 0;
    for (final match in _urlRe.allMatches(text)) {
      if (match.start > pos) {
        spans.add(TextSpan(text: text.substring(pos, match.start)));
      }
      final url = match.group(0)!;
      final rec = TapGestureRecognizer()
        ..onTap = () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      _recognizers.add(rec);
      spans.add(
        TextSpan(
          text: url,
          style: const TextStyle(
            color: Color(0xFF576B95),
            decoration: TextDecoration.underline,
          ),
          recognizer: rec,
        ),
      );
      pos = match.end;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    _spanText = text;
    return _span = TextSpan(children: spans);
  }
}

/// 「回到底部」悬浮按钮: 圆形白底向下箭头, 有新消息时右上角红色数字角标
class _BackToBottomButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _BackToBottomButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.cardOf(context),
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.lineOf(context)),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 4),
              ],
            ),
            child: Icon(
              Icons.arrow_downward,
              size: 20,
              color: AppTheme.inkOf(context),
            ),
          ),
          if (count > 0)
            Positioned(
              top: -5,
              right: -5,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.red,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
