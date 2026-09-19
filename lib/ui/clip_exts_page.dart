import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';

/// 自定义拦截扩展名编辑页: 每行一个扩展名, 输入即保存
/// (setClipBlockedExts 会自动去空白/小写/去前导点/去重)
class ClipExtsPage extends StatefulWidget {
  const ClipExtsPage({super.key});

  @override
  State<ClipExtsPage> createState() => _ClipExtsPageState();
}

class _ClipExtsPageState extends State<ClipExtsPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: context.read<RelayClient>().clipBlockedExts.join('\n'),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('clip_custom_exts')),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              color: AppTheme.cardOf(context),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.8,
                  color: AppTheme.inkOf(context),
                ),
                cursorColor: AppTheme.green,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(14),
                  hintText: tr('clip_custom_exts_hint'),
                  hintStyle: const TextStyle(
                    fontSize: 14,
                    height: 1.8,
                    color: AppTheme.grey,
                  ),
                ),
                onChanged: (v) => c.setClipBlockedExts(v.split('\n')),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              tr('clip_custom_exts_desc'),
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.grey,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
