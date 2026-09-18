import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    // 下拉刷新: 重播局域网宣告 + 向中继重新注册换最新在线列表
    return RefreshIndicator(
      color: AppTheme.green,
      onRefresh: () => c.refreshPeers(),
      child: CustomScrollView(
        // 列表不足一屏时也能下拉
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // 本机信息 (微信绿填充卡片, 与在线设备的描边卡片区分)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.green,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Builder(
                    builder: (_) {
                      final hasAvatar =
                          c.avatarPath.isNotEmpty &&
                          File(c.avatarPath).existsSync();
                      return Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24),
                          image: hasAvatar
                              ? DecorationImage(
                                  image: FileImage(File(c.avatarPath)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: hasAvatar
                            ? null
                            : Text(
                                c.deviceName.isNotEmpty
                                    ? c.deviceName[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
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
                                c.deviceName,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.white38),
                              ),
                              child: Text(
                                c.connected ? '在线' : '离线',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.white70,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: c.deviceId));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('设备 ID 已复制')),
                            );
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  c.deviceId,
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    color: Colors.white54,
                                    fontFamily: 'monospace',
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.copy,
                                size: 11,
                                color: Colors.white54,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '在线设备 · ${c.peers.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.grey,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => showAddManualPeerDialog(context),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_link, size: 14, color: AppTheme.green),
                          SizedBox(width: 3),
                          Text(
                            '手动添加',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (c.peers.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
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
                      '未发现其他设备',
                      style: TextStyle(
                        color: AppTheme.inkOf(context),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '让其他设备连接同一中继服务器\n或与本机接入同一局域网即可互相发现',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: c.peers.length,
              itemBuilder: (_, i) => _PeerCard(peer: c.peers[i]),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
      ),
    );
  }
}

class _PeerCard extends StatelessWidget {
  final Peer peer;
  const _PeerCard({required this.peer});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final peerId = peer.id;
    final name = c.peerName(peerId);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.lineOf(context)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => Navigator.pushNamed(context, '/chat', arguments: peerId),
        onLongPress: () => _showPeerOptions(context, c, peer),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Builder(
                builder: (_) {
                  final bytes = c.peerAvatarBytes(peerId);
                  final p = bytes != null ? MemoryImage(bytes) : null;
                  return Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF576B95),
                      borderRadius: BorderRadius.circular(6),
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
                              fontSize: 15,
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
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: AppTheme.inkOf(context),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (peer.viaLan) ...[
                          const SizedBox(width: 6),
                          _ChannelBadge('局域网', AppTheme.green),
                        ],
                        if (peer.viaRelay) ...[
                          const SizedBox(width: 6),
                          _ChannelBadge('中继', const Color(0xFF576B95)),
                        ],
                        if (c.isTrusted(peerId)) ...[
                          const SizedBox(width: 6),
                          _ChannelBadge('信任', const Color(0xFFC9A227)),
                        ],
                      ],
                    ),
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
                title: const Text('信任此设备', style: TextStyle(fontSize: 14)),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    '开启后，该设备发来的文件将自动接受，不再弹窗询问',
                    style: TextStyle(
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
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    ),
  );
}

/// 「手动添加设备」对话框: 输入对端 IP[:端口] 强制建立局域网直连。
/// 用于广播不可达的场景 (如 Android 模拟器, 填 10.0.2.2 可连宿主机)。
/// 设备页和设置页共用。
Future<void> showAddManualPeerDialog(BuildContext context) async {
  final c = context.read<RelayClient>();
  final ctrl = TextEditingController();
  final input = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.cardOf(context),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text(
        '手动添加设备',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: '例如 192.168.1.5'),
            onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
          ),
          const SizedBox(height: 10),
          const Text(
            '输入对方「设置 → 本机 IP」里看到的地址。\nAndroid 模拟器填 10.0.2.2 可连接宿主机。',
            style: TextStyle(fontSize: 11, color: AppTheme.grey, height: 1.5),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      actions: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('连接'),
        ),
      ],
    ),
  );
  if (input == null || input.isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('正在连接…')));
  final peerId = await c.addManualLanPeer(input);
  messenger.hideCurrentSnackBar();
  if (peerId != null) {
    messenger.showSnackBar(
      SnackBar(content: Text('已连接设备: ${c.peerName(peerId)}')),
    );
  } else {
    messenger.showSnackBar(
      const SnackBar(content: Text('连接失败，请确认对方已运行 cloudSend 且地址正确')),
    );
  }
}
