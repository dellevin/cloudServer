import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';
import '../models.dart';

/// 关于页: 图标/名称/版本 + 软件简介 + 主要功能列表 (彩色图标块 + 标题/说明)
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  // 功能条目的图标与配色 (与 about_feat_1..6 一一对应)
  static const _featMeta = [
    (Icons.swap_horiz_rounded, Color(0xFF10AEFF)), // 文件互传
    (Icons.chat_bubble_outline_rounded, Color(0xFF07C160)), // 即时消息
    (Icons.content_paste_rounded, Color(0xFFFA9D3B)), // 剪贴板同步
    (Icons.folder_open_rounded, Color(0xFF6467F0)), // 远程浏览
    (Icons.lock_outline_rounded, Color(0xFFC9A227)), // 端到端加密
    (Icons.qr_code_scanner_rounded, Color(0xFF1485EE)), // 扫码配对
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('about')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 40),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset(
                'assets/icon.png',
                width: 76,
                height: 76,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              'cloudSend',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkOf(context),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Center(
            child: Text(
              'v$kAppVersion',
              style: TextStyle(fontSize: 12, color: AppTheme.grey),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              tr('about_slogan'),
              style: const TextStyle(fontSize: 12.5, color: AppTheme.grey),
            ),
          ),
          const SizedBox(height: 28),
          // ---- 简介 ----
          Container(
            color: AppTheme.cardOf(context),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Text(
              tr('about_desc'),
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: AppTheme.inkOf(context),
              ),
            ),
          ),
          // ---- 主要功能 ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
            child: Text(
              tr('about_features_title'),
              style: const TextStyle(fontSize: 12, color: AppTheme.grey),
            ),
          ),
          Container(
            color: AppTheme.cardOf(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _featMeta.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 62,
                      color: AppTheme.lineOf(context),
                    ),
                  _FeatureRow(
                    text: tr('about_feat_${i + 1}'),
                    icon: _featMeta[i].$1,
                    color: _featMeta[i].$2,
                  ),
                ],
              ],
            ),
          ),
          // ---- 底部信息 ----
          const SizedBox(height: 28),
          Center(
            child: Text(
              '© 2026 cloudSend · Protocol v$kProtocolVersion',
              style: const TextStyle(fontSize: 11, color: AppTheme.grey),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 单个功能行: 彩色圆角图标块 + 标题 (冒号前, 半粗) + 说明 (冒号后, 灰)
class _FeatureRow extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  const _FeatureRow({
    required this.text,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // 兼容中文/英文冒号, 没有冒号则整行当标题
    var cut = text.indexOf('：');
    if (cut < 0) cut = text.indexOf(':');
    final title = cut >= 0 ? text.substring(0, cut) : text;
    final desc = cut >= 0 ? text.substring(cut + 1).trim() : '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          // 图标彩色, 底色与卡片同色 (#FFFFFF / 深色 #1E1E1E)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.cardOf(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 19, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.inkOf(context),
                  ),
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppTheme.grey,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
