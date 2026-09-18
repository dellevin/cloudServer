import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../l10n.dart';
import '../main.dart';
import '../models.dart';
import 'action_dialog.dart';
import 'app_toast.dart';

/// 文本类扩展名: 应用内预览
const _textExts = {
  'txt',
  'md',
  'log',
  'json',
  'xml',
  'csv',
  'yaml',
  'yml',
  'ini',
  'cfg',
  'toml',
  'dart',
  'py',
  'js',
  'ts',
  'java',
  'kt',
  'c',
  'h',
  'cpp',
  'hpp',
  'cs',
  'go',
  'rs',
  'sh',
  'bat',
  'ps1',
  'html',
  'css',
  'sql',
  'vue',
  'jsx',
  'tsx',
};

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

/// 图片/视频扩展名
const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
const videoExts = {'mp4', 'mkv', 'avi', 'mov', 'flv', 'webm', 'm4v', '3gp'};

/// 可应用内预览的压缩包扩展名
const archiveExts = {'zip'};

bool isImageFile(String name) => imageExts.contains(_ext(name));
bool isVideoFile(String name) => videoExts.contains(_ext(name));
bool isArchiveFile(String name) => archiveExts.contains(_ext(name));
bool isTextFile(String name) => _textExts.contains(_ext(name));

/// 点击传输记录: 文本/图片/视频/压缩包走应用内预览, 其他(音频/文档)交给系统默认程序
Future<void> openTransfer(BuildContext context, FileTransfer t) async {
  final path = t.savePath;
  if (path == null || !File(path).existsSync()) {
    AppToast.show(context, tr('file_gone'));
    return;
  }
  if (_textExts.contains(_ext(t.fileName))) {
    Navigator.pushNamed(context, '/file_preview', arguments: path);
    return;
  }
  if (isImageFile(t.fileName)) {
    Navigator.pushNamed(context, '/image_view', arguments: path);
    return;
  }
  if (isVideoFile(t.fileName)) {
    Navigator.pushNamed(context, '/video_view', arguments: path);
    return;
  }
  if (isArchiveFile(t.fileName)) {
    Navigator.pushNamed(context, '/zip_view', arguments: path);
    return;
  }
  final r = await OpenFilex.open(path);
  if (r.type != ResultType.done && context.mounted) {
    AppToast.show(context, trf('open_fail', {'msg': r.message}));
  }
}

/// 选择指定软件打开 (Windows 弹"打开方式"对话框; Android 走系统选择器)
Future<void> openTransferWith(BuildContext context, FileTransfer t) async {
  final path = t.savePath;
  if (path == null || !File(path).existsSync()) {
    AppToast.show(context, tr('file_gone'));
    return;
  }
  if (Platform.isWindows) {
    await Process.run('rundll32', ['shell32.dll,OpenAs_RunDLL', path]);
    return;
  }
  final r = await OpenFilex.open(path);
  if (r.type != ResultType.done && context.mounted) {
    AppToast.show(context, trf('open_fail', {'msg': r.message}));
  }
}

/// 打开文件所在位置 (Windows 资源管理器定位并选中; macOS Finder 显示;
/// Linux/Android 打开所在目录, 失败则提示路径)
Future<void> revealTransferInFolder(
  BuildContext context,
  FileTransfer t,
) async {
  final path = t.savePath;
  if (path == null || !File(path).existsSync()) {
    AppToast.show(context, tr('file_gone'));
    return;
  }
  try {
    if (Platform.isWindows) {
      // explorer 成功也可能返回非零退出码, 不据此举异常
      await Process.run('explorer.exe', [
        '/select,${path.replaceAll('/', '\\')}',
      ]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
      return;
    }
    final dir = File(path).parent.path;
    if (Platform.isAndroid) {
      // 部分文件管理器能处理目录打开, 不行则落到下面提示路径
      final r = await OpenFilex.open(dir);
      if (r.type == ResultType.done) return;
    } else {
      await Process.run('xdg-open', [dir]);
      return;
    }
  } catch (_) {}
  if (context.mounted) {
    AppToast.show(
      context,
      trf('file_located', {'dir': File(path).parent.path}),
    );
  }
}

/// 删除确认对话框 (微信动作面板风格, 与消息列表删除会话弹窗一致)
/// 返回 'record' / 'both' / null(取消)
Future<String?> confirmDeleteDialog(
  BuildContext context, {
  required String title,
  String? message,
}) {
  return showActionDialog<String>(
    context,
    title: title,
    message: message,
    actions: [
      (label: tr('del_record_only'), value: 'record', danger: false),
      (label: tr('del_record_file'), value: 'both', danger: true),
    ],
  );
}

/// 传输删除确认对话框: 返回 'record' / 'both' / null(取消)
Future<String?> confirmDeleteTransfer(BuildContext context, FileTransfer t) {
  return confirmDeleteDialog(
    context,
    title: tr('del_transfer_title'),
    message: t.status == TransferStatus.waiting
        ? trf('del_transfer_waiting', {'name': t.fileName})
        : trf('file_quoted', {'name': t.fileName}),
  );
}

/// 图片全屏查看页 (可缩放)
class ImageViewPage extends StatelessWidget {
  const ImageViewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final path = ModalRoute.of(context)!.settings.arguments as String;
    final name = path.split(RegExp(r'[\\/]')).last;
    // 限制解码分辨率防 OOM (留 2x 余量供双指放大)
    final cacheWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context) *
                2)
            .round();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 8,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            errorBuilder: (_, _, _) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 48,
            ),
          ),
        ),
      ),
    );
  }
}

/// 文本文件预览页
class FilePreviewPage extends StatelessWidget {
  const FilePreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final path = ModalRoute.of(context)!.settings.arguments as String;
    final name = path.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: AppTheme.bgSoft,
      appBar: AppBar(
        backgroundColor: AppTheme.bgSoft,
        title: Text(name, style: const TextStyle(fontSize: 15)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: FutureBuilder<String>(
        future: _readText(path),
        builder: (_, snap) {
          if (snap.hasError) {
            return Center(
              child: Text(
                tr('not_text'),
                style: const TextStyle(color: AppTheme.grey),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.hairline),
                ),
                child: SelectableText(
                  snap.data!,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: AppTheme.ink,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<String> _readText(String path) async {
    final f = File(path);
    final size = await f.length();
    const cap = 512 * 1024;
    final bytes = size <= cap
        ? await f.readAsBytes()
        : await f.openRead(0, cap).fold<List<int>>([], (a, b) => a..addAll(b));
    String text;
    try {
      text = const Utf8Decoder().convert(bytes);
    } catch (_) {
      text = String.fromCharCodes(bytes);
    }
    if (size > cap) text += '\n\n... (${tr('too_large')})';
    return text;
  }
}
