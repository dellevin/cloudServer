import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';
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

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    // 下拉刷新: 重播局域网宣告 + 向中继重新注册换最新在线列表
    return Container(
      color: AppTheme.softOf(context),
      child: RefreshIndicator(
        color: AppTheme.green,
        onRefresh: () => c.refreshPeers(),
        child: ListView(
          // 列表不足一屏时也能下拉
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 10),
            // 分组头: 在线设备数
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
              child: Text(
                trf('online_devices', {'n': c.peers.length}),
                style: const TextStyle(fontSize: 12, color: AppTheme.grey),
              ),
            ),
            if (c.peers.isEmpty)
              Container(
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
                      child: const Icon(
                        Icons.radar,
                        size: 26,
                        color: AppTheme.grey,
                      ),
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
                      style: const TextStyle(
                        color: AppTheme.grey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )
            else
              // 在线设备: 通栏白块 + 行间细分隔线 (微信通讯录风格)
              Container(
                color: AppTheme.cardOf(context),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < c.peers.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          indent: 66,
                          color: AppTheme.lineOf(context),
                        ),
                      _PeerCard(peer: c.peers[i]),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// 在线设备行 (微信通讯录风格: 通栏, 头像 + 名字/徽标 + ID)
class _PeerCard extends StatelessWidget {
  final Peer peer;
  const _PeerCard({required this.peer});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final peerId = peer.id;
    final name = c.peerName(peerId);
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/chat', arguments: peerId),
      onLongPress: () => _showPeerOptions(context, c, peer),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Builder(
              builder: (_) {
                final bytes = c.peerAvatarBytes(peerId);
                final p = bytes != null ? MemoryImage(bytes) : null;
                return Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF576B95),
                    borderRadius: BorderRadius.circular(4),
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
                            fontSize: 15.5,
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
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    peerId,
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.grey,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: AppTheme.grey),
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

/// 长按设备弹出的选项: 信任开关 (信任的设备发来的文件自动接受)
void _showPeerOptions(BuildContext context, RelayClient c, Peer peer) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.cardOf(context),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
    ),
    builder: (ctx) => SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setSheet) {
          final trusted = c.isTrusted(peer.id);
          final blocked = c.isBlocked(peer.id);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              Center(
                child: Container(
                  width: 26,
                  height: 3,
                  color: AppTheme.lineOf(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    c.peerName(peer.id),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(
                  tr('trust_device'),
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    tr('trust_device_desc'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.grey,
                      height: 1.4,
                    ),
                  ),
                ),
                value: trusted,
                activeThumbColor: AppTheme.green,
                onChanged: (v) {
                  c.setTrusted(peer.id, v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(
                  tr('block_device'),
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    tr('block_device_desc'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.grey,
                      height: 1.4,
                    ),
                  ),
                ),
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
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    ),
  );
}
