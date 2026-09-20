import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';

/// 远程文件页 (微信「文件下载」风格): 不能直接预览的类型/超限文件点进来,
/// 大图标 + 文件名 + 大小; 「下载」把文件拉到缓存再落盘到下载目录,
/// 完成后可打开/系统分享
class RemoteFilePage extends StatefulWidget {
  const RemoteFilePage({super.key});

  @override
  State<RemoteFilePage> createState() => _RemoteFilePageState();
}

class _RemoteFilePageState extends State<RemoteFilePage> {
  String _peerId = '';
  String _path = '';
  String _name = '';
  int _size = 0;
  bool _argsReady = false;

  int _since = 0; // 本次拉取发起时间 (匹配对应传输记录)
  bool _pulling = false;
  bool _watchHandled = false; // 防多帧 build 重复处理完成/失败
  String? _savedPath; // 已落盘到下载目录的路径
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsReady) return;
    _argsReady = true;
    final (peerId, path, name, size) =
        ModalRoute.of(context)!.settings.arguments
            as (String, String, String, int);
    _peerId = peerId;
    _path = path;
    _name = name;
    _size = size;
  }

  /// 本次拉取对应的传入传输记录 (发起后新建的最新一条)
  FileTransfer? _pending(RelayClient c) {
    if (!_pulling) return null;
    for (final t in c.transfers.reversed) {
      if (!t.outgoing &&
          t.peerId == _peerId &&
          t.fileName == _name &&
          t.ts >= _since) {
        return t;
      }
    }
    return null;
  }

  void _startDownload() {
    final c = context.read<RelayClient>();
    if (!c.isOnline(_peerId)) {
      AppToast.show(context, tr('fs_offline'));
      return;
    }
    setState(() {
      _pulling = true;
      _failed = false;
      _watchHandled = false;
      _since = DateTime.now().millisecondsSinceEpoch;
    });
    // 登记自动接收: 对端回传的 offer 免确认直接收 (存缓存, 完成后再落盘)
    c.fsGetFileAuto(_peerId, _path, name: _name, size: _size);
  }

  /// 盯传输状态 (build 中调用, 传输变更触发); 完成落盘/失败提示都推到帧后
  void _watch(RelayClient c) {
    if (!_pulling || _watchHandled) return;
    final t = _pending(c);
    if (t == null) return;
    if (t.status == TransferStatus.done && t.savePath != null) {
      _watchHandled = true;
      final src = t.savePath!;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // 复制到下载目录 = 真正下载 (自带已保存提示)
        final dest = await downloadTempPreview(context, src);
        if (!mounted) return;
        setState(() {
          _pulling = false;
          _savedPath = dest;
          _failed = dest == null;
        });
      });
    } else if (t.status == TransferStatus.failed ||
        t.status == TransferStatus.canceled ||
        t.status == TransferStatus.rejected) {
      _watchHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _pulling = false;
          _failed = true;
        });
        AppToast.show(context, tr('st_failed'));
      });
    }
  }

  Future<void> _share() async {
    final p = _savedPath;
    if (p == null) return;
    try {
      final r = await SharePlus.instance.share(
        ShareParams(files: [XFile(p)], text: _name),
      );
      if (r.status == ShareResultStatus.unavailable && mounted) {
        AppToast.show(context, tr('unsupported'));
      }
    } catch (e) {
      if (mounted) AppToast.show(context, trf('share_fail', {'err': e}));
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

  static (IconData, Color) _iconFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    if (isImageFile(name)) {
      return (Icons.image_outlined, const Color(0xFF4C8DFF));
    }
    if (isVideoFile(name)) {
      return (Icons.videocam_outlined, const Color(0xFF8A5CF6));
    }
    if (isArchiveFile(name) || const {'rar', '7z', 'tar', 'gz'}.contains(ext)) {
      return (Icons.folder_zip_outlined, const Color(0xFFC9A227));
    }
    if (const {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'}.contains(ext)) {
      return (Icons.audiotrack_outlined, const Color(0xFFFF7A45));
    }
    if (ext == 'pdf') {
      return (Icons.picture_as_pdf_outlined, const Color(0xFFFA5151));
    }
    return (Icons.insert_drive_file_outlined, const Color(0xFF576B95));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    _watch(c);
    final t = _pending(c);
    final (icon, color) = _iconFor(_name);

    return Scaffold(
      backgroundColor: AppTheme.softOf(context),
      appBar: AppBar(
        title: Text(
          _name,
          style: const TextStyle(fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 36, color: color),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkOf(context),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _fmt(_size),
              style: const TextStyle(fontSize: 12, color: AppTheme.grey),
            ),
            if (_failed) ...[
              const SizedBox(height: 10),
              Text(
                tr('st_failed'),
                style: const TextStyle(fontSize: 12, color: AppTheme.red),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _savedPath != null
              ? Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () =>
                            openPath(context, _savedPath!, _name),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(tr('open')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.share_outlined, size: 18),
                        label: Text(tr('share')),
                      ),
                    ),
                  ],
                )
              : _pulling
              // 订阅轻量进度 tick: 传输中的进度推进不走 notifyListeners
              // (节流设计), 不订阅的话进度会一直冻在开始时的 0%
              ? ValueListenableBuilder<int>(
                  valueListenable: c.progressTick,
                  builder: (context, _, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        value: t == null || t.progress <= 0 ? null : t.progress,
                        color: AppTheme.green,
                        backgroundColor: AppTheme.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t == null
                            ? '…'
                            : '${(t.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.grey,
                        ),
                      ),
                    ],
                  ),
                )
              : FilledButton.icon(
                  onPressed: _startDownload,
                  icon: Icon(
                    _failed ? Icons.refresh : Icons.download,
                    size: 18,
                  ),
                  label: Text(
                    _failed
                        ? tr('retry')
                        : '${tr('download')} (${_fmt(_size)})',
                  ),
                ),
        ),
      ),
    );
  }
}
