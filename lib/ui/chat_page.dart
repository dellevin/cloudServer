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

import '../client.dart';
import '../db.dart';
import '../main.dart';
import '../models.dart';
import 'file_preview_page.dart';
import 'video_thumbs.dart';

/// 聊天标签页: 显示有会话记录的对端列表
class ChatsTabPage extends StatelessWidget {
  const ChatsTabPage({super.key});

  /// 会话最后一条预览: 文件消息显示 [图片]/[视频]/[文件] 样式
  static String _lastPreview(
    RelayClient c,
    String peerId,
    List<ChatMessage> msgs,
  ) {
    final lastMsgTs = msgs.isNotEmpty ? msgs.last.ts : 0;
    FileTransfer? lastFile;
    for (final t in c.transfers) {
      if (t.peerId == peerId && (lastFile == null || t.ts > lastFile.ts)) {
        lastFile = t;
      }
    }
    if (lastFile != null && lastFile.ts > lastMsgTs) {
      final name = lastFile.fileName;
      if (isImageFile(name)) return '[图片]';
      if (isVideoFile(name)) return '[视频]';
      return '[文件] $name';
    }
    return msgs.isNotEmpty ? msgs.last.text : '';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final ids = c.chats.keys.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Expanded(
          child: ids.isEmpty
              ? const _Empty(icon: Icons.forum_outlined, text: '暂无会话')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: ids.length,
                  itemBuilder: (_, i) {
                    final id = ids[i];
                    final msgs = c.chats[id]!;
                    final last = _lastPreview(c, id, msgs);
                    final n = c.unread[id] ?? 0;
                    final name = c.peerName(id);
                    final online = c.isOnline(id);
                    // 左滑露出删除按钮, 点击按钮再弹选项
                    return Slidable(
                      key: Key('conv_$id'),
                      endActionPane: ActionPane(
                        motion: const DrawerMotion(),
                        extentRatio: 0.24,
                        children: [
                          CustomSlidableAction(
                            onPressed: (_) => _confirmDeleteConversation(
                              context,
                              c,
                              id,
                              name,
                            ),
                            backgroundColor: Colors.transparent,
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                vertical: 5,
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
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppTheme.lineOf(context)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 2,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          leading: Builder(
                            builder: (_) {
                              final bytes = c.peerAvatarBytes(id);
                              final p = bytes != null
                                  ? MemoryImage(bytes)
                                  : null;
                              return Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: online
                                      ? AppTheme.green
                                      : AppTheme.softOf(context),
                                  borderRadius: BorderRadius.circular(6),
                                  border: online
                                      ? null
                                      : Border.all(
                                          color: AppTheme.lineOf(context),
                                        ),
                                  image: p != null
                                      ? DecorationImage(
                                          image: p,
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: p != null
                                    ? null
                                    : Text(
                                        name.isNotEmpty
                                            ? name[0].toUpperCase()
                                            : '?',
                                        style: TextStyle(
                                          color: online
                                              ? Colors.white
                                              : AppTheme.grey,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                              );
                            },
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.grey,
                            ),
                          ),
                          trailing: n > 0
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.red,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '$n',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                    ),
                                  ),
                                )
                              : null,
                          onTap: () => Navigator.pushNamed(
                            context,
                            '/chat',
                            arguments: id,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static void _confirmDeleteConversation(
    BuildContext context,
    RelayClient c,
    String peerId,
    String name,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardOf(context),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: AppTheme.lineOf(context)),
        ),
        title: const Text(
          '删除会话',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Text(
          '如何处理与 $name 的会话?',
          style: const TextStyle(fontSize: 13, color: AppTheme.grey),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, 'hide'),
            child: const Text('仅移除会话'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除全部记录'),
          ),
        ],
      ),
    );
    if (choice == 'hide') c.hideConversation(peerId);
    if (choice == 'delete') await c.deleteConversation(peerId);
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
      // 加载动画至少显示 2s, 让加载过程可感知
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      if (elapsed < 2000) {
        await Future.delayed(Duration(milliseconds: 2000 - elapsed));
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
        _prevNewestTs = _newestTsOf(c); // 已有历史不计入「新消息」角标
        _jumpToHighlight();
      });
    }
  }

