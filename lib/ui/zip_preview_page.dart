import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';

/// zip 文件名乱码修复: archive 包按 UTF-8 解码条目名, 失败时回退成
/// 「每字节→一字符」的伪 latin1 字符串 (国产 Windows 压缩包多为 GBK 且
/// 未设 UTF-8 标志位)。此时原始字节还在 codeUnits 里, 依序尝试还原:
/// 严格 UTF-8 (有些包内容实为 UTF-8) → GBK
String fixZipEntryName(String name) {
  final units = name.codeUnits;
  final hasHigh = units.any((u) => u > 0x7F);
  if (!hasHigh || units.any((u) => u > 0xFF)) return name;
  final bytes = Uint8List.fromList(units);
  try {
    return utf8.decode(bytes); // 严格模式, 非法序列抛异常
  } catch (_) {}
  try {
    // 注意用 gbk_bytes: 同库的 gbk 解码器不会拼双字节, 解不出来
    return gbk_bytes.decode(bytes);
  } catch (_) {}
  return name;
}

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

  String get _path =>
      parseViewerArgs(ModalRoute.of(context)!.settings.arguments).$1;

  /// 是否远程浏览的临时预览 (是则 AppBar 显「下载」按钮)
  bool get _tempPreview =>
      parseViewerArgs(ModalRoute.of(context)!.settings.arguments).$2;

  Future<void> _load() async {
    InputFileStream? input;
    try {
      input = InputFileStream(_path);
      final archive = ZipDecoder().decodeStream(input);
      for (final f in archive.files) {
        f.name = fixZipEntryName(f.name);
      }
      final files = archive.files.where((f) => f.isFile).toList();
      await input.close();
      input = null;
      if (mounted) setState(() => _files = files);
    } catch (_) {
      // 损坏/非 zip: 句柄必须关掉, 否则每次打开泄漏一个
      try {
        await input?.close();
      } catch (_) {}
      if (mounted) setState(() => _error = tr('zip_read_fail'));
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
    try {
      final dir = await context.read<RelayClient>().downloadDir();
      final name = f.name.split(RegExp(r'[\\/]')).last;
      final dest = await _dedupe(dir, name.isEmpty ? 'unnamed' : name);
      final input = InputFileStream(_path);
      OutputFileStream? out;
      var found = false;
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final file in archive.files) {
          // 重新解码得到的是未修复的名字, 先修复再与列表项比对
          if (fixZipEntryName(file.name) == f.name && file.isFile) {
            out = OutputFileStream(dest);
            file.writeContent(out);
            found = true;
            break;
          }
        }
      } finally {
        await out?.close();
        await input.close();
      }
      if (!found) {
        // 条目没找到: 别误报成功, 也别留空文件
        try {
          await File(dest).delete();
        } catch (_) {}
        if (mounted) AppToast.show(context, tr('extract_fail'));
        return;
      }
      if (mounted) {
        AppToast.show(
          context,
          trf('extracted', {'dest': dest}),
          actionLabel: tr('open'),
          onAction: () => OpenFilex.open(dest),
        );
      }
    } catch (_) {
      if (mounted) AppToast.show(context, tr('extract_fail'));
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  /// 全部解压到 下载目录/<压缩包名>/
  Future<void> _extractAll() async {
    if (_extracting) return;
    setState(() => _extracting = true);
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
      // 不用 extractFileToDisk: 解压前要先修复条目名, 并拦掉 ../ 越界路径
      final input = InputFileStream(_path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final file in archive.files) {
          final name = fixZipEntryName(file.name);
          final segs = name.split(RegExp(r'[\\/]'));
          if (segs.contains('..')) continue;
          final outPath = p.joinAll([folder, ...segs]);
          if (!file.isFile) {
            await Directory(outPath).create(recursive: true);
            continue;
          }
          await Directory(p.dirname(outPath)).create(recursive: true);
          final out = OutputFileStream(outPath);
          try {
            file.writeContent(out);
          } finally {
            await out.close();
          }
        }
      } finally {
        await input.close();
      }
      if (mounted) {
        AppToast.show(
          context,
          trf('extracted_to', {'folder': folder}),
          actionLabel: tr('open'),
          onAction: () => OpenFilex.open(folder),
        );
      }
    } catch (_) {
      if (mounted) AppToast.show(context, tr('extract_fail'));
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
        actions: [
          // 远程浏览的临时预览: 「下载」复制压缩包本体到下载目录
          if (_tempPreview)
            IconButton(
              tooltip: tr('download'),
              icon: const Icon(Icons.save_alt, size: 20),
              onPressed: () => downloadTempPreview(context, _path),
            ),
        ],
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
                  label: Text(
                    _extracting
                        ? tr('extracting')
                        : trf('extract_all', {'n': _files!.length}),
                  ),
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
      return Center(
        child: Text(tr('zip_empty'), style: const TextStyle(color: AppTheme.grey)),
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
              child: Text(tr('extract'), style: const TextStyle(fontSize: 12.5)),
            ),
          ),
        );
      },
    );
  }
}
