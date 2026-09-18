import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../db.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';

/// 聊天搜索页: 搜索文字消息和文件传输记录, 点击跳转到对应聊天位置
/// 不带参数打开时为全局搜索 (所有会话 + 全部传输记录)
class ChatSearchPage extends StatefulWidget {
  const ChatSearchPage({super.key});

  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends State<ChatSearchPage> {
  final _ctrl = TextEditingController();
  String? peerId; // null = 全局搜索
  bool _argLoaded = false;
  String _query = '';
  int _filter = 0; // 0=全部 1=聊天 2=文件
  List<ChatMessage> _msgResults = []; // DB 全文搜索结果 (聊天记录分页加载,不能只在内存搜)
  int _searchToken = 0; // 防止异步结果乱序覆盖

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_argLoaded) {
      peerId = ModalRoute.of(context)!.settings.arguments as String?;
      _argLoaded = true;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 消息搜索走数据库 LIKE (内存里只加载了最近一页, 搜不全)
  Future<void> _refreshMessages() async {
    final q = _query.trim();
    final token = ++_searchToken;
    if (_filter == 2 || q.isEmpty) {
      setState(() => _msgResults = []);
      return;
    }
    final r = await ChatDb.search(q, peerId: peerId);
    if (mounted && token == _searchToken) {
      setState(() => _msgResults = r);
    }
  }

  void _jump(Object item) {
    final ts = item is ChatMessage ? item.ts : (item as FileTransfer).ts;
    final pid = item is ChatMessage
        ? item.peerId
        : (item as FileTransfer).peerId;
    final nav = Navigator.of(context);
    // 清回首页再进聊天: 从聊天页内进入搜索时, pushReplacement 会把旧 ChatPage
    // 留在栈里 (dispose 时误清 activePeerId, 正在看的会话也累计未读)
    nav.popUntil((route) => route.isFirst);
    nav.pushNamed('/chat', arguments: {'peerId': pid, 'highlightTs': ts});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final q = _query.trim().toLowerCase();
    // 文件传输记录: 「文件」筛选下空关键词也列出全部记录
    final List<FileTransfer> files;
    if (_filter == 1 || (q.isEmpty && _filter != 2)) {
      files = <FileTransfer>[];
    } else {
      files = c.visibleTransfers.where((t) {
        if (peerId != null && t.peerId != peerId) return false;
        return q.isEmpty || t.fileName.toLowerCase().contains(q);
      }).toList();
    }
    final results = <Object>[..._msgResults, ...files]
      ..sort((a, b) {
        final ta = a is ChatMessage ? a.ts : (a as FileTransfer).ts;
        final tb = b is ChatMessage ? b.ts : (b as FileTransfer).ts;
        return tb.compareTo(ta);
      });

    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        backgroundColor: AppTheme.softOf(context),
        titleSpacing: 0,
        title: Container(
          height: 36,
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardOf(context),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, size: 18, color: AppTheme.grey),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.inkOf(context),
                  ),
                  decoration: InputDecoration(
                    hintText: tr('search'),
                    hintStyle: const TextStyle(
                      fontSize: 14,
                      color: AppTheme.grey,
                    ),
                    filled: false,
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: (v) {
                    setState(() => _query = v);
                    _refreshMessages();
                  },
                ),
              ),
              if (_query.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _ctrl.clear();
                    setState(() => _query = '');
                    _refreshMessages();
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.cancel, size: 16, color: AppTheme.grey),
                  ),
                ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // 筛选: 全部 / 聊天 / 文件
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                _filterChip(tr('filter_all'), 0),
                const SizedBox(width: 8),
                _filterChip(tr('filter_chat'), 1),
                const SizedBox(width: 8),
                _filterChip(tr('filter_file'), 2),
              ],
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? _Hint(
                    icon: q.isEmpty
                        ? Icons.search
                        : Icons.find_in_page_outlined,
                    text: q.isEmpty
                        ? (_filter == 2 ? tr('no_transfers') : tr('search_tip'))
                        : tr('no_match'),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: results.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 68, endIndent: 16),
                    itemBuilder: (_, i) {
                      final it = results[i];
                      return it is ChatMessage
                          ? _ResultTile.message(
                              m: it,
                              q: q,
                              onTap: () => _jump(it),
                            )
                          : _ResultTile.file(
                              t: it as FileTransfer,
                              q: q,
                              onTap: () => _jump(it),
                            );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, int idx) {
    final selected = _filter == idx;
    return GestureDetector(
      onTap: () {
        setState(() => _filter = idx);
        _refreshMessages();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppTheme.green : AppTheme.cardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppTheme.green : AppTheme.lineOf(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppTheme.grey,
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: AppTheme.lineOf(context)),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(fontSize: 13, color: AppTheme.grey),
          ),
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  final Widget leading;
  final String? senderPeerId;
  final bool fromMe;
  final String title;
  final String subtitle;
  final String time;
  final String q;
  final bool titleIsFile;
  final VoidCallback onTap;

  const _ResultTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.q,
    required this.onTap,
    this.titleIsFile = false,
    this.senderPeerId,
    this.fromMe = false,
  });

  factory _ResultTile.message({
    required ChatMessage m,
    required String q,
    required VoidCallback onTap,
  }) {
    return _ResultTile(
      leading: _MsgAvatar(peerId: m.peerId, fromMe: m.fromMe),
      title: m.fromMe ? tr('me') : '',
      subtitle: m.text,
      time: _fmtTime(m.ts),
      q: q,
      onTap: onTap,
      titleIsFile: false,
      senderPeerId: m.peerId,
      fromMe: m.fromMe,
    );
  }

  factory _ResultTile.file({
    required FileTransfer t,
    required String q,
    required VoidCallback onTap,
  }) {
    return _ResultTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppTheme.green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(
          Icons.insert_drive_file_outlined,
          size: 22,
          color: AppTheme.green,
        ),
      ),
      title: t.fileName,
      subtitle: t.outgoing ? tr('file_out') : tr('file_in'),
      time: _fmtTime(t.ts),
      q: q,
      onTap: onTap,
      titleIsFile: true,
      senderPeerId: t.peerId,
      fromMe: t.outgoing,
    );
  }

  static String _fmtTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == today) return hm;
    if (day == today.subtract(const Duration(days: 1))) return tr('yesterday');
    if (day.year == now.year) return trf('date_md', {'m': d.month, 'd': d.day});
    return trf('date_ymd', {'y': d.year, 'm': d.month, 'd': d.day});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final displayTitle = titleIsFile
        ? title
        : (fromMe ? tr('me') : c.peerName(senderPeerId ?? ''));
    final displaySubtitle = titleIsFile && senderPeerId != null
        ? '${fromMe ? trf('sent_to', {'name': c.peerName(senderPeerId!)}) : trf('recv_from', {'name': c.peerName(senderPeerId!)})} · $subtitle'
        : subtitle;
    return Material(
      color: AppTheme.cardOf(context),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayTitle,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.inkOf(context),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          time,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text.rich(
                      _highlight(displaySubtitle, q),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: AppTheme.grey,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  TextSpan _highlight(String text, String q) {
    if (q.isEmpty) return TextSpan(text: text);
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    var pos = 0;
    while (true) {
      final i = lower.indexOf(q, pos);
      if (i < 0) break;
      if (i > pos) spans.add(TextSpan(text: text.substring(pos, i)));
      spans.add(
        TextSpan(
          text: text.substring(i, i + q.length),
          style: const TextStyle(
            color: Color(0xFF07C160),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      pos = i + q.length;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(children: spans);
  }
}

class _MsgAvatar extends StatelessWidget {
  final String peerId;
  final bool fromMe;
  const _MsgAvatar({required this.peerId, required this.fromMe});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    ImageProvider? p;
    if (fromMe) {
      if (c.avatarPath.isNotEmpty && File(c.avatarPath).existsSync()) {
        p = FileImage(File(c.avatarPath));
      }
    } else {
      final bytes = c.peerAvatarBytes(peerId);
      if (bytes != null) p = MemoryImage(bytes);
    }
    final name = fromMe ? c.deviceName : c.peerName(peerId);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fromMe ? const Color(0xFF07C160) : const Color(0xFF576B95),
        borderRadius: BorderRadius.circular(6),
        image: p != null ? DecorationImage(image: p, fit: BoxFit.cover) : null,
      ),
      child: p != null
          ? null
          : Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
    );
  }
}
