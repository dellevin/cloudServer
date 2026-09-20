import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';
import 'app_dialog.dart';
import 'app_toast.dart';

/// 设备平台图标: windows / android / macos / ios / linux, 未知给通用设备图标
IconData _platformIcon(String? platform) => switch (platform) {
  'windows' => Icons.window,
  'android' => Icons.android,
  'macos' => Icons.laptop_mac,
  'ios' => Icons.phone_iphone,
  'linux' => Icons.computer,
  _ => Icons.devices_other,
};

/// 设备页: 在线 + 历史设备合并列表 (在线排前), 顶部搜索 + 筛选
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _filter = 'all'; // all / online / trusted / blocked

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFilter() async {
    final v = await AppDialog.actions<String>(
      context,
      title: tr('filter'),
      actions: [
        AppDialogAction(tr('filter_all'), 'all', check: _filter == 'all'),
        AppDialogAction(
          tr('filter_online'),
          'online',
          check: _filter == 'online',
        ),
        AppDialogAction(
          tr('badge_trusted'),
          'trusted',
          check: _filter == 'trusted',
        ),
        AppDialogAction(
          tr('badge_blocked'),
          'blocked',
          check: _filter == 'blocked',
        ),
      ],
    );
    if (v != null && mounted) setState(() => _filter = v);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final offline = c.offlinePeers;
    // 在线 + 历史合并: 在线排前 (保持 peers 顺序), 未在线按最后在线倒序
    var items = [
      for (final p in c.peers) (peer: p, online: true),
      for (final p in offline) (peer: p, online: false),
    ];
    if (_filter == 'online') {
      items = items.where((e) => e.online).toList();
    } else if (_filter == 'trusted') {
      items = items.where((e) => c.isTrusted(e.peer.id)).toList();
    } else if (_filter == 'blocked') {
      items = items.where((e) => c.isBlocked(e.peer.id)).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items
          .where(
            (e) =>
                c.peerName(e.peer.id).toLowerCase().contains(q) ||
                e.peer.id.toLowerCase().contains(q),
          )
          .toList();
    }
    return Container(
      color: AppTheme.softOf(context),
      child: Column(
        children: [
          _searchRow(context),
          Expanded(
            // 下拉刷新: 重播局域网宣告 + 向中继重新注册换最新在线列表
            child: RefreshIndicator(
              color: AppTheme.green,
              onRefresh: () => c.refreshPeers(),
              child: ListView(
                // 列表不足一屏时也能下拉
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 10),
                  if (c.peers.isEmpty && offline.isEmpty)
                    _emptyState(context)
                  else if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 60),
                      child: Center(
                        child: Text(
                          tr('device_no_match'),
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    // 通栏白块 + 行间细分隔线 (微信通讯录风格)
                    Container(
                      color: AppTheme.cardOf(context),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0)
                              Divider(
                                height: 1,
                                indent: 68,
                                color: AppTheme.lineOf(context),
                              ),
                            _PeerCard(
                              peer: items[i].peer,
                              offline: !items[i].online,
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (items.isNotEmpty)
                    // 微信通讯录同款底部总数
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          trf('device_count', {'n': items.length}),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.grey,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部搜索栏 + 筛选块 (与聊天搜索页同款: 白圆角盒内裸 TextField,
  /// 桌面端必须显式清掉 enabled/focused border 和填充, 否则会浮一层白边)
  Widget _searchRow(BuildContext context) {
    final active = _filter != 'all';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
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
                      controller: _searchCtrl,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.inkOf(context),
                      ),
                      decoration: InputDecoration(
                        hintText: tr('device_search_hint'),
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
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                      child: const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(
                          Icons.cancel,
                          size: 16,
                          color: AppTheme.grey,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 筛选块: 显示当前选中项 (激活时绿字), 点按弹窗切换
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _pickFilter,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppTheme.cardOf(context),
                borderRadius: BorderRadius.circular(6),
                border: active
                    ? Border.all(color: AppTheme.green.withValues(alpha: 0.5))
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    switch (_filter) {
                      'online' => tr('filter_online'),
                      'trusted' => tr('badge_trusted'),
                      'blocked' => tr('badge_blocked'),
                      _ => tr('filter_all'),
                    },
                    style: TextStyle(
                      fontSize: 13,
                      color: active ? AppTheme.green : AppTheme.inkOf(context),
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: active ? AppTheme.green : AppTheme.grey,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 从未发现过任何设备时的空态
  Widget _emptyState(BuildContext context) {
    return Container(
      color: AppTheme.cardOf(context),
      padding: const EdgeInsets.symmetric(vertical: 40),
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
            child: const Icon(Icons.radar, size: 26, color: AppTheme.grey),
          ),
          const SizedBox(height: 14),
          Text(
            tr('no_devices'),
            style: TextStyle(
              color: AppTheme.inkOf(context),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            tr('no_devices_hint'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 在线设备行 (微信通讯录风格: 通栏, 头像 + 名字/徽标 + ID)
/// offline = true: 历史设备行 — 灰色头像 + 「未在线」徽标, 长按可删除
class _PeerCard extends StatelessWidget {
  final Peer peer;
  final bool offline;
  const _PeerCard({required this.peer, this.offline = false});

  // 灰度滤镜: 离线设备的彩色头像去色
  static const _greyscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final peerId = peer.id;
    final name = c.peerName(peerId);
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/chat', arguments: peerId),
      onLongPress: () => _showPeerOptions(context, c, peer, deletable: offline),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Builder(
              builder: (_) {
                final bytes = c.peerAvatarBytes(peerId);
                final p = bytes != null ? MemoryImage(bytes) : null;
                final avatar = Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: offline
                        ? AppTheme.grey
                        : const Color(0xFF576B95),
                    borderRadius: BorderRadius.circular(5),
                    image: p != null
                        ? DecorationImage(image: p, fit: BoxFit.cover)
                        : null,
                  ),
                  child: p != null
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
                return offline
                    ? ColorFiltered(colorFilter: _greyscale, child: avatar)
                    : avatar;
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 16,
                            color: AppTheme.inkOf(context),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Tooltip(
                        message: peer.platform ?? tr('unknown_platform'),
                        child: Icon(
                          _platformIcon(peer.platform),
                          size: 13.5,
                          color: AppTheme.grey,
                        ),
                      ),
                      if (c.isTrusted(peerId)) ...[
                        const SizedBox(width: 6),
                        _ChannelBadge(
                          tr('badge_trusted'),
                          const Color(0xFFC9A227),
                        ),
                      ],
                      if (c.isBlocked(peerId)) ...[
                        const SizedBox(width: 6),
                        _ChannelBadge(tr('badge_blocked'), AppTheme.red),
                      ],
                      if (offline) ...[
                        const SizedBox(width: 6),
                        _ChannelBadge(tr('badge_offline'), AppTheme.grey),
                      ],
                      if (peer.viaLan) ...[
                        const SizedBox(width: 6),
                        _ChannelBadge(tr('badge_lan'), AppTheme.green),
                      ],
                      if (peer.viaRelay) ...[
                        const SizedBox(width: 6),
                        _ChannelBadge(
                          tr('badge_relay'),
                          const Color(0xFF576B95),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    peerId,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.grey,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
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

/// 设备来源徽标 (局域网 / 中继)
class _ChannelBadge extends StatelessWidget {
  final String text;
  final Color color;
  const _ChannelBadge(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 9, color: color, letterSpacing: 0.5),
      ),
    );
  }
}

/// 长按设备弹出的选项: 信任/拉黑开关 (圆角灰块行, 与 AppDialog 选项同一风格);
/// deletable (离线设备) 时底部带浅红删除块
void _showPeerOptions(
  BuildContext context,
  RelayClient c,
  Peer peer, {
  bool deletable = false,
}) {
  AppDialog.custom(
    context,
    title: c.peerName(peer.id),
    child: StatefulBuilder(
      builder: (ctx, setSheet) {
        final trusted = c.isTrusted(peer.id);
        final blocked = c.isBlocked(peer.id);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _peerOptionBlock(
                ctx,
                title: tr('trust_device'),
                desc: tr('trust_device_desc'),
                trailing: Switch(
                  value: trusted,
                  activeThumbColor: AppTheme.green,
                  onChanged: (v) {
                    c.setTrusted(peer.id, v);
                    setSheet(() {});
                  },
                ),
              ),
              const SizedBox(height: 6),
              _peerOptionBlock(
                ctx,
                title: tr('block_device'),
                desc: tr('block_device_desc'),
                trailing: Switch(
                  value: blocked,
                  activeThumbColor: AppTheme.red,
                  onChanged: (v) {
                    c.setBlocked(peer.id, v);
                    setSheet(() {});
                    AppToast.show(
                      context,
                      v
                          ? trf('blocked_toast', {'name': c.peerName(peer.id)})
                          : tr('unblocked_toast'),
                    );
                  },
                ),
              ),
              if (deletable) ...[
                const SizedBox(height: 6),
                Material(
                  color: AppTheme.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () async {
                      final ok = await AppDialog.confirm(
                        ctx,
                        title: tr('delete_device'),
                        message: tr('delete_device_confirm'),
                        danger: true,
                      );
                      if (ok && ctx.mounted) {
                        Navigator.pop(ctx);
                        await c.removeKnownPeer(peer.id);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 14,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('delete_device'),
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.red,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: AppTheme.red,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

/// 设备选项弹窗里的圆角灰块行: 左侧标题+说明, 右侧挂件 (开关)
Widget _peerOptionBlock(
  BuildContext ctx, {
  required String title,
  required String desc,
  required Widget trailing,
}) {
  return Material(
    color: AppTheme.softOf(ctx),
    borderRadius: BorderRadius.circular(10),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.inkOf(ctx),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.grey,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    ),
  );
}
