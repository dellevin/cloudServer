import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return CustomScrollView(
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
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
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
                    '让其他设备连接同一中继服务器即可互相发现',
                    style: TextStyle(color: AppTheme.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: c.peers.length,
            itemBuilder: (_, i) => _PeerCard(peerId: c.peers[i].id),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }
}

class _PeerCard extends StatelessWidget {
  final String peerId;
  const _PeerCard({required this.peerId});

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
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
                    Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: AppTheme.inkOf(context),
                      ),
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
