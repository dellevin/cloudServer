import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../l10n.dart';
import '../main.dart';
import '../models.dart';
import 'app_toast.dart';
import 'file_preview_page.dart';

/// 远程文件浏览页: 像文件管理器一样浏览对端设备的存储,
/// 点目录进入; 点文件 = 预览 (可预览类型且 ≤20MB: 走临时传输,
/// 存缓存目录、不入库、不进聊天/传输记录, 完成自动打开预览, 重启即清);
/// 点行尾下载按钮 = 真正下载 (普通接收确认流程, 落盘到下载目录)。
/// Android 从共享存储根起步; Windows 先列磁盘分区 (C:\ D:\ ...)
class RemoteFsPage extends StatefulWidget {
  const RemoteFsPage({super.key});

  @override
  State<RemoteFsPage> createState() => _RemoteFsPageState();
}

class _RemoteFsPageState extends State<RemoteFsPage> {
  String? peerId;
  bool _isWin = false; // 对端是否 Windows (决定根与路径分隔符)
  // 浏览路径栈: Android ['/storage/emulated/0', ...]; Windows ['C:', ...] (空=盘符根)
  final List<String> _stack = [];
  // 当前目录条目缓存: null=加载中, 带 error 键=失败
  Map<String, dynamic>? _result;
  // 防止快速点目录时旧应答覆盖新目录
  int _seq = 0;

  /// 直接预览的大小上限: 超过走普通下载流程 (弹接收确认框)
  static const int _previewMax = 20 * 1024 * 1024;

  /// 正在等待自动预览的文件名 / 拉取发起时间 (毫秒); null = 无待预览
  String? _previewName;
  int _previewSince = 0;

  /// 是否可应用内预览 (与 openTransfer 的类型分派一致)
  static bool _previewable(String name) =>
      isImageFile(name) ||
      isVideoFile(name) ||
      isArchiveFile(name) ||
      isTextFile(name);

  /// 点文件 = 预览: 走临时传输 (存缓存、不入库、不进聊天/传输记录),
  /// 完成后自动打开预览, 重启即清; 真正下载要点行尾的下载按钮
  void _tapFile(RelayClient c, String name, int size) {
    if (!_previewable(name)) {
      AppToast.show(context, tr('fs_no_preview'));
      return;
    }
    if (size <= 0 || size > _previewMax) {
      AppToast.show(context, trf('fs_too_big', {'max': _fmt(_previewMax)}));
      return;
    }
    if (_previewName != null) return; // 一次只拉一个
    setState(() {
      _previewName = name;
      _previewSince = DateTime.now().millisecondsSinceEpoch;
    });
    c.fsGetFileAuto(peerId!, _child(name), name: name, size: size);
    // 对端迟迟不回 offer (离线/文件被删): 超时退出等待 (登记 30s 过期,
    // 之后到达的同名 offer 会回落成普通接收确认框)
    Timer(const Duration(seconds: 32), () {
      if (mounted &&
          _previewName == name &&
          _pendingTransfer(context.read<RelayClient>()) == null) {
        setState(() => _previewName = null);
        AppToast.show(context, tr('fs_timeout'));
      }
    });
  }

  /// 行尾下载按钮: 走普通接收流程 (弹确认框, 落盘到下载目录)
  void _download(RelayClient c, String name) {
    c.fsGetFile(peerId!, _child(name));
    AppToast.show(context, trf('fs_get_sent', {'name': name}));
  }

  /// 找本次拉取对应的传入传输记录 (发起后新建的最新一条)
  FileTransfer? _pendingTransfer(RelayClient c) {
    final name = _previewName;
    if (name == null) return null;
    for (final t in c.transfers.reversed) {
      if (!t.outgoing &&
          t.peerId == peerId &&
          t.fileName == name &&
          t.ts >= _previewSince) {
        return t;
      }
    }
    return null;
  }

