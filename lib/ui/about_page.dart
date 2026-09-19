import 'package:flutter/material.dart';

import '../l10n.dart';
import '../main.dart';

/// 关于页: 图标/名称/版本 + 软件简介 + 主要功能列表
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
          const SizedBox(height: 36),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/icon.png',
                width: 72,
                height: 72,
              ),
            ),
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 24),
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
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 1; i <= 5; i++) _FeatureRow(tr('about_feat_$i')),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String text;
  const _FeatureRow(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.check_circle,
              size: 15,
              color: AppTheme.green,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppTheme.inkOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
