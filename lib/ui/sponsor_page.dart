import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';

/// 赞助页: 感谢文案 + 微信/支付宝收款码 (点按放大扫码)
class SponsorPage extends StatelessWidget {
  const SponsorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('sponsor')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 32),
          // 顶部爱心 + 感谢语
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.red.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.favorite_rounded,
                size: 30,
                color: AppTheme.red,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              tr('sponsor_thanks'),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkOf(context),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              tr('sponsor_desc'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppTheme.grey,
              ),
            ),
          ),
          const SizedBox(height: 24),
          // 收款码: 微信 / 支付宝 双卡片。
          // 两张图宽高比不同 (wx 1283x1748≈0.734, zfb 1182x1772≈0.667):
          // 按各自比例分配宽度 (flex 与宽高比成正比), 卡片内再用相同比例框,
          // 两卡自然等高、图各自填满, 不留白边不裁切
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 734,
                  child: _QrCard(
                    asset: 'assets/wx.jpg',
                    aspectRatio: 1283 / 1748,
                    label: tr('sponsor_wx'),
                    color: AppTheme.green,
                    icon: Icons.chat_bubble_rounded,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 667,
                  child: _QrCard(
                    asset: 'assets/zfb.jpg',
                    aspectRatio: 1182 / 1772,
                    label: tr('sponsor_zfb'),
                    color: const Color(0xFF1677FF),
                    icon: Icons.currency_yen_rounded,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              tr('sponsor_tap_zoom'),
              style: const TextStyle(fontSize: 11, color: AppTheme.grey),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 单个收款码卡片: 白卡 + 二维码图 + 带色标签; 点图全屏放大 (方便扫码)
class _QrCard extends StatelessWidget {
  final String asset;
  final double aspectRatio; // 图片原始宽高比, 框与图一致 → 完整填满不变形
  final String label;
  final Color color;
  final IconData icon;
  const _QrCard({
    required this.asset,
    required this.aspectRatio,
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardOf(context),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _zoom(context),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: aspectRatio,
                  // 原图 ~1200px 宽, 卡片仅显示 ~200px: 限解码宽度省内存
                  // (全屏放大页不限, 保留双指放大后的清晰度)
                  child: Image.asset(
                    asset,
                    fit: BoxFit.cover,
                    cacheWidth: 800,
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: AppTheme.lineOf(context), width: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 全屏放大收款码: 黑底 + 双指缩放, 点按退出
  void _zoom(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.9),
        barrierDismissible: true,
        pageBuilder: (ctx, _, _) => GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Image.asset(asset, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
