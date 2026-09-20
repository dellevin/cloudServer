import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../db.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_toast.dart';
import 'bubble_menu.dart';
import 'file_preview_page.dart';
import 'video_thumbs.dart';

/// 收藏页 (消息列表顶部固定入口进入): 布局与聊天页一致 —
/// 气泡 + 头像 + 时间分隔 (>5 分钟), 自己收藏自己发的在右侧 (绿),
/// 收藏对方的在左侧 (白, 气泡上方带来源名, 群聊样式);
/// 文件点按打开, 长按气泡弹菜单 (复制/取消收藏);
/// 底部保留输入框: 文本/+ 号选文件都直接进收藏
class CollectionPage extends StatefulWidget {
  const CollectionPage({super.key});

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  final _ctrl = TextEditingController();

  /// 桌面平台: 回车发送, Shift+回车换行 (与聊天页一致)
  static final _desktopEnter =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    context.read<RelayClient>().collectText(t, tr('me'), fromMe: true);
    _ctrl.clear();
  }

  /// + 号: 选本地文件直接收藏 (复制进收藏目录)
  Future<void> _attach() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths =
        r?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isEmpty || !mounted) return;
    final c = context.read<RelayClient>();
    var ok = 0;
    for (final p in paths) {
      if (await c.collectFile(p, tr('me'))) ok++;
    }
    if (mounted) {
      AppToast.show(context, tr(ok > 0 ? 'collected' : 'collect_fail'));
    }
  }

  /// 与聊天页一致的时间分隔标签
  static String _timeLabel(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == today) return hm;
    if (day == today.subtract(const Duration(days: 1))) {
      return '${tr('yesterday')} $hm';
    }
    if (d.year == now.year) {
      return '${trf('date_md', {'m': d.month, 'd': d.day})} $hm';
    }
    return '${trf('date_ymd', {'y': d.year, 'm': d.month, 'd': d.day})} $hm';
  }

  /// 收藏按时间正序排列, 间隔 >5 分钟插时间头 (与聊天页 _buildItems 一致);
  /// 列表项为 String (时间头) / CollectionItem
  static List<Object> _buildItems(List<CollectionItem> desc) {
    final items = <Object>[];
    int? lastTs;
    for (final it in desc.reversed) {
      if (lastTs == null || it.ts - lastTs > 5 * 60 * 1000) {
        items.add(_timeLabel(it.ts));
      }
      lastTs = it.ts;
      items.add(it);
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final items = _buildItems(c.collection);
    return Scaffold(
      backgroundColor: AppTheme.chatBgOf(context),
      appBar: AppBar(
        title: Text(tr('collection')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Opacity(
                          opacity: 0.5,
                          child: Image.asset(
                            'assets/collection.png',
                            width: 44,
                            height: 44,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          tr('collection_empty'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.grey,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    // 与聊天页一致: 倒序列表, 最新一条在底部
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final item = items[items.length - 1 - i];
                      if (item is String) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              item,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF999999),
                              ),
                            ),
                          ),
                        );
                      }
                      return _CollectionBubble(item: item as CollectionItem);
                    },
                  ),
          ),
          // 底部输入栏: 与聊天页一致 (文本直接收藏, + 号选文件收藏)
          Container(
            color: AppTheme.softOf(context),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (!_desktopEnter) return KeyEventResult.ignored;
                          if (event is KeyDownEvent &&
                              (event.logicalKey == LogicalKeyboardKey.enter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.numpadEnter) &&
                              !HardwareKeyboard.instance.isShiftPressed) {
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
                        onTap: _attach,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.add_circle_outline,
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
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条收藏气泡: 方向/配色/头像全部对齐聊天页气泡
class _CollectionBubble extends StatelessWidget {
  final CollectionItem item;
  const _CollectionBubble({required this.item});

  static const green = Color(0xFF95EC69); // 与聊天页 _Bubble.green 一致

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  void _showMenu(BuildContext context, Rect anchor) {
    final c = context.read<RelayClient>();
    showBubbleMenu(context, anchor, [
      if (item.kind == 'text')
        (
          label: tr('copy'),
          onTap: () {
            Clipboard.setData(ClipboardData(text: item.content));
            AppToast.show(context, tr('copied'));
          },
        ),
      (
        label: tr('uncollect'),
        onTap: () async {
          await c.deleteCollectionItem(item);
          if (context.mounted) AppToast.show(context, tr('uncollected'));
        },
      ),
    ]);
  }

  Future<void> _open(BuildContext context) async {
    if (item.kind != 'file') return;
    if (!await File(item.content).exists()) {
      if (context.mounted) AppToast.show(context, tr('file_gone'));
      return;
    }
    if (!context.mounted) return;
    await openPath(context, item.content, item.fileName);
  }

  @override
  Widget build(BuildContext context) {
    final me = item.fromMe;
    final isText = item.kind == 'text';
    final isImage = !isText && isImageFile(item.fileName);
    final isVideo = !isText && isVideoFile(item.fileName);

    // 气泡内容: 文本 = 彩色气泡; 图片/视频 = 裸缩略图; 其他文件 = 描边卡片
    final Widget bubble;
    if (isText) {
      bubble = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: me ? green : AppTheme.bubbleOf(context),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          item.content,
          style: TextStyle(
            fontSize: 16,
            height: 1.35,
            color: me ? Colors.black87 : AppTheme.bubbleInkOf(context),
          ),
        ),
      );
    } else if (isImage || isVideo) {
      bubble = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: isImage
            ? Image.file(
                File(item.content),
                width: 200,
                height: 140,
                fit: BoxFit.cover,
                // 限制解码分辨率, 多张原图全尺寸解码会 OOM
                cacheWidth: 600,
                errorBuilder: (_, _, _) => _fileCard(context),
              )
            : SizedBox(
                width: 200,
                height: 110,
                child: FutureBuilder<Uint8List?>(
                  future: VideoThumbs.get(item.content),
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
      bubble = _fileCard(context);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: me
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!me) ...[
            _CollectionAvatar(
              name: item.fromName,
              me: false,
              peerId: item.peerId,
            ),
            const SizedBox(width: 8),
            if (isText)
              // 来源名占了气泡上方一行, 小尾巴下移对齐气泡
              Padding(
                padding: const EdgeInsets.only(top: 34),
                child: _Tail(color: AppTheme.bubbleOf(context), left: true),
              ),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: me
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                // 群聊样式来源名 (自己的不显示, 与聊天页一致)
                if (!me)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      item.fromName,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.grey,
                      ),
                    ),
                  ),
                Builder(
                  builder: (bubbleCtx) => GestureDetector(
                    onLongPress: () => _showMenu(context, rectOf(bubbleCtx)),
                    onTap: isText ? null : () => _open(context),
                    child: bubble,
                  ),
                ),
              ],
            ),
          ),
          if (me) ...[
            if (isText)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: _Tail(color: green, left: false),
              ),
            const SizedBox(width: 8),
            _CollectionAvatar(name: tr('me'), me: true),
          ],
        ],
      ),
    );
  }

  /// 非媒体文件: 描边卡片 (图标块 + 文件名 + 大小), 与聊天页文件消息一致
  Widget _fileCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.62,
      ),
      decoration: BoxDecoration(
        color: AppTheme.cardOf(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.lineOf(context)),
      ),
      child: Row(
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
                  item.fileName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.bubbleInkOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _fmt(item.fileSize),
                  style: const TextStyle(fontSize: 11, color: AppTheme.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 收藏页头像: 与聊天页 _Avatar 一致 (40px 圆角 6; 本机/对端头像, 无头像显首字母)
class _CollectionAvatar extends StatelessWidget {
  final String name;
  final bool me;
  final String? peerId;
  const _CollectionAvatar({required this.name, required this.me, this.peerId});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    ImageProvider? img;
    if (me) {
      final bytes = c.ownAvatarBytes();
      if (bytes != null) img = MemoryImage(bytes);
    } else if (peerId != null && peerId!.isNotEmpty) {
      final bytes = c.peerAvatarBytes(peerId!);
      if (bytes != null) img = MemoryImage(bytes);
    }
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: me ? const Color(0xFF07C160) : const Color(0xFF576B95),
        borderRadius: BorderRadius.circular(6),
        image: img != null
            ? DecorationImage(image: img, fit: BoxFit.cover)
            : null,
      ),
      child: img != null
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

/// 气泡小尾巴 (与聊天页 _Tail 一致)
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
