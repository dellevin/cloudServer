import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';

/// 压缩包预览页: 列出 zip 内容, 支持解压单个文件 / 全部解压到下载目录
class ZipPreviewPage extends StatefulWidget {
  const ZipPreviewPage({super.key});

  @override
  State<ZipPreviewPage> createState() => _ZipPreviewPageState();
}

class _ZipPreviewPageState extends State<ZipPreviewPage> {
  List<ArchiveFile>? _files;
  String? _error;
  bool _extracting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_files != null || _error != null) return;
    _load();
  }

  String get _path => ModalRoute.of(context)!.settings.arguments as String;

  Future<void> _load() async {
    try {
      final input = InputFileStream(_path);
      final archive = ZipDecoder().decodeStream(input);
      final files = archive.files.where((f) => f.isFile).toList();
      await input.close();
      if (mounted) setState(() => _files = files);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取压缩包 (可能已损坏或不是 zip 格式)');
    }
  }

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 目标路径去重: 已存在则追加 (1)(2)…
  static Future<String> _dedupe(String dir, String name) async {
    var dest = '$dir${Platform.pathSeparator}$name';
    var i = 1;
    while (await File(dest).exists()) {
      final dot = name.lastIndexOf('.');
      dest = dot > 0
          ? '$dir${Platform.pathSeparator}${name.substring(0, dot)}($i)${name.substring(dot)}'
          : '$dir${Platform.pathSeparator}$name($i)';
      i++;
    }
    return dest;
  }

  /// 解压单个文件到下载目录
  Future<void> _extractOne(ArchiveFile f) async {
    if (_extracting) return;
    setState(() => _extracting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await context.read<RelayClient>().downloadDir();
      final name = f.name.split(RegExp(r'[\\/]')).last;
      final dest = await _dedupe(dir, name.isEmpty ? 'unnamed' : name);
      final input = InputFileStream(_path);
      OutputFileStream? out;
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final file in archive.files) {
          if (file.name == f.name && file.isFile) {
            out = OutputFileStream(dest);
            file.writeContent(out);
            break;
          }
        }
      } finally {
        await out?.close();
        await input.close();
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text('已解压: $dest'),
          action: SnackBarAction(
            label: '打开',
            onPressed: () => OpenFilex.open(dest),
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('解压失败')));
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  /// 全部解压到 下载目录/<压缩包名>/
  Future<void> _extractAll() async {
    if (_extracting) return;
    setState(() => _extracting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await context.read<RelayClient>().downloadDir();
      final base = _path.split(RegExp(r'[\\/]')).last;
      final dot = base.lastIndexOf('.');
      var folder = await _dedupe(dir, dot > 0 ? base.substring(0, dot) : base);
      // _dedupe 按文件逻辑加后缀, 这里要的是全新目录名
      while (await Directory(folder).exists()) {
        folder = '${folder}_1';
      }
      await Directory(folder).create(recursive: true);
      await extractFileToDisk(_path, folder);
      messenger.showSnackBar(
        SnackBar(
          content: Text('已解压到: $folder'),
          action: SnackBarAction(
            label: '打开',
            onPressed: () => OpenFilex.open(folder),
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('解压失败')));
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _path.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontSize: 15)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: _buildBody(context),
      bottomNavigationBar: _files == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _extracting ? null : _extractAll,
                  icon: _extracting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.unarchive_outlined, size: 18),
                  label: Text(_extracting ? '解压中…' : '全部解压 (${_files!.length} 个文件)'),
                ),
              ),
            ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: AppTheme.grey)),
      );
    }
    final files = _files;
    if (files == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (files.isEmpty) {
      return const Center(
        child: Text('压缩包是空的', style: TextStyle(color: AppTheme.grey)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: files.length,
      itemBuilder: (_, i) {
        final f = files[i];
        final short = f.name.split(RegExp(r'[\\/]')).last;
        final dir = f.name.length > short.length
            ? f.name.substring(0, f.name.length - short.length)
            : '';
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.cardOf(context),
            border: Border.all(color: AppTheme.lineOf(context)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            leading: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.softOf(context),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.insert_drive_file_outlined,
                size: 17,
                color: AppTheme.green,
              ),
            ),
            title: Text(
              short.isEmpty ? f.name : short,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${dir.isEmpty ? '' : '$dir · '}${_fmt(f.size)}',
              style: const TextStyle(fontSize: 11, color: AppTheme.grey),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton(
              onPressed: _extracting ? null : () => _extractOne(f),
              child: const Text('解压', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        );
      },
    );
  }
}
