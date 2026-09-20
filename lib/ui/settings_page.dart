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
              icon: Icons.link_rounded,
              iconColor: const Color(0xFF10AEFF),
              title: tr('settings_conn'),
              onTap: () => Navigator.pushNamed(context, '/settings_conn'),
            ),
            _Tile(
              icon: Icons.tune_rounded,
              iconColor: const Color(0xFF576B95),
              title: tr('settings_general'),
              onTap: () => Navigator.pushNamed(context, '/settings_general'),
            ),
            _Tile(
              icon: Icons.content_paste_rounded,
              iconColor: const Color(0xFFFA9D3B),
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
              icon: Icons.qr_code_scanner_rounded,
              iconColor: const Color(0xFF1485EE),
              title: tr('qr_pairing'),
              onTap: () => Navigator.pushNamed(context, '/qr_pair'),
            ),
            _Tile(
              icon: Icons.dark_mode_outlined,
              iconColor: const Color(0xFF6467F0),
              title: tr('dark_mode'),
              trailing: Switch(
                value: c.darkMode,
                onChanged: (v) => c.setDarkMode(v),
              ),
              onTap: () => c.setDarkMode(!c.darkMode),
            ),
            _Tile(
              icon: Icons.translate_rounded,
              iconColor: AppTheme.green,
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
              icon: Icons.article_outlined,
              iconColor: const Color(0xFF8A8A8A),
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
              icon: Icons.favorite_rounded,
              iconColor: AppTheme.red,
              title: tr('sponsor'),
              onTap: () => Navigator.pushNamed(context, '/sponsor'),
            ),
            _Tile(
              icon: Icons.info_outline_rounded,
              iconColor: const Color(0xFF576B95),
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
            // 带图标的条目, 分隔线缩进对齐标题左缘 (16 + 30 + 12)
            if (i < children.length - 1)
              Divider(
                height: 1,
                indent: children[i] is _Tile &&
                        (children[i] as _Tile).icon != null
                    ? 58
                    : 16,
              ),
          ],
        ],
      ),
    );
  }
}

/// 标准设置条目: 可选彩色图标块 + 标题, 右灰色 value + 箭头
class _Tile extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Tile({
    this.icon,
    this.iconColor,
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
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (icon != null) ...[
                // 图标彩色, 底色与卡片同色 (#FFFFFF / 深色 #1E1E1E)
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: AppTheme.cardOf(context),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(
                    icon,
                    size: 17,
                    color: iconColor ?? AppTheme.grey,
                  ),
                ),
                const SizedBox(width: 12),
              ],
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
                    // 只保存, 不自动连: 保存后再点一次「连接」
                    if (v.isNotEmpty) c.setServerAddr(v);
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

/// 清除缓存条目: 显示缓存总大小, 点击弹分类管理面板 (各分类大小 +
/// 分别清理 + 全部清理); 确认弹窗带大小; 使用中文件自动跳过
/// (Android 上 file_picker 会把选中的文件复制到缓存目录, 发文件后缓存会变大)
class _ClearCacheTile extends StatefulWidget {
  const _ClearCacheTile();

  @override
  State<_ClearCacheTile> createState() => _ClearCacheTileState();
}

class _ClearCacheTileState extends State<_ClearCacheTile> {
  Map<String, int>? _sizes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await context.read<RelayClient>().cacheSizeByCategory();
    if (mounted) setState(() => _sizes = s);
  }

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  int get _total => _sizes?.values.fold<int>(0, (a, b) => a + b) ?? 0;

  /// 确认 (弹窗带大小) → 清理 → 刷新; 有使用中文件被跳过时提示
  Future<void> _clear(
    RelayClient c,
    Set<String>? categories,
    int size,
  ) async {
    final ok = await AppDialog.confirm(
      context,
      title: tr('clear_cache'),
      message: trf('clear_cache_msg', {'size': _fmt(size)}),
      okLabel: tr('clear'),
      danger: true,
    );
    if (!ok) return;
    final all = await c.clearCache(categories: categories);
    await _load();
    if (mounted) {
      AppToast.show(context, tr(all ? 'cache_cleared' : 'cache_partial'));
    }
  }

  /// 分类管理面板: 各分类大小 + 分别清理, 底部全部清理
  void _showSheet(RelayClient c) {
    AppDialog.custom(
      context,
      title: tr('clear_cache'),
      child: StatefulBuilder(
        builder: (ctx, setSheet) {
          final s = _sizes;
          if (s == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          Future<void> clearAndRefresh(Set<String>? cats, int size) async {
            await _clear(c, cats, size);
            // 清理期间弹窗可能已被关掉, StatefulBuilder 已卸载不能再 setState
            if (ctx.mounted) setSheet(() {}); // _sizes 已刷新, 重画面板
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('cache_sheet_hint'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.grey,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                _catRow(
                  ctx,
                  label: tr('cache_cat_preview'),
                  size: s[RelayClient.cacheCatPreview]!,
                  onClear: () => clearAndRefresh({
                    RelayClient.cacheCatPreview,
                  }, s[RelayClient.cacheCatPreview]!),
                ),
                const SizedBox(height: 6),
                _catRow(
                  ctx,
                  label: tr('cache_cat_picker'),
                  size: s[RelayClient.cacheCatPicker]!,
                  onClear: () => clearAndRefresh({
                    RelayClient.cacheCatPicker,
                  }, s[RelayClient.cacheCatPicker]!),
                ),
                const SizedBox(height: 6),
                _catRow(
                  ctx,
                  label: tr('cache_cat_other'),
                  size: s[RelayClient.cacheCatOther]!,
                  onClear: () => clearAndRefresh({
                    RelayClient.cacheCatOther,
                  }, s[RelayClient.cacheCatOther]!),
                ),
                const SizedBox(height: 10),
                // 全部清理 (浅红块, 与删除设备同款)
                Material(
                  color: AppTheme.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _total == 0
                        ? null
                        : () => clearAndRefresh(null, _total),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 14,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${tr('clear_all')} (${_fmt(_total)})',
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
            ),
          );
        },
      ),
    );
  }

  /// 分类行: 圆角灰块, 左名称+大小, 右清除胶囊 (0 字节置灰)
  Widget _catRow(
    BuildContext ctx, {
    required String label,
    required int size,
    required VoidCallback onClear,
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
                    label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.inkOf(ctx),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmt(size),
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: size == 0 ? null : onClear,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: size == 0
                      ? AppTheme.grey.withValues(alpha: 0.15)
                      : AppTheme.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  tr('clear'),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: size == 0 ? AppTheme.grey : AppTheme.green,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return _Tile(
      title: tr('clear_cache'),
      value: _sizes == null ? '…' : _fmt(_total),
      onTap: () => _showSheet(c),
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
                  // 只保存地址不自动连接: 还要填密码, 点「连接」按钮才连
                  onTap: () => SettingsPage._editField(
                    context,
                    title: tr('server_addr_title'),
                    hint: tr('server_addr_hint'),
                    initial: c.serverAddr,
                    onSubmit: (v) {
                      if (v.isNotEmpty) c.setServerAddr(v);
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
