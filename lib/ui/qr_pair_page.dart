import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_toast.dart';

/// 二维码配对: 展示本机二维码 (服务器地址 / 局域网直连), 或扫对方二维码填入。
/// 载荷格式:
/// - `cloudsend://server/<addr>`   中继服务器地址 (ws://ip:port 或 ip:port)
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
        c.connect(value);
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
  String? _lanIp;

  @override
  void initState() {
    super.initState();
    context.read<RelayClient>().firstLanIp().then((ip) {
      if (mounted) setState(() => _lanIp = ip);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final items = <({String title, String payload, String caption})>[];
    if (c.connMode != 'lan' && c.serverAddr.isNotEmpty) {
      items.add((
        title: tr('qr_server'),
        payload: 'cloudsend://server/${c.serverAddr}',
        caption: c.serverAddr,
      ));
    }
    if (c.connMode != 'relay' && _lanIp != null && c.lanTcpPort != 0) {
      final target = '$_lanIp:${c.lanTcpPort}';
      items.add((
        title: tr('qr_lan'),
        payload: 'cloudsend://lan/$target',
        caption: target,
      ));
    }
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('qr_pairing')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Center(
                child: Text(
                  tr('qr_nothing'),
                  style: const TextStyle(color: AppTheme.grey, fontSize: 13),
                ),
              ),
            )
          else
            for (final item in items) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.cardOf(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.inkOf(context),
                      ),
                    ),
                    const SizedBox(height: 12),
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
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          if (isMobile)
            FilledButton.icon(
              onPressed: () => QrPairPage.scan(context),
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: Text(tr('qr_scan')),
            ),
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