  /// 当前会话最新消息(含文件)的时间戳
  int _newestTsOf(RelayClient c) {
    var ts = 0;
    final msgs = c.chats[peerId] ?? <ChatMessage>[];
    if (msgs.isNotEmpty) ts = msgs.last.ts;
    for (final t in c.transfers) {
      if (t.peerId == peerId && t.ts > ts) ts = t.ts;
    }
    return ts;
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
        .where((t) => t.peerId == peerId && t.ts >= boundary)
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
              online ? '在线' : '离线',
              style: TextStyle(
                fontSize: 11,
                color: online ? AppTheme.inkOf(context) : AppTheme.grey,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(sent > 0 ? '已发送 $sent 个文件请求' : '对方不在线, 无法发送文件'),
            ),
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
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.file_upload_outlined,
                          size: 40,
                          color: AppTheme.green,
                        ),
                        SizedBox(height: 8),
                        Text(
                          '松开鼠标发送文件',
                          style: TextStyle(
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
    _lastItemCount = items.length + (c.hasMoreHistory[peerId] == true ? 1 : 0);
    // 不在底部时来了新消息: 累计到「回到底部」按钮角标
    final newestTs = _newestTsOf(c);
    if (newestTs > _prevNewestTs) {
      if (_prevNewestTs != 0 && !_atBottom) {
        _newBelowCount +=
            msgs.where((m) => m.ts > _prevNewestTs).length +
            transfers.where((t) => t.ts > _prevNewestTs).length;
      }
      _prevNewestTs = newestTs;
    }
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
                            '开始和 $name 聊天吧',
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
                            itemCount: _lastItemCount,
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
                                  onLongPress: () =>
                                      _showTransferActions(context, c, item),
                                );
                              }
                              final m = item as ChatMessage;
                              return _Bubble(
                                message: m,
                                highlight: m.ts == _highlightTs,
                                onLongPress: () => _showActions(context, c, m),
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
                  c.connected
                      ? Padding(
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
                                      decoration: const InputDecoration(
                                        hintText: '输入消息…',
                                        hintStyle: TextStyle(
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
                                  onTap: () {
                                    FocusScope.of(context).unfocus();
                                    setState(() => _showPanel = !_showPanel);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(
                                      _showPanel
                                          ? Icons.cancel_outlined
                                          : Icons.add_circle_outline,
                                      size: 30,
                                      color: AppTheme.isDark(context)
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
                                    child: const Text(
                                      '发送',
                                      style: TextStyle(
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
                        )
                      : Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          alignment: Alignment.center,
                          child: const Text(
                            '中继未连接,无法发送消息',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.grey,
                            ),
                          ),
                        ),
                  if (_showPanel) _buildPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 微信风格 + 号面板: 相册 / 拍摄 / 拍视频 / 文件 / 文件夹
  Widget _buildPanel() {
    final picker = ImagePicker();
    final items = <(IconData, String, VoidCallback)>[
      (
        Icons.photo_library_outlined,
        '相册',
        () => _sendMediaMulti(
          () => picker.pickMultipleMedia(maxWidth: 2048),
          '媒体',
        ),
      ),
      (
        Icons.photo_camera_outlined,
        '拍摄',
        () => _sendMedia(
          () => picker.pickImage(source: ImageSource.camera, maxWidth: 2048),
          '图片',
        ),
      ),
      (
        Icons.videocam_outlined,
        '拍视频',
        () => _sendMedia(
          () => picker.pickVideo(source: ImageSource.camera),
          '视频',
        ),
      ),
      (
        Icons.insert_drive_file_outlined,
        '文件',
        () {
          setState(() => _showPanel = false);
          _attachFiles();
        },
      ),
      (
        Icons.folder_outlined,
        '文件夹',
        () {
          setState(() => _showPanel = false);
          _attachFolder();
        },
      ),
    ];
    final dark = AppTheme.isDark(context);
    return Container(
      height: 272, // 两排图标的高度
      padding: const EdgeInsets.fromLTRB(28, 34, 28, 40),
      child: Wrap(
        spacing: 26,
        runSpacing: 26,
        children: [
          for (final it in items)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: it.$3,
              child: SizedBox(
                width: 62,
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
                        color: dark
                            ? const Color(0xFFAAAAAA)
                            : const Color(0xFF555555),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      it.$2,
                      style: TextStyle(
                        fontSize: 12,
                        color: dark
                            ? const Color(0xFF888888)
                            : const Color(0xFF777777),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
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
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    if (day.year == now.year) return '${d.month}月${d.day}日 $hm';
    return '${d.year}年${d.month}月${d.day}日 $hm';
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    final c = context.read<RelayClient>();
    if (!c.connected) return;
    if (!c.isOnline(peerId!)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('对方当前离线,消息可能无法送达')));
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sent > 0 ? '已发送 $sent 个文件请求' : '对方不在线, 无法发送文件'),
        ),
      );
    }
  }

  /// 发送文件夹: 先打包成 zip (流式写盘), 发送完成后自动删除临时包
  Future<void> _attachFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final c = context.read<RelayClient>();
    messenger.showSnackBar(const SnackBar(content: Text('正在打包文件夹…')));
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
      messenger.showSnackBar(
        SnackBar(content: Text(ok ? '已发送文件夹: $name' : '对方不在线, 无法发送')),
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('文件夹打包失败')));
    }
  }

  /// 发送图片/视频 (从相册或拍摄拿到路径后走文件传输)
  Future<void> _sendMedia(Future<XFile?> Function() pick, String label) async {
    setState(() => _showPanel = false);
    try {
      final f = await pick();
      final path = f?.path;
      if (path != null && mounted) {
        final ok = await context.read<RelayClient>().sendFile(peerId!, path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ok ? '已发送$label' : '对方不在线, 无法发送')),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前平台不支持此功能')));
      }
    }
  }

  /// 从相册多选图片/视频发送
  Future<void> _sendMediaMulti(
    Future<List<XFile>> Function() pick,
    String label,
  ) async {
    setState(() => _showPanel = false);
    try {
      final files = await pick();
      if (files.isEmpty || !mounted) return;
      final c = context.read<RelayClient>();
      var sent = 0;
      for (final f in files) {
        if (await c.sendFile(peerId!, f.path)) sent++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sent > 0 ? '已发送 $sent 个$label' : '对方不在线, 无法发送'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前平台不支持此功能')));
      }
    }
  }

  void _showTransferActions(
    BuildContext context,
    RelayClient c,
    FileTransfer t,
  ) {
    // waiting 状态可取消删除; 只有真正在传输中才禁止
    final busy =
        t.status == TransferStatus.accepted ||
        t.status == TransferStatus.transferring;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardOf(context),
      constraints: const BoxConstraints(maxWidth: 250),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Container(width: 26, height: 3, color: AppTheme.lineOf(context)),
            const SizedBox(height: 2),
            ListTile(
              dense: true,
              minTileHeight: 34,
              horizontalTitleGap: 8,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const Icon(Icons.insert_drive_file_outlined, size: 15),
              title: Text(
                t.fileName,
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              dense: true,
              minTileHeight: 34,
              horizontalTitleGap: 8,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const Icon(Icons.delete_outline, size: 15),
              title: Text(
                busy
                    ? '传输进行中,暂不能删除'
                    : (t.status == TransferStatus.waiting ? '取消并删除记录' : '删除记录'),
                style: const TextStyle(fontSize: 12.5),
              ),
              enabled: !busy,
              onTap: () {
                Navigator.pop(ctx);
                c.deleteTransfer(t);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context, RelayClient c, ChatMessage m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardOf(context),
      constraints: const BoxConstraints(maxWidth: 250),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Container(width: 26, height: 3, color: AppTheme.lineOf(context)),
            const SizedBox(height: 2),
            ListTile(
              dense: true,
              minTileHeight: 34,
              horizontalTitleGap: 8,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const Icon(Icons.copy, size: 15),
              title: const Text('复制', style: TextStyle(fontSize: 12.5)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.text));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已复制')));
              },
            ),
            ListTile(
              dense: true,
              minTileHeight: 34,
              horizontalTitleGap: 8,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const Icon(Icons.delete_outline, size: 15),
              title: const Text('删除', style: TextStyle(fontSize: 12.5)),
              onTap: () {
                Navigator.pop(ctx);
                c.deleteMessage(peerId!, m);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
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
      final p = c.avatarPath;
      if (p.isNotEmpty && File(p).existsSync())
        imgProvider = FileImage(File(p));
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
  final VoidCallback? onLongPress;
  final bool highlight;
  const _FileBubble({
    required this.t,
    this.onLongPress,
    this.highlight = false,
  });

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
        File(localPath).existsSync();
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
                t.status == TransferStatus.accepted) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: t.progress,
                  minHeight: 3,
                  color: AppTheme.green,
                  backgroundColor: AppTheme.lineOf(context),
                ),
              ),
            ],
            if (!fromMe && t.status == TransferStatus.waiting) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _chip(context, '拒绝', onTap: () => c.rejectFile(t)),
                  const SizedBox(width: 8),
                  _chip(
                    context,
                    '接受',
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

    return Container(
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
          GestureDetector(
            onLongPress: onLongPress,
            onTap: t.status == TransferStatus.done
                ? () => openTransfer(context, t)
                : null,
            child: content,
          ),
          if (fromMe) ...[
            const SizedBox(width: 10),
            _Avatar(name: '我', me: true),
          ],
        ],
      ),
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

/// 微信风格文字气泡
class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onLongPress;
  final bool highlight;
  const _Bubble({
    required this.message,
    required this.onLongPress,
    this.highlight = false,
  });

  static const green = Color(0xFF95EC69);
  static final _urlRe = RegExp(r'(https?://[^\s]+)');

  @override
  Widget build(BuildContext context) {
    final m = message;
    final c = context.read<RelayClient>();
    final bubbleColor = m.fromMe ? green : AppTheme.bubbleOf(context);
    return Container(
      color: highlight ? const Color(0x3307C160) : null,
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
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
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
          // 未送达标记 (对方上线后会自动重发)
          if (m.fromMe && !m.delivered)
            const Padding(
              padding: EdgeInsets.only(top: 16, left: 4),
              child: Icon(Icons.schedule, size: 14, color: AppTheme.grey),
            ),
          if (m.fromMe) ...[
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: _Tail(color: green, left: false),
            ),
            const SizedBox(width: 8),
            _Avatar(name: '我', me: true),
          ],
        ],
      ),
    );
  }

  TextSpan _linkify(String text) {
    final spans = <TextSpan>[];
    var pos = 0;
    for (final match in _urlRe.allMatches(text)) {
      if (match.start > pos)
        spans.add(TextSpan(text: text.substring(pos, match.start)));
      final url = match.group(0)!;
      spans.add(
        TextSpan(
          text: url,
          style: const TextStyle(
            color: Color(0xFF576B95),
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        ),
      );
      pos = match.end;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(children: spans);
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
