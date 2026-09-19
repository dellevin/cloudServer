import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_dialog.dart';
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

        // ---- 功能分类入口 ----
        _Group(
          children: [
            _Tile(
              title: tr('settings_conn'),
              onTap: () => Navigator.pushNamed(context, '/settings_conn'),
            ),
            _Tile(
              title: tr('settings_general'),
              onTap: () => Navigator.pushNamed(context, '/settings_general'),
            ),
            _Tile(
              title: tr('clip_sync'),
              onTap: () => Navigator.pushNamed(context, '/settings_clip'),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ---- 常用 ----
        _Group(
          children: [
            _Tile(
              title: tr('qr_pairing'),
              onTap: () => Navigator.pushNamed(context, '/qr_pair'),
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
          children: [
            _Tile(
              title: '${tr('about')} cloudSend',
              value: 'v$kAppVersion',
              onTap: () => Navigator.pushNamed(context, '/about'),
            ),
          ],
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

  /// 功能模式选择弹窗: 局域网+中继 / 仅中继 / 仅局域网
  static void _pickConnMode(BuildContext context, RelayClient c) async {
    final v = await AppDialog.actions<String>(
      context,
      title: tr('mode_title'),
      actions: [
        AppDialogAction(
          '${tr('mode_both')} ${tr('mode_both_rec')}',
          'both',
          sub: tr('mode_both_desc'),
          check: c.connMode == 'both',
        ),
        AppDialogAction(
          tr('mode_relay'),
          'relay',
          sub: tr('mode_relay_desc'),
          check: c.connMode == 'relay',
        ),
        AppDialogAction(
          tr('mode_lan'),
          'lan',
          sub: tr('mode_lan_desc'),
          check: c.connMode == 'lan',
        ),
      ],
    );
    if (v != null) c.setConnMode(v);
  }

  /// 远程预览大小上限选择弹窗 (MB); 选“自定义”可手动输入
  static Future<void> _pickPreviewLimit(BuildContext context) async {
    const opts = [5, 10, 20, 50, 100, 200];
    final v = await AppDialog.actions<int>(
      context,
      title: tr('fs_preview_limit'),
      actions: [
        for (final mb in opts) AppDialogAction('$mb MB', mb),
        AppDialogAction(tr('custom'), -1),
      ],
    );
    if (v == null || !context.mounted) return;
    if (v > 0) {
      context.read<RelayClient>().setFsPreviewMaxMb(v);
      return;
    }
    // 自定义: 手动输入 MB 数
    final cur = context.read<RelayClient>().fsPreviewMaxMb;
    await _editField(
      context,
      title: tr('fs_preview_limit'),
      hint: tr('fs_preview_limit_hint'),
      initial: '$cur',
      onSubmit: (s) {
        final mb = int.tryParse(s);
        if (mb != null && mb > 0) {
          context.read<RelayClient>().setFsPreviewMaxMb(mb);
        }
      },
    );
  }

  /// 语言选择弹窗: 中文 / English
  static Future<void> _pickLanguage(BuildContext context) async {
    final v = await AppDialog.actions<String>(
      context,
      title: tr('language'),
      actions: [AppDialogAction('中文', 'zh'), AppDialogAction('English', 'en')],
    );
    if (v != null) l10n.setLang(v);
  }

  /// 弹窗编辑单个字段; obscure=密码遮罩, allowEmpty=允许提交空值 (用于清除)
  static Future<void> _editField(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    required void Function(String) onSubmit,
    bool obscure = false,
    bool allowEmpty = false,
  }) async {
    final result = await AppDialog.input(
      context,
      title: title,
      hint: hint,
      initial: initial,
      obscure: obscure,
      allowEmpty: allowEmpty,
    );
    if (result != null) onSubmit(result);
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

  void _pickAvatar(BuildContext context, RelayClient c) async {
    final v = await AppDialog.actions<String>(
      context,
      title: tr('avatar'),
      actions: [
        AppDialogAction(tr('pick_from_file'), 'pick'),
        if (c.avatarPath.isNotEmpty)
          AppDialogAction(tr('restore_default'), 'reset'),
      ],
    );
    if (v == 'pick') {
      final r = await FilePicker.platform.pickFiles(type: FileType.image);
      final path = r?.files.single.path;
      if (path != null) c.setAvatar(path);
    } else if (v == 'reset') {
      c.setAvatar('');
    }
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
    AppDialog.custom(
      context,
      title: tr('ip_sheet_title'),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final i in ifs)
            for (final a in i.addresses)
              ListTile(
                dense: true,
                minTileHeight: 36,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(
                  a.address,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontFamily: 'monospace',
                  ),
                ),
                subtitle: Text(
                  i.name,
                  style: const TextStyle(fontSize: 11, color: AppTheme.grey),
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
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _showManualPeers(BuildContext context, RelayClient c) {
    AppDialog.custom(
      context,
      title: tr('manual_devices_title'),
      trailing: TextButton.icon(
        onPressed: () => _showAddLanTargetDialog(context),
        icon: const Icon(Icons.add, size: 15),
        label: Text(tr('add'), style: const TextStyle(fontSize: 12)),
      ),
      child: StatefulBuilder(
        builder: (ctx, setSheet) {
          if (c.manualLanTargets.isEmpty) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                tr('manual_devices_desc'),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.grey,
                  height: 1.5,
                ),
              ),
            );
          }
          // 设备多了限高滚动, 弹窗高度不随条目数膨胀
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: Scrollbar(
              thumbVisibility: true,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final t in c.manualLanTargets)
                    ListTile(
                      dense: true,
                      minTileHeight: 36,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
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
                ],
              ),
            ),
          );
        },
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
    final ok = await AppDialog.confirm(
      context,
      title: tr('clear_cache'),
      message: tr('clear_cache_msg'),
      okLabel: tr('clear'),
      danger: true,
    );
    if (ok) {
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

  void _showMenu(BuildContext context, RelayClient c, String dir) async {
    final v = await AppDialog.actions<String>(
      context,
      title: tr('save_dir'),
      actions: [
        AppDialogAction(tr('open_folder'), 'open'),
        AppDialogAction(tr('change_save_dir'), 'change'),
        AppDialogAction(tr('reset_save_dir'), 'reset'),
      ],
    );
    if (!context.mounted) return;
    switch (v) {
      case 'open':
        _openDir(context, dir);
      case 'change':
        final picked = await FilePicker.platform.getDirectoryPath();
        if (picked != null && picked.isNotEmpty) {
          await c.setDownloadDir(picked);
          if (context.mounted) {
            AppToast.show(context, tr('dir_updated'));
          }
        }
      case 'reset':
        await c.setDownloadDir(null);
        if (context.mounted) {
          AppToast.show(context, tr('dir_reset'));
        }
    }
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
  final input = await AppDialog.input(
    context,
    title: tr('manual_devices'),
    hint: tr('lan_target_hint'),
    desc: tr('lan_target_desc'),
    okLabel: tr('connect'),
    keyboardType: TextInputType.url,
  );
  if (input == null || !context.mounted) return;
  AppToast.show(context, tr('connecting'), sticky: true);
  final peerId = await c.addManualLanPeer(input);
  if (!context.mounted) return;
  if (peerId != null) {
    AppToast.show(context, trf('connected_to', {'name': c.peerName(peerId)}));
  } else {
    AppToast.show(context, tr('connect_fail'));
  }
}

/// 设置子页通用 AppBar (标题 + 底部分隔线)
PreferredSizeWidget _subAppBar(String title) => AppBar(
  title: Text(title),
  bottom: const PreferredSize(
    preferredSize: Size.fromHeight(1),
    child: Divider(height: 1),
  ),
);

/// 连接设置子页: 功能模式 / 中继服务器 / 局域网直连
class ConnSettingsPage extends StatelessWidget {
  const ConnSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: _subAppBar(tr('settings_conn')),
      body: ListView(
        children: [
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
                onTap: () => SettingsPage._pickConnMode(context, c),
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
                  onTap: () => SettingsPage._editField(
                    context,
                    title: tr('server_addr_title'),
                    hint: tr('server_addr_hint'),
                    initial: c.serverAddr,
                    onSubmit: (v) {
                      if (v.isNotEmpty) c.connect(v);
                    },
                  ),
                ),
                _Tile(
                  title: tr('server_key'),
                  value: c.serverKey.isEmpty
                      ? tr('not_set')
                      : '••••••••', // 密码不回显
                  onTap: () => SettingsPage._editField(
                    context,
                    title: tr('server_key'),
                    hint: tr('server_key_hint'),
                    initial: c.serverKey,
                    obscure: true,
                    allowEmpty: true, // 清空 = 不再发送接入密码
                    onSubmit: (v) => c.setServerKey(v),
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
        ],
      ),
    );
  }
}

/// 通用设置子页: 配对/传输/存储/黑名单 + 各项开关
class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: _subAppBar(tr('settings_general')),
      body: ListView(
        children: [
          const SizedBox(height: 10),
          _Group(
            children: [
              const _SaveDirTile(),
              const _ClearCacheTile(),
              _Tile(
                title: tr('blocklist'),
                value: trf('n_items', {
                  'n': c.blockedPeers.length + c.blockedIps.length,
                }),
                onTap: () => Navigator.pushNamed(context, '/blocklist'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Group(
            children: [
              _Tile(
                title: tr('queue_sends'),
                trailing: Switch(
                  value: c.queueSends,
                  onChanged: (v) => c.setQueueSends(v),
                ),
                onTap: () => c.setQueueSends(!c.queueSends),
              ),
              _Tile(
                title: tr('p2p_title'),
                trailing: Switch(
                  value: c.p2pEnabled,
                  onChanged: (v) => c.setP2pEnabled(v),
                ),
                onTap: () => c.setP2pEnabled(!c.p2pEnabled),
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
                title: tr('fs_preview_limit'),
                value: '${c.fsPreviewMaxMb} MB',
                onTap: () => SettingsPage._pickPreviewLimit(context),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// 剪贴板同步设置子页
class ClipSettingsPage extends StatelessWidget {
  const ClipSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: _subAppBar(tr('clip_sync')),
      body: ListView(
        children: [
          const SizedBox(height: 10),
          _Group(
            children: [
              _Tile(
                title: tr('clip_sync'),
                trailing: Switch(
                  value: c.clipSyncEnabled,
                  onChanged: (v) => c.setClipSyncEnabled(v),
                ),
                onTap: () => c.setClipSyncEnabled(!c.clipSyncEnabled),
              ),
              _Tile(
                title: tr('clip_auto_paste'),
                trailing: Switch(
                  value: c.clipAutoPaste,
                  onChanged: (v) => c.setClipAutoPaste(v),
                ),
                onTap: () => c.setClipAutoPaste(!c.clipAutoPaste),
              ),
              _Tile(
                title: tr('clip_block_archives'),
                trailing: Switch(
                  value: c.clipBlockArchives,
                  onChanged: (v) => c.setClipBlock('archives', v),
                ),
                onTap: () => c.setClipBlock('archives', !c.clipBlockArchives),
              ),
              _Tile(
                title: tr('clip_block_images'),
                trailing: Switch(
                  value: c.clipBlockImages,
                  onChanged: (v) => c.setClipBlock('images', v),
                ),
                onTap: () => c.setClipBlock('images', !c.clipBlockImages),
              ),
              _Tile(
                title: tr('clip_block_videos'),
                trailing: Switch(
                  value: c.clipBlockVideos,
                  onChanged: (v) => c.setClipBlock('videos', v),
                ),
                onTap: () => c.setClipBlock('videos', !c.clipBlockVideos),
              ),
              _Tile(
                title: tr('clip_custom_exts'),
                value: c.clipBlockedExts.isEmpty
                    ? tr('not_set')
                    : c.clipBlockedExts.join(', '),
                onTap: () => Navigator.pushNamed(context, '/clip_exts'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('clip_sync_trust_hint'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.grey,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('clip_auto_paste_off_hint'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.grey,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
