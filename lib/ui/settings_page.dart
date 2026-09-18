import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';
import 'devices_page.dart';

/// 设置页 (微信「我 → 设置」风格: 灰底 + 通栏白色分组)
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: const Text('设置'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // ---- 个人信息大卡 ----
          const _ProfileCard(),
          const SizedBox(height: 10),

          // ---- 功能模式 ----
          _Group(
            children: [
              _Tile(
                icon: Icons.alt_route,
                title: '功能模式',
                value: switch (c.connMode) {
                  'relay' => '仅中继',
                  'lan' => '仅局域网',
                  _ => '局域网 + 中继',
                },
                onTap: () => _pickConnMode(context, c),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ---- 中继服务器 (仅局域网模式下隐藏) ----
          if (c.connMode != 'lan') ...[
            _Group(
              children: [
                _Tile(
                  icon: Icons.dns_outlined,
                  title: '服务器',
                  value: c.serverAddr.isEmpty ? '未设置' : c.serverAddr,
                  // 连接中也可编辑, 保存后自动断开旧连接并重连新地址
                  onTap: () => _editField(
                    context,
                    title: '服务器地址',
                    hint: '例如 1.2.3.4:8787 或 ws://example.com/ws',
                    initial: c.serverAddr,
                    onSubmit: (v) {
                      if (v.isNotEmpty) c.connect(v);
                    },
                  ),
                ),
                _ServerStatusTile(),
              ],
            ),
            const SizedBox(height: 10),
          ],

          // ---- 局域网 (仅中继模式下隐藏) ----
          if (c.connMode != 'relay') ...[
            const _NetworkGroup(),
            const SizedBox(height: 10),
          ],

          // ---- 通用 ----
          _Group(
            children: [
              _Tile(
                icon: Icons.swap_vert,
                title: '传输记录',
                onTap: () => Navigator.pushNamed(context, '/transfers'),
              ),
              const _SaveDirTile(),
              const _ClearCacheTile(),
              _Tile(
                icon: Icons.playlist_play,
                title: '多文件排队发送',
                trailing: Switch(
                  value: c.queueSends,
                  onChanged: (v) => c.setQueueSends(v),
                ),
                onTap: () => c.setQueueSends(!c.queueSends),
              ),
              _Tile(
                icon: Icons.dark_mode_outlined,
                title: '深色模式',
                trailing: Switch(
                  value: c.darkMode,
                  onChanged: (v) => c.setDarkMode(v),
                ),
                onTap: () => c.setDarkMode(!c.darkMode),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ---- 诊断 ----
          _Group(
            children: [
              _Tile(
                icon: Icons.article_outlined,
                title: '运行日志',
                onTap: () => Navigator.pushNamed(context, '/log'),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ---- 关于 ----
          const _Group(
            children: [
              _Tile(
                icon: Icons.info_outline,
                title: '关于 cloudSend',
                value: 'v1.0.0',
              ),
            ],
          ),

          const SizedBox(height: 24),
          const Center(
            child: Text(
              '填写公网服务器地址，可以随时随地使用！',
              style: TextStyle(fontSize: 11, color: AppTheme.grey),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 功能模式选择底弹: 局域网+中继 / 仅中继 / 仅局域网
  static void _pickConnMode(BuildContext context, RelayClient c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Center(
              child: Container(
                width: 26,
                height: 3,
                color: AppTheme.lineOf(context),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                '功能模式',
                style: TextStyle(fontSize: 12, color: AppTheme.grey),
              ),
            ),
            for (final (mode, title, desc) in [
              ('both', '局域网 + 中继 (推荐)', '优先走局域网直连；传输失败或离开局域网时自动切换中继保证连接'),
              ('relay', '仅中继', '只通过中继服务器连接，关闭局域网发现与直连'),
              ('lan', '仅局域网', '只在局域网内使用，不连接中继服务器'),
            ])
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(title, style: const TextStyle(fontSize: 14)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    desc,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.grey,
                      height: 1.4,
                    ),
                  ),
                ),
                trailing: c.connMode == mode
                    ? const Icon(Icons.check, size: 18, color: AppTheme.green)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  c.setConnMode(mode);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 弹窗编辑单个字段
  static Future<void> _editField(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    required void Function(String) onSubmit,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardOf(context),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
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
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) onSubmit(result);
  }
}

/// 通栏白色分组容器, 条目间缩进分割线
class _Group extends StatelessWidget {
  final List<Widget> children;
  const _Group({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.cardOf(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) const Divider(height: 1, indent: 52),
          ],
        ],
      ),
    );
  }
}

/// 标准设置条目: 左图标 + 标题, 右灰色 value + 箭头
class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Tile({
    required this.icon,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: AppTheme.isDark(context)
                    ? AppTheme.grey
                    : const Color(0xFF555555),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14.5,
                  color: AppTheme.inkOf(context),
                ),
              ),
              // value 用 Expanded + 右对齐, 短文本也紧贴右侧 (Spacer+Flexible
              // 会平分剩余空间导致短文本浮在中间)
              if (value != null)
                Expanded(
                  child: Text(
                    value!,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, color: AppTheme.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                const Spacer(),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else if (onTap != null) ...[
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 18, color: AppTheme.grey),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部个人信息大卡: 大头像 + 用户名 + 设备 ID
class _ProfileCard extends StatelessWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final hasAvatar =
        c.avatarPath.isNotEmpty && File(c.avatarPath).existsSync();
    return Container(
      color: AppTheme.cardOf(context),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        children: [
          // 点头像更换
          GestureDetector(
            onTap: () => _pickAvatar(context, c),
            child: Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.green,
                borderRadius: BorderRadius.circular(10),
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
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 26,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          // 点名字修改用户名
          Expanded(
            child: InkWell(
              onTap: () => SettingsPage._editField(
                context,
                title: '用户名',
                hint: '输入用户名',
                initial: c.deviceName,
                onSubmit: (v) {
                  if (v.isNotEmpty) c.setDeviceName(v);
                },
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.deviceName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
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
                            'ID: ${c.deviceId}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.grey,
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.copy, size: 11, color: AppTheme.grey),
                      ],
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

  void _pickAvatar(BuildContext context, RelayClient c) {
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
              leading: const Icon(Icons.photo_library_outlined, size: 15),
              title: const Text('从文件中选择', style: TextStyle(fontSize: 12.5)),
              onTap: () async {
                Navigator.pop(ctx);
                final r = await FilePicker.platform.pickFiles(
                  type: FileType.image,
                );
                final path = r?.files.single.path;
                if (path != null) c.setAvatar(path);
              },
            ),
            if (c.avatarPath.isNotEmpty)
              ListTile(
                dense: true,
                minTileHeight: 34,
                horizontalTitleGap: 8,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const Icon(Icons.restart_alt, size: 15),
                title: const Text('恢复默认', style: TextStyle(fontSize: 12.5)),
                onTap: () {
                  Navigator.pop(ctx);
                  c.setAvatar('');
                },
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 局域网分组: 直连状态 / 本机 IP / 手动设备
class _NetworkGroup extends StatefulWidget {
  const _NetworkGroup();

  @override
  State<_NetworkGroup> createState() => _NetworkGroupState();
}

class _NetworkGroupState extends State<_NetworkGroup> {
  List<NetworkInterface>? _ifs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ifs = await context.read<RelayClient>().localInterfaces();
    if (mounted) setState(() => _ifs = ifs);
  }

  /// 概要: 优先显示第一个非回环 IPv4, 否则显示接口数
  String get _ipSummary {
    final ifs = _ifs;
    if (ifs == null) return '…';
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
    final all = ifs.expand((i) => i.addresses).toList();
    return all.isEmpty ? '无' : '${all.length} 个地址';
  }

  void _showIps(BuildContext context) {
    final ifs = _ifs ?? [];
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Center(
              child: Container(
                width: 26,
                height: 3,
                color: AppTheme.lineOf(context),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                '本机 IP 地址 (点按复制, 对方可输入此地址手动连接)',
                style: TextStyle(fontSize: 12, color: AppTheme.grey),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final i in ifs)
                    for (final a in i.addresses)
                      ListTile(
                        dense: true,
                        minTileHeight: 36,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          a.address,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                        subtitle: Text(
                          i.name,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.grey,
                          ),
                        ),
                        trailing: a.isLoopback
                            ? const Text(
                                '回环',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.grey,
                                ),
                              )
                            : null,
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: a.address));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已复制 ${a.address}')),
                          );
                        },
                      ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showManualPeers(BuildContext context, RelayClient c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.cardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '手动添加的设备',
                        style: TextStyle(fontSize: 12, color: AppTheme.grey),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => showAddManualPeerDialog(context),
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('添加', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
              if (c.manualLanTargets.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    '用于广播不可达的场景 (如 Android 模拟器)。\n添加后即使重启应用也会自动重连。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.grey,
                      height: 1.5,
                    ),
                  ),
                )
              else
                for (final t in c.manualLanTargets)
                  ListTile(
                    dense: true,
                    minTileHeight: 36,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      t,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: AppTheme.grey,
                      ),
                      onPressed: () async {
                        await c.removeManualLanPeer(t);
                        setSheet(() {});
                      },
                    ),
                  ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return _Group(
      children: [
        _Tile(icon: Icons.lan_outlined, title: '局域网直连', value: c.lanStatusText),
        _Tile(
          icon: Icons.wifi,
          title: '本机 IP',
          value: _ipSummary,
          onTap: () => _showIps(context),
        ),
        _Tile(
          icon: Icons.add_link,
          title: '手动设备',
          value: '${c.manualLanTargets.length} 个',
          onTap: () => _showManualPeers(context, c),
        ),
      ],
    );
  }
}

/// 服务器状态条目: 状态点 + 文字紧贴右侧, 药丸连接/断开按钮
class _ServerStatusTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return _Tile(
      icon: Icons.link,
      title: '状态',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: c.connected ? AppTheme.green : AppTheme.grey,
          ),
          const SizedBox(width: 6),
          Text(
            c.connected ? '已连接' : '未连接',
            style: const TextStyle(fontSize: 13, color: AppTheme.grey),
          ),
          const SizedBox(width: 12),
          _PillButton(
            label: c.connected ? '断开' : '连接',
            filled: !c.connected,
            onTap: () {
              if (c.connected) {
                c.disconnect();
              } else if (c.serverAddr.isEmpty) {
                SettingsPage._editField(
                  context,
                  title: '服务器地址',
                  hint: '例如 1.2.3.4:8787 或 ws://example.com/ws',
                  initial: c.serverAddr,
                  onSubmit: (v) {
                    if (v.isNotEmpty) c.connect(v);
                  },
                );
              } else {
                c.connect(c.serverAddr);
              }
            },
          ),
        ],
      ),
    );
  }
}

/// 清除缓存条目: 显示缓存大小, 点击弹确认后清空
/// (Android 上 file_picker 会把选中的文件复制到缓存目录, 发文件后缓存会变大)
class _ClearCacheTile extends StatefulWidget {
  const _ClearCacheTile();

  @override
  State<_ClearCacheTile> createState() => _ClearCacheTileState();
}

class _ClearCacheTileState extends State<_ClearCacheTile> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await context.read<RelayClient>().cacheSize();
    if (mounted) setState(() => _bytes = b);
  }

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _confirmClear(RelayClient c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardOf(context),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text(
          '清除缓存',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          '将清空临时文件 (含文件选择器复制的文件副本)，不影响已接收保存的文件。',
          style: TextStyle(fontSize: 13),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.clearCache();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('缓存已清除')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return _Tile(
      icon: Icons.cleaning_services_outlined,
      title: '清除缓存',
      value: _bytes == null ? '…' : _fmt(_bytes!),
      onTap: () => _confirmClear(c),
    );
  }
}

/// 药丸小按钮: filled=绿底白字, 否则白底灰边
class _PillButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _PillButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? AppTheme.green : AppTheme.cardOf(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: filled ? AppTheme.green : AppTheme.lineOf(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: filled ? Colors.white : AppTheme.inkOf(context),
          ),
        ),
      ),
    );
  }
}

