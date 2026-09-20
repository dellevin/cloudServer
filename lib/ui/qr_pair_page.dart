import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_toast.dart';

/// 二维码配对: 展示本机二维码 (服务器地址 / 局域网直连, 分页切换),
/// 或扫对方二维码填入。
/// 载荷格式:
/// - `cloudsend://server/<addr>[?key=<url编码的接入密码>]`   中继服务器
/// - `cloudsend://lan/<ip:port>`   局域网手动设备
class QrPairPage extends StatefulWidget {
  const QrPairPage({super.key});

  /// 扫码入口 (仅移动平台; 桌面端没有相机): 扫到结果直接应用
  static Future<void> scan(BuildContext context) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final c = context.read<RelayClient>();
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _QrScanPage()));
    if (raw == null || !context.mounted) return;
    final ok = await applyQrPayload(c, raw);
    if (!context.mounted) return;
    AppToast.show(context, ok ? tr('qr_applied') : tr('qr_invalid'));
  }

  /// 解析并应用扫码结果; 无法识别返回 false
  static Future<bool> applyQrPayload(RelayClient c, String raw) async {
    const prefix = 'cloudsend://';
    if (!raw.startsWith(prefix)) return false;
    final rest = raw.substring(prefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return false;
    final kind = rest.substring(0, slash);
    final value = rest.substring(slash + 1);
    switch (kind) {
      case 'server':
        // 载荷可带接入密码 (?key=): 先存密码再连接, 注册时才会带上
        var addr = value;
        final q = value.indexOf('?key=');
        if (q > 0) {
          addr = value.substring(0, q);
          final key = Uri.decodeComponent(value.substring(q + 5));
          if (key.isNotEmpty) await c.setServerKey(key);
        }
        c.connect(addr);
        return true;
      case 'lan':
        return await c.addManualLanPeer(value) != null;
      default:
        return false;
    }
  }

  @override
  State<QrPairPage> createState() => _QrPairPageState();
}

class _QrPairPageState extends State<QrPairPage> {
  List<(String, String)> _lanAddrs = const []; // (IP, 网卡名)
  int _lanSel = 0; // 选中的局域网网段下标
  int _seg = 0; // 当前展示的二维码页签 (中继 / 局域网分开看)

  @override
  void initState() {
    super.initState();
    context.read<RelayClient>().lanAddrs().then((list) {
      if (mounted) setState(() => _lanAddrs = list);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final items =
        <
          ({
            String title,
            String payload,
            String caption,
            String? note,
            bool isLan,
          })
        >[];
    if (c.connMode != 'lan' && c.serverAddr.isNotEmpty) {
      // 服务器设了接入密码: 一并编进二维码, 对方扫完即可连, 不用再手输
      var payload = 'cloudsend://server/${c.serverAddr}';
      String? note;
      if (c.serverKey.isNotEmpty) {
        payload += '?key=${Uri.encodeComponent(c.serverKey)}';
        note = tr('qr_includes_key');
      }
      items.add((
        title: tr('qr_server'),
        payload: payload,
        caption: c.serverAddr,
        note: note,
        isLan: false,
      ));
    }
    if (c.connMode != 'relay' && _lanAddrs.isNotEmpty && c.lanTcpPort != 0) {
      final sel = _lanSel.clamp(0, _lanAddrs.length - 1);
      final target = '${_lanAddrs[sel].$1}:${c.lanTcpPort}';
      items.add((
        title: tr('qr_lan'),
        payload: 'cloudsend://lan/$target',
        caption: target,
        note: null,
        isLan: true,
      ));
    }
    if (_seg >= items.length) _seg = 0;
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('qr_pairing')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                tr('qr_nothing'),
                style: const TextStyle(color: AppTheme.grey, fontSize: 13),
              ),
            )
          : Column(
              children: [
                // 两个连接方式分页切换, 一次只展示一个二维码
                if (items.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: Row(
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: _segTab(
                              label: items[i].title,
                              selected: _seg == i,
                              onTap: () => setState(() => _seg = i),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _qrCard(context, items[_seg], showTitle: items.length <= 1),
                      if (isMobile) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => QrPairPage.scan(context),
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: Text(tr('qr_scan')),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 页签胶囊: 选中绿底白字, 未选卡片底色 (与 AppDialog 胶囊按钮同风格)
  Widget _segTab({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? AppTheme.green : AppTheme.cardOf(context),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppTheme.inkOf(context),
            ),
          ),
        ),
      ),
    );
  }

  /// 网段选择胶囊卡: 选中绿底白字 (IP 等宽字体 + 网卡名小字),
  /// 未选卡片底色描边, 与 _segTab 同一套视觉
  Widget _lanChip(int i) {
    final (ip, ifname) = _lanAddrs[i];
    final selected = _lanSel.clamp(0, _lanAddrs.length - 1) == i;
    return Material(
      color: selected ? AppTheme.green : AppTheme.softOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? AppTheme.green : AppTheme.lineOf(context),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _lanSel = i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ip,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppTheme.inkOf(context),
                ),
              ),
              if (ifname.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(
                  ifname,
                  style: TextStyle(
                    fontSize: 10,
                    color: selected
                        ? Colors.white.withValues(alpha: 0.75)
                        : AppTheme.grey,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _qrCard(
    BuildContext context,
    ({
      String title,
      String payload,
      String caption,
      String? note,
      bool isLan,
    })
    item, {
    required bool showTitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardOf(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          if (showTitle) ...[
            // 只有一种连接方式时没有页签, 标题放卡片里
            Text(
              item.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkOf(context),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // 多网卡/多网段: 胶囊选择卡切换网段 (与页签同风格), 二维码跟随切换
          if (item.isLan && _lanAddrs.length > 1) ...[
            Text(
              tr('qr_pick_lan'),
              style: const TextStyle(fontSize: 11, color: AppTheme.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (var i = 0; i < _lanAddrs.length; i++) _lanChip(i),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(10),
            child: QrImageView(
              data: item.payload,
              size: 200,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            item.caption,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.grey,
              fontFamily: 'monospace',
            ),
          ),
          if (item.note != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.key, size: 12, color: AppTheme.grey),
                const SizedBox(width: 3),
                Text(
                  item.note!,
                  style: const TextStyle(fontSize: 11, color: AppTheme.grey),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 扫码页: 全屏相机取景, 识别到二维码立即返回结果
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final _ctrl = MobileScannerController();
  bool _found = false; // 防连扫触发多次 pop

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(tr('qr_scan')),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: MobileScanner(
        controller: _ctrl,
        onDetect: (capture) {
          if (_found) return;
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw != null && raw.startsWith('cloudsend://')) {
              _found = true;
              Navigator.of(context).pop(raw);
              return;
            }
          }
        },
      ),
    );
  }
}
