import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_toast.dart';

/// 黑名单管理页 (微信「通讯录黑名单」风格):
/// 拉黑的设备 (点「移除」解除) + 拉黑的 IP (可手动添加/删除)
class BlocklistPage extends StatelessWidget {
  const BlocklistPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('blocklist')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 12),
          _sectionLabel(tr('blocked_devices')),
          Container(
            color: AppTheme.cardOf(context),
            child: c.blockedPeers.isEmpty
                ? _emptyRow(tr('blocklist_empty_devices'))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < c.blockedPeers.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            indent: 66,
                            color: AppTheme.lineOf(context),
                          ),
                        _BlockedPeerTile(id: c.blockedPeers.elementAt(i)),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          _sectionLabel(tr('blocked_ips')),
          Container(
            color: AppTheme.cardOf(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.blockedIps.isEmpty)
                  _emptyRow(tr('blocklist_empty_ips'))
                else
                  for (var i = 0; i < c.blockedIps.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 14,
                        color: AppTheme.lineOf(context),
                      ),
                    _BlockedIpTile(ip: c.blockedIps.elementAt(i)),
                  ],
                Divider(height: 1, color: AppTheme.lineOf(context)),
                InkWell(
                  onTap: () => _addIp(context, c),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.add, size: 17, color: AppTheme.green),
                        const SizedBox(width: 4),
                        Text(
                          tr('add_ip'),
                          style: const TextStyle(
                            fontSize: 14,
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
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              tr('add_ip_desc'),
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.grey,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(text, style: const TextStyle(fontSize: 12, color: AppTheme.grey)),
  );

  Widget _emptyRow(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 22),
    child: Center(
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: AppTheme.grey),
      ),
    ),
  );

  /// 手动添加拉黑 IP: 校验格式与重复
  Future<void> _addIp(BuildContext context, RelayClient c) async {
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardOf(ctx),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          tr('add_ip_title'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: tr('add_ip_hint')),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('ok')),
          ),
        ],
      ),
    );
    if (input == null || input.isEmpty || !context.mounted) return;
    if (InternetAddress.tryParse(input) == null) {
      AppToast.show(context, tr('invalid_ip'));
      return;
    }
    if (c.blockedIps.contains(input)) {
      AppToast.show(context, tr('ip_already_blocked'));
      return;
    }
    c.setIpBlocked(input, true);
  }
}

/// 被拉黑设备行: 头像 + 名字/ID + 移除按钮
class _BlockedPeerTile extends StatelessWidget {
  final String id;
  const _BlockedPeerTile({required this.id});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    // 优先用拉黑时缓存的名字 (对方离线时 peerName 只剩 ID 前 8 位)
    final name = c.blockedPeerNames[id] ?? c.peerName(id);
    final bytes = c.peerAvatarBytes(id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF576B95),
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
                      fontSize: 16,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: AppTheme.inkOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.grey,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _RemoveButton(onTap: () => c.setBlocked(id, false)),
        ],
      ),
    );
  }
}

/// 被拉黑 IP 行: 等宽字体地址 + 移除按钮
class _BlockedIpTile extends StatelessWidget {
  final String ip;
  const _BlockedIpTile({required this.ip});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ip,
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'monospace',
                color: AppTheme.inkOf(context),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _RemoveButton(onTap: () => c.setIpBlocked(ip, false)),
        ],
      ),
    );
  }
}

/// 描边药丸小按钮
class _RemoveButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RemoveButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppTheme.lineOf(context)),
        ),
        child: Text(
          tr('unblock'),
          style: TextStyle(fontSize: 12, color: AppTheme.inkOf(context)),
        ),
      ),
    );
  }
}