/// 文件保存位置条目: 显示路径, 点击弹出 打开/更改/恢复默认 菜单
class _SaveDirTile extends StatelessWidget {
  const _SaveDirTile();

  @override
  Widget build(BuildContext context) {
    // watch 以便修改目录后即时刷新
    final c = context.watch<RelayClient>();
    return FutureBuilder<String>(
      future: c.downloadDir(),
      builder: (_, snap) {
        final dir = snap.data ?? '';
        return _Tile(
          icon: Icons.folder_open,
          title: '文件保存位置',
          value: dir.isEmpty ? '…' : dir,
          onTap: dir.isEmpty ? null : () => _showMenu(context, c, dir),
        );
      },
    );
  }

  void _showMenu(BuildContext context, RelayClient c, String dir) {
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
            _menuItem(
              icon: Icons.folder_open,
              label: '打开文件夹',
              onTap: () {
                Navigator.pop(ctx);
                _openDir(context, dir);
              },
            ),
            _menuItem(
              icon: Icons.drive_file_move_outline,
              label: '更改保存位置',
              onTap: () async {
                Navigator.pop(ctx);
                final picked = await FilePicker.platform.getDirectoryPath();
                if (picked != null && picked.isNotEmpty) {
                  await c.setDownloadDir(picked);
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('保存位置已更新')));
                  }
                }
              },
            ),
            _menuItem(
              icon: Icons.restart_alt,
              label: '恢复默认位置',
              onTap: () async {
                Navigator.pop(ctx);
                await c.setDownloadDir(null);
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已恢复默认保存位置')));
                }
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      minTileHeight: 34,
      horizontalTitleGap: 8,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: Icon(icon, size: 15),
      title: Text(label, style: const TextStyle(fontSize: 12.5)),
      onTap: onTap,
    );
  }

  Future<void> _openDir(BuildContext context, String dir) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('文件保存于: $dir')));
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开文件夹')));
      }
    }
  }
}
