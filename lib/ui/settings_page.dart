import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import 'action_dialog.dart';
import 'app_toast.dart';

/// 设置页 (微信「我 → 设置」风格: 灰底 + 通栏白色分组)
class SettingsPage extends StatelessWidget {
  /// embedded=true 时嵌入主界面 (不带 Scaffold/AppBar)
  final bool embedded;
  const SettingsPage({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final body = ListView(
      children: [
        const SizedBox(height: 10),

        // ---- 个人信息大卡 ----
        const _ProfileCard(),
        const SizedBox(height: 10),

        // ---- 功能模式 ----
        _Group(
          children: [
            _Tile(
              title: tr('mode_title'),
              value: switch (c.connMode) {
                'relay' => tr('mode_relay'),
                'lan' => tr('mode_lan'),
                _ => tr('mode_both'),
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
                title: tr('server'),
                value: c.serverAddr.isEmpty ? tr('not_set') : c.serverAddr,
                // 连接中也可编辑, 保存后自动断开旧连接并重连新地址
                onTap: () => _editField(
                  context,
                  title: tr('server_addr_title'),
                  hint: tr('server_addr_hint'),
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
              title: tr('seg_transfers'),
              onTap: () => Navigator.pushNamed(context, '/transfers'),
            ),
            const _SaveDirTile(),
            const _ClearCacheTile(),
            _Tile(
              title: tr('blocklist'),
              value: trf('n_items', {
                'n': c.blockedPeers.length + c.blockedIps.length,
              }),
              onTap: () => Navigator.pushNamed(context, '/blocklist'),
            ),
            _Tile(
              title: tr('queue_sends'),
              trailing: Switch(
                value: c.queueSends,
                onChanged: (v) => c.setQueueSends(v),
              ),
              onTap: () => c.setQueueSends(!c.queueSends),
            ),
            _Tile(
              title: tr('compress_images'),
              trailing: Switch(
                value: c.compressImages,
                onChanged: (v) => c.setCompressImages(v),
              ),
              onTap: () => c.setCompressImages(!c.compressImages),
            ),
            _Tile(
              title: tr('dark_mode'),
              trailing: Switch(
                value: c.darkMode,
                onChanged: (v) => c.setDarkMode(v),
              ),
              onTap: () => c.setDarkMode(!c.darkMode),
            ),
            _Tile(
              title: tr('language'),
              value: l10n.isEn ? 'English' : '中文',
              onTap: () => _pickLanguage(context),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ---- 诊断 ----
        _Group(
          children: [
            _Tile(
              title: tr('run_log'),
              onTap: () => Navigator.pushNamed(context, '/log'),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ---- 关于 ----
        _Group(
          children: [_Tile(title: '${tr('about')} cloudSend', value: 'v1.0.0')],
        ),

        const SizedBox(height: 24),
        Center(
          child: Text(
            tr('footer_tip'),
            style: const TextStyle(fontSize: 11, color: AppTheme.grey),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
    if (embedded) {
      return Container(color: AppTheme.softOf(context), child: body);
    }
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('settings')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: body,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                tr('mode_title'),
                style: const TextStyle(fontSize: 12, color: AppTheme.grey),
              ),
            ),
            for (final (mode, title, desc) in [
              (
                'both',
                '${tr('mode_both')} ${tr('mode_both_rec')}',
                tr('mode_both_desc'),
              ),
              ('relay', tr('mode_relay'), tr('mode_relay_desc')),
              ('lan', tr('mode_lan'), tr('mode_lan_desc')),
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

  /// 语言选择弹窗: 中文 / English
  static Future<void> _pickLanguage(BuildContext context) async {
    final v = await showActionDialog<String>(
      context,
      title: tr('language'),
      actions: const [
        (label: '中文', value: 'zh', danger: false),
        (label: 'English', value: 'en', danger: false),
      ],
    );
    if (v != null) l10n.setLang(v);
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
            if (i < children.length - 1) const Divider(height: 1, indent: 16),
          ],
        ],
      ),
    );
  }
}

/// 标准设置条目: 标题, 右灰色 value + 箭头
class _Tile extends StatelessWidget {
  final String title;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Tile({required this.title, this.value, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 16, color: AppTheme.inkOf(context)),
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
                title: tr('username'),
                hint: tr('username_hint'),
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
                      AppToast.show(context, tr('id_copied'));
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
              title: Text(
                tr('pick_from_file'),
                style: const TextStyle(fontSize: 12.5),
              ),
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
                title: Text(
                  tr('restore_default'),
                  style: const TextStyle(fontSize: 12.5),
                ),
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
    return all.isEmpty ? tr('none') : trf('n_addrs', {'n': all.length});
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                tr('ip_sheet_title'),
                style: const TextStyle(fontSize: 12, color: AppTheme.grey),
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
                            ? Text(
                                tr('loopback'),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.grey,
                                ),
                              )
                            : null,
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: a.address));
                          AppToast.show(
                            context,
                            trf('copied_addr', {'addr': a.address}),
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
                    Expanded(
                      child: Text(
                        tr('manual_devices_title'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.grey,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _showAddLanTargetDialog(context),
                      icon: const Icon(Icons.add, size: 15),
                      label: Text(
                        tr('add'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              if (c.manualLanTargets.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    tr('manual_devices_desc'),
                    style: const TextStyle(
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
        _Tile(title: tr('lan_direct'), value: c.lanStatusText),
        _Tile(
          title: tr('local_ip'),
          value: _ipSummary,
          onTap: () => _showIps(context),
        ),
        _Tile(
          title: tr('manual_devices'),
          value: trf('n_items', {'n': c.manualLanTargets.length}),
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
      title: tr('status'),
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
            c.connected ? tr('connected') : tr('not_connected'),
            style: const TextStyle(fontSize: 13, color: AppTheme.grey),
          ),
          const SizedBox(width: 12),
          _PillButton(
            label: c.connected ? tr('disconnect') : tr('connect'),
            filled: !c.connected,
            onTap: () {
              if (c.connected) {
                c.disconnect();
              } else if (c.serverAddr.isEmpty) {
                SettingsPage._editField(
                  context,
                  title: tr('server_addr_title'),
                  hint: tr('server_addr_hint'),
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
        title: Text(
          tr('clear_cache'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Text(
          tr('clear_cache_msg'),
          style: const TextStyle(fontSize: 13),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('clear')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.clearCache();
      await _load();
      if (mounted) {
        AppToast.show(context, tr('cache_cleared'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return _Tile(
      title: tr('clear_cache'),
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
          title: tr('save_dir'),
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
              label: tr('open_folder'),
              onTap: () {
                Navigator.pop(ctx);
                _openDir(context, dir);
              },
            ),
            _menuItem(
              icon: Icons.drive_file_move_outline,
              label: tr('change_save_dir'),
              onTap: () async {
                Navigator.pop(ctx);
                final picked = await FilePicker.platform.getDirectoryPath();
                if (picked != null && picked.isNotEmpty) {
                  await c.setDownloadDir(picked);
                  if (context.mounted) {
                    AppToast.show(context, tr('dir_updated'));
                  }
                }
              },
            ),
            _menuItem(
              icon: Icons.restart_alt,
              label: tr('reset_save_dir'),
              onTap: () async {
                Navigator.pop(ctx);
                await c.setDownloadDir(null);
                if (context.mounted) {
                  AppToast.show(context, tr('dir_reset'));
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
          AppToast.show(context, trf('dir_saved_to', {'dir': dir}));
        }
      }
    } catch (_) {
      if (context.mounted) {
        AppToast.show(context, tr('open_folder_fail'));
      }
    }
  }
}

/// 「手动设备 → 添加」对话框: 输入对端 IP[:端口] 强制建立局域网直连。
/// 用于广播不可达的场景 (如 Android 模拟器, 填 10.0.2.2 可连宿主机)。
Future<void> _showAddLanTargetDialog(BuildContext context) async {
  final c = context.read<RelayClient>();
  final ctrl = TextEditingController();
  final input = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.cardOf(context),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(
        tr('manual_devices'),
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(hintText: tr('lan_target_hint')),
            onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
          ),
          const SizedBox(height: 10),
          Text(
            tr('lan_target_desc'),
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.grey,
              height: 1.5,
            ),
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
          child: Text(tr('cancel')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(tr('connect')),
        ),
      ],
    ),
  );
  // showDialog 完成时退出动画仍在播放, TextField 还在树里;
  // 立即 dispose 会让动画重建崩 "used after disposed", 延迟到动画结束
  Future<void>.delayed(const Duration(milliseconds: 300), ctrl.dispose);
  if (input == null || input.isEmpty || !context.mounted) return;
  AppToast.show(context, tr('connecting'), sticky: true);
  final peerId = await c.addManualLanPeer(input);
  if (!context.mounted) return;
  if (peerId != null) {
    AppToast.show(context, trf('connected_to', {'name': c.peerName(peerId)}));
  } else {
    AppToast.show(context, tr('connect_fail'));
  }
}
