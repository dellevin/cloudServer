import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../log.dart';
import '../main.dart';

/// 运行日志查看页: 显示日志尾部, 可刷新/导出到下载目录/清空
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  String _text = '加载中…';
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
    try {
      final src = Log.filePath;
      if (src == null || !await File(src).exists()) {
        _toast('暂无日志可导出');
        return;
      }
      final dir = await context.read<RelayClient>().downloadDir();
      final d = DateTime.now();
      String p2(int v) => v.toString().padLeft(2, '0');
      final dest =
          '$dir${Platform.pathSeparator}cloudsend_log_'
          '${d.year}${p2(d.month)}${p2(d.day)}_'
          '${p2(d.hour)}${p2(d.minute)}${p2(d.second)}.txt';
      await File(src).copy(dest);
      _toast('已导出: $dest');
    } catch (e) {
      _toast('导出失败: $e');
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
        title: const Text(
          '清空日志',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          '确定要清空全部运行日志吗？',
          style: TextStyle(fontSize: 13, color: AppTheme.grey),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('清空'),
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _reload,
          ),
          IconButton(
            tooltip: '导出到下载目录',
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
            tooltip: '清空',
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
