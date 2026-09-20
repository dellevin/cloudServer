import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../models.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';
import 'zoomable_image.dart';

/// 远程图片预览页 (Telegram 风格): 点开即看 — 列表 128px 缩略图模糊打底,
/// 对端同时下发压缩预览图 (1280px JPEG, 通常几百 KB 秒到), 淡入替换;
/// 原图不自动下载, 顶栏「下载」另起整文件传输, 完成后落盘并改显原图。
/// 双击缩放 / 双指捏合 / 单击显隐控制层。
/// 路由参数: (peerId, 对端路径, 文件名, 大小, 列表缩略图 Future?)
class RemoteImagePage extends StatefulWidget {
  const RemoteImagePage({super.key});

  @override
  State<RemoteImagePage> createState() => _RemoteImagePageState();
}

class _RemoteImagePageState extends State<RemoteImagePage> {
  bool _ready = false;
  String _peerId = '';
  String _path = '';
  String _name = '';
  int _size = 0;

  Uint8List? _thumb; // 列表缩略图 (模糊打底)
  Uint8List? _preview; // 1280px 压缩预览图
  bool _failed = false; // 预览拉取失败 (对端离线/超时/文件被删)
  String? _localPath; // 原图已下载落盘 → 改显本地原图

  bool _bars = true;

  // 「下载原图」另起的整文件传输状态 (与视频播放页同一套跟踪逻辑)
  bool _downloading = false;
  int _dlSince = 0;
  bool _dlHandled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final args =
        ModalRoute.of(context)!.settings.arguments
            as (String, String, String, int, Future<Uint8List?>?);
    _peerId = args.$1;
    _path = args.$2;
    _name = args.$3;
    _size = args.$4;
    args.$5?.then((b) {
      if (b != null && mounted) setState(() => _thumb = b);
    });
    unawaited(_loadPreview());
  }

  /// 拉压缩预览图 (对端实时缩放编码; 旧版对端忽略 max 回 128px, 能看但糊)
  Future<void> _loadPreview() async {
    final c = context.read<RelayClient>();
    final b = await c.fsThumb(_peerId, _path, maxSide: 1280);
    if (!mounted) return;
    setState(() {
      if (b == null) {
        _failed = true;
      } else {
        _preview = b;
      }
    });
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 「下载原图」: 另起一整文件传输 (免确认拉取存缓存),
  /// 完成后由 _watchDownload 复制到下载目录真正落盘
  void _startDownload(RelayClient c) {
    if (_downloading) return;
    if (!c.isOnline(_peerId)) {
      AppToast.show(context, tr('fs_offline'));
      return;
    }
    c.fsGetFileAuto(_peerId, _path, name: _name, size: _size);
    setState(() {
      _downloading = true;
      _dlHandled = false;
      _dlSince = DateTime.now().millisecondsSinceEpoch;
    });
  }

  /// 找本次下载对应的传入传输记录 (发起后新建的最新一条)
  FileTransfer? _dlTransfer(RelayClient c) {
    for (final t in c.transfers.reversed) {
      if (!t.outgoing &&
          t.peerId == _peerId &&
          t.fileName == _name &&
          t.ts >= _dlSince) {
        return t;
      }
    }
    return null;
  }

  /// 盯下载传输状态: 完成落盘并改显原图, 失败提示; build 中调用 (传输变更触发),
  /// 状态清理推到帧后, 避免 build 期 setState
  void _watchDownload(RelayClient c) {
    if (!_downloading || _dlHandled) return;
    final t = _dlTransfer(c);
    if (t == null) return;
    if (t.status == TransferStatus.done && t.savePath != null) {
      _dlHandled = true;
      final src = t.savePath!;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // 复制到下载目录 = 真正落盘 (自带已保存提示)
        final dest = await downloadTempPreview(context, src);
        if (!mounted) return;
        setState(() {
          _downloading = false;
          if (dest != null) _localPath = dest;
        });
      });
    } else if (t.status == TransferStatus.failed ||
        t.status == TransferStatus.canceled ||
        t.status == TransferStatus.rejected) {
      _dlHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _downloading = false);
        AppToast.show(context, tr('st_failed'));
      });
    }
  }

  /// 画面层: 原图 > 预览图 (淡入) > 列表缩略图 (模糊打底) > 空黑
  Widget _imageLayer() {
    final local = _localPath;
    if (local != null) {
      return Image.file(
        File(local),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 48,
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_thumb != null)
          Image.memory(
            _thumb!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.low, // 小图放大有意保糊 (渐进感)
            gaplessPlayback: true,
          ),
        AnimatedOpacity(
          opacity: _preview != null ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 250),
          child: _preview != null
              ? Image.memory(
                  _preview!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    _watchDownload(c);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ZoomableImage(
            onTap: () => setState(() => _bars = !_bars),
            child: _imageLayer(),
          ),
          // 预览图未到: 中央小转圈 (Telegram 同款); 失败: 图标 + 下载原图按钮
          if (_localPath == null && _preview == null)
            Center(
              child: _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54,
                          size: 44,
                        ),
                        const SizedBox(height: 14),
                        TextButton.icon(
                          onPressed: () => _startDownload(c),
                          icon: const Icon(
                            Icons.save_alt,
                            size: 18,
                            color: Colors.white,
                          ),
                          label: Text(
                            '${tr('download_original')} (${_fmtSize(_size)})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white24,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white70,
                      ),
                    ),
            ),
          // 顶栏: 返回 + 文件名/大小 + 下载原图 (单击画面显隐)
          if (_bars)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              _fmtSize(_size),
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 下载原图; 传输中图标换成进度环 (订阅轻量 tick, 不整页重建)
                      if (_localPath == null)
                        _downloading
                            ? Padding(
                                padding: const EdgeInsets.all(14),
                                child: ValueListenableBuilder<int>(
                                  valueListenable: c.progressTick,
                                  builder: (_, _, _) => SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      value: () {
                                        final p =
                                            _dlTransfer(c)?.progress ?? 0.0;
                                        return p > 0 ? p : null;
                                      }(),
                                      strokeWidth: 2,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              )
                            : IconButton(
                                tooltip:
                                    '${tr('download_original')} (${_fmtSize(_size)})',
                                icon: const Icon(
                                  Icons.save_alt,
                                  color: Colors.white,
                                ),
                                onPressed: () => _startDownload(c),
                              ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
