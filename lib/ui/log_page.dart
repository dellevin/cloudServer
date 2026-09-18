import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../log.dart';
import '../main.dart';
import 'app_toast.dart';

/// 运行日志查看页: 显示日志尾部, 可刷新/导出到下载目录/清空
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  late String _text = tr('loading');
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final text = await Log.readTail();
    if (mounted) setState(() => _text = text);
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final client = context.read<RelayClient>();
    try {
      final src = Log.filePath;
      if (src == null || !await File(src).exists()) {
        _toast(tr('no_log'));
        return;
      }
      final dir = await client.downloadDir();
      final d = DateTime.now();
      String p2(int v) => v.toString().padLeft(2, '0');
      final dest =
          '$dir${Platform.pathSeparator}cloudsend_log_'
          '${d.year}${p2(d.month)}${p2(d.day)}_'
          '${p2(d.hour)}${p2(d.minute)}${p2(d.second)}.txt';
      await File(src).copy(dest);
      _toast(trf('log_exported', {'dest': dest}));
    } catch (e) {
      _toast(trf('log_export_fail', {'e': e}));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.cardOf(dctx),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          tr('clear_log_title'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Text(
          tr('clear_log_msg'),
          style: const TextStyle(fontSize: 13, color: AppTheme.grey),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(tr('clear_all')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await Log.clear();
      await _reload();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.show(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(tr('run_log')),
        actions: [
          IconButton(
            tooltip: tr('refresh'),
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _reload,
          ),
          IconButton(
            tooltip: tr('export_log'),
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt, size: 20),
            onPressed: _exporting ? null : _export,
          ),
          IconButton(
            tooltip: tr('clear_all'),
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: _clear,
          ),
          const SizedBox(width: 6),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          _text,
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            fontFamily: 'monospace',
            color: AppTheme.inkOf(context),
          ),
        ),
      ),
    );
  }
}