  /// 盯传输状态: 完成开预览, 失败提示; build 中调用 (传输变更触发),
  /// 状态清理和跳路由都推到帧后, 避免 build 期 setState
  void _watchPreview(RelayClient c) {
    if (_previewName == null) return;
    final t = _pendingTransfer(c);
    if (t == null) return;
    if (t.status == TransferStatus.done && t.savePath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _previewName = null);
        openTransfer(context, t);
      });
    } else if (t.status == TransferStatus.failed ||
        t.status == TransferStatus.canceled ||
        t.status == TransferStatus.rejected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _previewName = null);
        AppToast.show(context, tr('st_failed'));
      });
    }
  }

  String get _path {
    if (_isWin) {
      if (_stack.isEmpty) return ''; // 虚拟根: 列出磁盘分区
      final p = _stack.join('\\');
      // 单段是盘符根 (C:\), 必须带反斜杠否则是驱动器当前目录
      return _stack.length == 1 ? '$p\\' : p;
    }
    return _stack.join('/');
  }

  bool get _atRoot => _isWin ? _stack.isEmpty : _stack.length <= 1;

  /// 当前目录下名为 name 的子项完整路径
  String _child(String name) {
    if (_isWin) {
      final p = _path;
      return p.endsWith('\\') ? '$p$name' : '$p\\$name';
    }
    return '$_path/$name';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (peerId == null) {
      peerId = ModalRoute.of(context)!.settings.arguments as String;
      final c = context.read<RelayClient>();
      Peer? peer;
      for (final p in c.peers) {
        if (p.id == peerId) {
          peer = p;
          break;
        }
      }
      _isWin = peer?.platform == 'windows';
      if (!_isWin) _stack.add('/storage/emulated/0');
      _load();
    }
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _result = null);
    final c = context.read<RelayClient>();
    final r = await c.fsListDir(peerId!, _path);
    if (!mounted || seq != _seq) return;
    setState(() => _result = r ?? {'error': 'offline'});
  }

  void _enter(String name) {
    _stack.add(name);
    _load();
  }

  bool _up() {
    if (_atRoot) return false;
    _stack.removeLast();
    _load();
    return true;
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    _watchPreview(c);
    final name = c.peerName(peerId ?? '');
    final r = _result;
    final err = r?['error'];
    final entries = (r?['entries'] as List?) ?? const [];
    final pending = _pendingTransfer(c);

    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        backgroundColor: AppTheme.softOf(context),
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () {
              if (!_up()) Navigator.pop(context);
            },
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trf('fs_title', {'name': name}),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _path.isEmpty ? tr('fs_drives') : _path,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.grey),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1),
          ),
        ),
        body: err != null
            ? _ErrorView(error: '$err', onRetry: _load)
            : r == null
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.green,
                  ),
                ),
              )
            : RefreshIndicator(
                color: AppTheme.green,
                onRefresh: _load,
                child: entries.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Center(
                            child: Text(
                              tr('fs_empty'),
                              style: const TextStyle(color: AppTheme.grey),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: 52,
                          color: AppTheme.lineOf(context),
                        ),
                        itemBuilder: (_, i) {
                          final e = entries[i] as Map;
                          final isDir = e['dir'] == true;
                          final ename = e['name'] as String;
                          // 该文件正在拉取等待预览: 尾部转圈, 副标题显进度
                          final pulling =
                              !isDir &&
                              _previewName == ename &&
                              pending != null &&
                              (pending.status == TransferStatus.waiting ||
                                  pending.status ==
                                      TransferStatus.accepted ||
                                  pending.status ==
                                      TransferStatus.transferring);
                          final waitingOffer =
                              !isDir && _previewName == ename && pending == null;
                          return Container(
                            color: AppTheme.cardOf(context),
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                _isWin && _stack.isEmpty
                                    ? Icons
                                          .storage // 磁盘分区
                                    : isDir
                                    ? Icons.folder_outlined
                                    : Icons.insert_drive_file_outlined,
                                size: 22,
                                color: isDir
                                    ? const Color(0xFFE6A23C)
                                    : AppTheme.grey,
                              ),
                              title: Text(
                                ename,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.inkOf(context),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: isDir
                                  ? null
                                  : Text(
                                      pulling
                                          ? '${_fmt(e['size'] as int? ?? 0)} · ${(pending.progress * 100).toStringAsFixed(0)}%'
                                          : _fmt(e['size'] as int? ?? 0),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.grey,
                                      ),
                                    ),
                              trailing: pulling || waitingOffer
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.green,
                                      ),
                                    )
                                  : isDir
                                  ? const Icon(
                                      Icons.chevron_right,
                                      size: 18,
                                      color: AppTheme.grey,
                                    )
                                  : IconButton(
                                      // 显式下载: 走普通接收确认流程落盘
                                      tooltip: tr('download'),
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(
                                        Icons.download,
                                        size: 18,
                                        color: AppTheme.grey,
                                      ),
                                      onPressed: () => _download(c, ename),
                                    ),
                              onTap: () {
                                if (isDir) {
                                  _enter(ename);
                                } else {
                                  _tapFile(c, ename, e['size'] as int? ?? 0);
                                }
                              },
                            ),
                          );
                        },
                      ),
              ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_off_outlined, size: 40, color: AppTheme.grey),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              error == 'no_permission'
                  ? tr('fs_no_permission')
                  : error == 'offline'
                  ? tr('fs_offline')
                  : error == 'timeout'
                  ? tr('fs_timeout')
                  : trf('fs_fail', {'msg': error}),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.grey,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onRetry, child: Text(tr('retry'))),
        ],
      ),
    );
  }
}
