import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'db.dart';
import 'e2ee.dart';
import 'image_compress.dart';
import 'l10n.dart';
import 'lan.dart';
import 'log.dart';
import 'models.dart';
import 'stream_server.dart';
import 'transfer_service.dart';
import 'ui/video_thumbs.dart';

/// 中继协议:
/// 文本帧(JSON):
///  C->S {type:'register', id, name}
///  S->C {type:'peers', peers:[{id,name}...]}
///  转发(带 from/to): chat / chat_ack / file_offer / file_accept / file_reject
///    / file_done / file_progress / file_result / file_cancel / clip_text
/// 二进制帧: 36字节 transferId(ASCII) + 文件数据块, 服务器按 transferId 路由
///
/// 传输可靠性:
///  - 接收端写入 `<savePath>.part` 临时文件, 校验通过后改名;
///    超过 500MB 的大文件按 500MB 一片写 `<savePath>.segN`, 收齐后合并校验
///  - file_accept 带 offset: 已收字节数, 发送端从该偏移续传
///  - file_progress: 接收端每收 2MB 回执一次, 发送端 8MB 窗口背压
///  - file_done 带 sha256, 接收端校验后回 file_result {ok}
///
/// v2 大文件增强 (file_offer/file_accept 各带 v2 标志双向协商, 旧版忽略):
///  - 分片哈希: 发送端每发完一片发 file_seg_hash, 接收端记 .seghash 边车;
///    续传前逐片校验已收片 (坏片及后续删除, 只重收坏的部分),
///    收完逐片校验 + 纯拷贝合并, 不再重算总哈希 (file_done 不带 sha256)
///  - 秒传: 接收端发现本地有同名同大小文件 → file_instant 带哈希,
///    发送端比对一致则 file_done {instant:true} 免传, 否则 file_instant_nack 回退
///  - 并行车道: LAN 直连 + 全新大文件, 发送端 dialLane 另起一条 TCP 车道,
///    主链路+车道按片领取并发 (40 字节头: 36 tid + 4 片号);
///    file_accept_pending 用于上述耗时准备期间给 offer 等待续期
///
/// 局域网直连 (见 lan.dart):
///  - UDP 广播自动发现同网段设备, peers 为中继+局域网合并列表
///  - 对端在局域网内时控制消息和二进制块优先走 TCP 直连, 失败回退中继
class RelayClient extends ChangeNotifier {
  String deviceId = '';
  String deviceName = '';
  String avatarPath = '';
  String serverAddr = '';
  bool connected = false;
  bool darkMode = false;

  /// 功能模式: both=局域网+中继 (默认, 局域网优先, 失败/离网自动切中继)
  /// relay=仅中继 (停用局域网发现与直连) / lan=仅局域网 (不连中继)
  String connMode = 'both';
  bool get _lanActive => connMode != 'relay';
  bool get _relayActive => connMode != 'lan';

  /// 多文件排队发送: 同一对端同时只传一个, 避免带宽互抢 (默认开)
  bool queueSends = true;

  /// 发送图片前用 Luban 算法压缩 (默认开); 关闭时相册/拍照发原图
  bool compressImages = true;

  // ---- 剪贴板同步 (仅信任设备; 2s 轮询本机剪贴板, 文本/图片/文件) ----

  /// 总开关 (默认开): 关闭后不监听本机剪贴板也不接收对端同步
  bool clipSyncEnabled = true;

  /// 收到对端剪贴板文本后自动写入本机剪贴板 (默认关: 只进列表, 手动点复制)
  bool clipAutoPaste = false;

  /// 上传黑名单: 不上传压缩包/图片/视频 (默认全部允许)
  bool clipBlockArchives = false;
  bool clipBlockImages = false;
  bool clipBlockVideos = false;

  /// 上传黑名单: 自定义扩展名 (小写, 不带点, 如 ifo / c)
  List<String> clipBlockedExts = [];

  /// 信任的设备 (设备ID): 这些设备发来的文件自动接受, 不再弹窗询问
  Set<String> trustedPeers = {};

  /// 服务器接入密码 (服务器启用 --access-key 时必须填写, 否则被踢)
  String serverKey = '';

  /// P2P 打洞直连 (默认开): 中继传输时尝试与对方建立跨网段 TCP 直连,
  /// 成功后续传数据不走服务器, 失败静默回落中继
  bool p2pEnabled = true;

  /// 拉黑的设备 (设备ID): 其聊天消息静默丢弃, 文件请求自动拒绝
  Set<String> blockedPeers = {};

  /// 拉黑时缓存的设备名 (黑名单管理页显示; 对方离线时 peerName 只剩 ID)
  Map<String, String> blockedPeerNames = {};

  /// 拉黑的 IP: 局域网连接/宣告直接忽略 (中继看不到对端 IP, 仅局域网生效)
  Set<String> blockedIps = {};

  /// 历史连接过的设备 (持久化): id → {name, avatar, platform, lastSeen},
  /// 设备页「未在线」分组的数据源; 上线时由 _rebuildPeers 更新
  Map<String, Map<String, dynamic>> knownPeers = {};

  List<Peer> peers = []; // 中继 + 局域网合并后的在线设备
  List<Peer> _relayPeers = []; // 仅中继服务器下发的在线设备
  Set<String> _relayIds = {};
  List<String> manualLanTargets = []; // 手动添加的局域网设备 "ip:port"
  final List<FileTransfer> transfers = [];
  // transferId 索引: 每个文件块 (64~256KB) 都查一次 _find, 线性扫描在
  // 高速传输 + 历史记录多时是纯 CPU 浪费; 增删 transfers 必须同步维护
  final Map<String, FileTransfer> _transferIdx = {};
  final Map<String, List<ChatMessage>> chats = {};
  final Map<String, int> unread = {};

  /// 登记一条传输 (维护 tid 索引; 顺手修剪终结的 ephemeral 记录防列表膨胀)
  void _addTransfer(FileTransfer t) {
    transfers.add(t);
    _transferIdx[t.transferId] = t;
    if (t.ephemeral) _pruneEphemeral();
  }

  /// ephemeral (预览/剪贴板) 临时传输不入库, 重启即弃; 但会话期内完成后
  /// 也一直留在 transfers 里, 长期运行越攒越多拖慢每次全表遍历。
  /// 终结超 5 分钟的清掉 (预览页完成即取走文件, 不会再查旧记录)
  void _pruneEphemeral() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
    for (var i = transfers.length - 1; i >= 0; i--) {
      final x = transfers[i];
      if (!x.ephemeral || x.ts > cutoff) continue;
      if (x.status == TransferStatus.done ||
          x.status == TransferStatus.failed ||
          x.status == TransferStatus.canceled ||
          x.status == TransferStatus.rejected) {
        _transferIdx.remove(x.transferId);
        transfers.removeAt(i);
      }
    }
  }

  /// 移除一条传输 (维护 tid 索引)
  void _removeTransfer(FileTransfer t) {
    _transferIdx.remove(t.transferId);
    transfers.remove(t);
  }

  /// 要在 UI 展示的传输记录 (预览拉取的 ephemeral 临时传输不入库不上列表;
  /// hidden = 用户在列表里「删除」的, 仅对列表隐藏, 聊天页文件消息保留)
  List<FileTransfer> get visibleTransfers =>
      transfers.where((t) => !t.ephemeral && !t.hidden).toList();

  late LanManager _lan; // 仅中继模式下为已 dispose 的空实例 (不启动发现/直连)

  WebSocketChannel? _ch;
  Timer? _reconnectTimer;
  // 连接代次: 每次 connect/disconnect 自增, 使等待握手期间的旧连接失效
  // (两次 connect 交错时先到位的 channel 不会被后者覆盖成无人持有的泄漏连接)
  int _connectSeq = 0;
  bool _manualClose = false;
  int _retryCount = 0; // 重连次数 (指数退避用, 连上后归零)
  bool _svcSyncPending = false;

  /// 被服务器拒绝的原因 (kick=踢下线/black_id=拉黑ID/black_ip=拉黑IP/white=不在白名单)
  /// null=正常; 被拦后停止自动重连, 由用户手动重连 (connect 时清除)
  String? blockedReason;

  /// 被拦原因 → 用户可读文案
  static String blockedText(String reason) => switch (reason) {
    'kick' => tr('blocked_kick'),
    'black_id' => tr('blocked_black_id'),
    'black_ip' => tr('blocked_black_ip'),
    'white' => tr('blocked_white'),
    'rate' => tr('blocked_rate'),
    'auth' => tr('blocked_auth'),
    'auth_ban' => tr('blocked_auth_ban'),
    _ => tr('blocked_unknown'),
  };

  /// 传输状态变化时同步 Android 前台服务 (microtask 节流)
  @override
  void notifyListeners() {
    super.notifyListeners();
    _syncTransferService();
  }

  void _syncTransferService() {
    if (!Platform.isAndroid || _svcSyncPending) return;
    _svcSyncPending = true;
    scheduleMicrotask(() {
      _svcSyncPending = false;
      TransferForegroundService.sync(
        transfers
            .where(
              (t) =>
                  t.status == TransferStatus.accepted ||
                  t.status == TransferStatus.transferring ||
                  // 校验中也保持前台服务: 大文件合并数分钟, 进程被杀则前功尽弃
                  t.status == TransferStatus.verifying,
            )
            .toList(),
      );
    });
  }

  /// 未读数持久化 + 更新应用图标角标
  void _unreadChanged() {
    SharedPreferences.getInstance().then(
      (sp) => sp.setString('unread', jsonEncode(unread)),
    );
    _updateBadge();
  }

  void _updateBadge() {
    if (!Platform.isAndroid) return;
    try {
      final total = unread.values.fold<int>(0, (a, b) => a + b);
      AppBadgePlus.updateBadge(total);
    } catch (_) {}
  }

  /// 当前正在查看的聊天对端 (用于不收未读/不弹通知)
  String? activePeerId;

  /// 收到文件传输请求的事件流 (UI 全局弹窗用)
  final StreamController<FileTransfer> _fileOfferCtrl =
      StreamController<FileTransfer>.broadcast();
  Stream<FileTransfer> get fileOffers => _fileOfferCtrl.stream;

  /// 自动重试 3 次仍失败的事件流 (UI 弹窗询问用户是否继续)
  final StreamController<FileTransfer> _retryAskCtrl =
      StreamController<FileTransfer>.broadcast();
  Stream<FileTransfer> get retryAsks => _retryAskCtrl.stream;

  /// 应用是否在前台 (后台时即使开着聊天页也要计未读+弹通知)
  bool _appForeground = true;

  void _initLifecycle() {
    AppLifecycleListener(
      onStateChange: (s) => _appForeground = s == AppLifecycleState.resumed,
    );
  }

  final Map<String, IOSink> _incoming = {};
  final Set<String> _accepting = {}; // acceptFile 防重入 (见下方注释)
  final Map<String, int> _recvAcked = {}; // 接收侧上次回执的字节数
  // 大文件分片接收: 超过 _segThreshold 的文件按 _segSize 一片写 .segN,
  // 收齐后合并成 .part 再校验改名; 中断只丢当前半片, 完整片可直接续传
  static const int _segThreshold = 500 * 1024 * 1024;
  static const int _segSize = 500 * 1024 * 1024;
  // 秒传: 小于该大小不值得哈希一遍直接传; v2 对端 + 本地有同名同大小文件时启用
  static const int _instantThreshold = 64 * 1024 * 1024;
  final Map<String, int> _recvSeg = {}; // 当前片序号 (含 tid 即为分片模式)
  final Set<String> _finishing = {}; // 合并+校验进行中 (防 file_done 重入)
  // 接收侧写盘串行链: add/flush/回执全部排队执行 (见分块处理器处注释)
  final Map<String, Future<void>> _recvChain = {};
  final Map<String, int> _recvLastTs = {}; // 接收侧最后收到分块的毫秒时间戳
  final Map<String, int> _sendAcked = {}; // 发送侧: 对方已确认收到的字节数
  // 背压等待 (列表: 并行车道时多个 worker 同时等窗口回执)
  final Map<String, List<Completer<void>>> _sendWaiters = {};
  final Set<String> _canceled = {}; // 已取消的 transferId (发送循环据此退出)
  final Set<String> _aborted = {}; // 对端掉线中止的 transferId
  final Set<String> _unverified = {}; // 已发完但尚未收到接收端校验结果的 transferId
  // ---- v2 传输协商 (对端同样支持时启用, 旧版对端自动回落) ----
  final Set<String> _offerV2 = {}; // 接收侧: 带 v2 标志的 file_offer
  final Map<String, bool> _acceptPar = {}; // 发送侧: file_accept 声明可并行
  final Set<String> _parMode = {}; // 接收侧: 该传输走 40 字节头 (36 tid + 4 片号)
  final Map<String, Map<int, IOSink>> _parSinks = {}; // 并行接收: 片号 -> sink
  // 并行接收: 片号 -> 已收字节数 (车道断线重发时回退 bytesDone 用)
  final Map<String, Map<int, int>> _parRecvBytes = {};
  // 并行发送: 车道断线交回的半片, 重派时需先发 file_seg_reset 让接收端清空该片
  // (已送入死车道的字节是否到达不可知, 从中间偏移续发必造成空洞/重复)
  final Set<String> _parSegReset = {}; // '$tid:$seg'
  final Map<String, Map<int, String>> _segHashes = {}; // 分片 SHA-256 (.seghash 边车)
  final Map<String, String> _instantPending = {}; // 秒传等待中: tid -> 候选文件路径
  final Map<String, Timer> _instantTimers = {}; // 秒传兜底计时 (终结时取消, 不白活 600s)

  /// 清理秒传等待状态 (pending + 兜底计时器)
  void _clearInstant(String tid) {
    _instantPending.remove(tid);
    _instantTimers.remove(tid)?.cancel();
  }
  final Map<String, Timer> _offerTimers = {}; // 外发 offer 的等待超时 (可续期)
  int _lastNotifyBytes = 0;
  int _lastNotifyTs = 0; // 上次进度通知时间 (高速传输时按 200ms 节流)

  // ---- 失败自动重试 (指数退避, 最多 3 次; 用户取消/拒绝不触发) ----
  final Map<String, int> _retryAttempts = {}; // transferId -> 已自动重试次数
  final Map<String, int> _retrySchedules = {}; // transferId -> 已排期次数 (含对端不在线的空转)
  final Map<String, Timer> _retryTimers = {};
  static const _maxAutoRetries = 3;
  static const _maxRetrySchedules = 6;

  /// 网络类失败兜底重试: 2s/4s/8s 退避; 触发时对端不在线则重新排期
  /// (空转最多 6 次, 防对端长期离线时无限挂定时器)
  void _autoRetry(FileTransfer t) {
    if (t.status != TransferStatus.failed) return;
    if ((_retryAttempts[t.transferId] ?? 0) >= _maxAutoRetries) {
      // 3 次自动重试都失败: 不再闷头循环, 交给用户决定要不要继续
      // (剪贴板/预览等静默传输不打扰; 用户拒绝后保持失败, 仍可手动续传)
      if (transfers.contains(t) && !t.ephemeral) {
        Log.w('transfer', 'auto-retry exhausted ${t.fileName}, ask user');
        _retryAskCtrl.add(t);
      }
      return;
    }
    final sched = (_retrySchedules[t.transferId] ?? 0) + 1;
    if (sched > _maxRetrySchedules) return;
    _retrySchedules[t.transferId] = sched;
    _retryTimers[t.transferId]?.cancel();
    final n = (_retryAttempts[t.transferId] ?? 0) + 1;
    _retryTimers[t.transferId] = Timer(Duration(seconds: 2 << (n - 1)), () async {
      _retryTimers.remove(t.transferId);
      if (!transfers.contains(t) || t.status != TransferStatus.failed) return;
      if (!isOnline(t.peerId)) {
        _autoRetry(t); // 对端还没回来: 不消耗重试次数, 重新排期等下一轮
        return;
      }
      final attempt = (_retryAttempts[t.transferId] ?? 0) + 1;
      _retryAttempts[t.transferId] = attempt;
      Log.i('transfer', 'auto-retry #$attempt ${t.fileName}');
      if (t.outgoing) {
        await retrySend(t);
      } else {
        await retryReceive(t);
      }
    });
  }

  /// 重试账本清零: 成功/取消/手动重试时调用, 下次失败重新计 3 次
  void _resetRetry(String tid) {
    _retryAttempts.remove(tid);
    _retrySchedules.remove(tid);
    _retryTimers.remove(tid)?.cancel();
  }

  /// 用户在「重试耗尽」弹窗里选了继续: 账本清零重新走自动重试流程,
  /// 再失败 3 次会再次询问 (对端不在线则排期等待, 不消耗次数)
  void retryAgain(FileTransfer t) {
    if (t.status != TransferStatus.failed) return;
    Log.i('transfer', 'user chose retry again ${t.fileName}');
    _resetRetry(t.transferId);
    _autoRetry(t);
  }

  /// 传输进度轻量通知: 进度 tick 走它, 不触发整页重建;
  /// 进度条用 ValueListenableBuilder 订阅, 状态变化仍走 ChangeNotifier
  final ValueNotifier<int> progressTick = ValueNotifier<int>(0);

  /// 轻量进度 tick: 进度条走 ValueListenableBuilder, Android 通知进度也要刷
  void _bumpProgress() {
    progressTick.value++;
    _syncTransferService();
  }

  // ---- 发送队列 (queueSends 开启时, 同一对端串行发送) ----
  final Set<String> _sendingPeers = {}; // 当前有发送任务在跑的对端
  final Map<String, List<String>> _sendQueue = {}; // peerId -> 排队中的 transferId
  final Map<String, int> _queuedOffsets = {}; // 排队中 transferId 的续传偏移

  /// 该传输是否在发送队列中排队 (UI 显示「排队中」用)
  bool isSendQueued(String tid) =>
      _sendQueue.values.any((l) => l.contains(tid));

  Future<void> init() async {
    await Log.init();
    final sp = await SharedPreferences.getInstance();
    deviceId = sp.getString('deviceId') ?? const Uuid().v4();
    await sp.setString('deviceId', deviceId);
    deviceName = sp.getString('deviceName') ?? Platform.localHostname;
    await sp.setString('deviceName', deviceName);
    avatarPath = sp.getString('avatarPath') ?? '';
    serverAddr = sp.getString('serverAddr') ?? '';
    serverKey = sp.getString('serverKey') ?? '';
    await E2ee.setPassword(serverKey);
    p2pEnabled = sp.getBool('p2pEnabled') ?? true;
    connMode = sp.getString('connMode') ?? 'both';
    queueSends = sp.getBool('queueSends') ?? true;
    compressImages = sp.getBool('compressImages') ?? true;
    fsPreviewMaxMb = sp.getInt('fsPreviewMaxMb') ?? 20;
    clipSyncEnabled = sp.getBool('clipSyncEnabled') ?? true;
    clipAutoPaste = sp.getBool('clipAutoPaste') ?? false;
    clipBlockArchives = sp.getBool('clipBlockArchives') ?? true;
    clipBlockImages = sp.getBool('clipBlockImages') ?? true;
    clipBlockVideos = sp.getBool('clipBlockVideos') ?? true;
    clipBlockedExts = sp.getStringList('clipBlockedExts') ?? [];
    trustedPeers = (sp.getStringList('trustedPeers') ?? []).toSet();
    blockedPeers = (sp.getStringList('blockedPeers') ?? []).toSet();
    blockedIps = (sp.getStringList('blockedIps') ?? []).toSet();
    try {
      final raw = sp.getString('blockedPeerNames');
      if (raw != null) {
        blockedPeerNames = Map<String, String>.from(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {}
    try {
      final raw = sp.getString('knownPeers');
      if (raw != null) {
        knownPeers = Map<String, Map<String, dynamic>>.from(
          (jsonDecode(raw) as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
          ),
        );
      }
    } catch (_) {}
    Log.i(
      'app',
      'init: id=$deviceId name=$deviceName mode=$connMode '
          'queue=$queueSends trusted=${trustedPeers.length}',
    );
    _downloadDirOverride = sp.getString('downloadDir');
    darkMode = sp.getBool('darkMode') ?? false;
    // 恢复未读数 (重启不丢角标)
    final unreadRaw = sp.getString('unread');
    if (unreadRaw != null) {
      try {
        (jsonDecode(unreadRaw) as Map<String, dynamic>).forEach((k, v) {
          if (v is int && v > 0) unread[k] = v;
        });
      } catch (_) {}
    }
    TransferForegroundService.init();
    // 手动添加的局域网设备列表 (局域网/混合模式启动时自动重连)
    manualLanTargets = sp.getStringList('manualLanPeers') ?? [];
    // 局域网发现: 广播自身 + 监听同网段设备 (仅中继模式不启动, 但保留空实例)
    if (_lanActive) {
      _startLan();
    } else {
      _lan = _createLan();
    }
    // 通知栏「全部取消」: 取消所有进行中的传输
    TransferForegroundService.onCancelAll = () {
      for (final t
          in transfers
              .where(
                (t) =>
                    t.status == TransferStatus.accepted ||
                    t.status == TransferStatus.transferring,
              )
              .toList()) {
        cancelTransfer(t);
      }
    };
    await _initNotifications();
    _initLifecycle();
    await _restoreLocalData();
    _updateBadge();
    // 接收停滞看门狗: 发送端掉线/崩溃时, 接收端不会永远卡在「传输中」
    Timer.periodic(const Duration(seconds: 10), (_) => _recvWatchdogTick());
    // 剪贴板同步: 2s 轮询 (桌面端没有剪贴板变更事件; Android 仅前台可读,
    // 轮询到系统拒绝会拿到 null, 天然静默)
    Timer.periodic(const Duration(seconds: 2), (_) => _clipTick());
    if (serverAddr.isNotEmpty && _relayActive) connect(serverAddr);
  }

  /// 传输中但超过 45s 没收到任何分块: 判失败 (.part 保留, 可点续传)
  void _recvWatchdogTick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final t in transfers) {
      if (t.outgoing) continue;
      final last = _recvLastTs[t.transferId];
      if (t.status == TransferStatus.transferring) {
        if (last == null || now - last < 45000) continue;
      } else if (t.status == TransferStatus.accepted && t.bytesDone == 0) {
        // accept 后首分块迟迟不来: 对端在线则可能在排队大文件, 只有
        // 对端已离线且超 60s 才判失败, 避免误杀正常排队
        if (last == null || now - last < 60000 || isOnline(t.peerId)) {
          continue;
        }
      } else {
        continue;
      }
      Log.e(
        'transfer',
        'recv stalled ${t.fileName} (${t.bytesDone}/${t.fileSize}B), mark failed',
      );
      t.status = TransferStatus.failed;
      unawaited(_closeIncoming(t.transferId, deletePart: false));
      ChatDb.upsertTransfer(t);
      notifyListeners();
      _autoRetry(t);
    }
  }

  /// 构造局域网管理器 (未启动状态; 仅中继模式下作为空实例占位)
  LanManager _createLan() {
    final lan = LanManager(
      deviceId: deviceId,
      getName: () => deviceName,
      getAvatarB64: _avatarBase64,
    );
    lan.shouldBlockIp = (ip) => blockedIps.contains(ip);
    lan.validateP2pHello = _validateP2pHello;
    return lan;
  }

  /// 启动局域网发现与直连 (both/lan 模式)
  void _startLan() {
    _lan = _createLan();
    _lan.onPeersChanged = () {
      _rebuildPeers();
      _abortTransfersWithOfflinePeers();
      _resendUndelivered();
    };
    _lan.onFrame = _onData; // 直连通道的消息与中继走同一处理
    _lan.onLaneFrame = _onLaneFrame; // 并行车道: 只有 40 字节头的二进制块
    _lan.onLinkClosed = (_) {
      _abortTransfersWithOfflinePeers();
      // 直连断开时可能有消息写进了死连接, 立即重发未送达消息 (走中继/新直连)
      _resendUndelivered();
      notifyListeners();
    };
    unawaited(
      _lan.start().then((_) => Log.i('lan', 'started: $lanStatusText')),
    );
    for (final t in List.of(manualLanTargets)) {
      unawaited(_connectManual(t, persist: false));
    }
  }

  /// 停止局域网发现与直连 (切到仅中继模式时调用)
  Future<void> _stopLan() async {
    final lan = _lan;
    lan.onPeersChanged = null;
    lan.onFrame = null;
    lan.onLaneFrame = null;
    lan.onLinkClosed = null;
    await lan.dispose();
    lan.peers.clear();
    lan.links.clear();
    _lanFailCount.clear();
    _lanFailUntil.clear();
    _lan = _createLan(); // 换上空实例, 避免后续误触已 dispose 的对象
  }

  /// 切换功能模式 (设置页): 按需启动/停止局域网与中继
  Future<void> setConnMode(String mode) async {
    assert(mode == 'both' || mode == 'relay' || mode == 'lan');
    if (mode == connMode) return;
    final wasLan = _lanActive; // 赋值前捕获, 避免 lan→both 重复启动局域网
    connMode = mode;
    (await SharedPreferences.getInstance()).setString('connMode', mode);
    if (_lanActive && !wasLan) {
      _startLan();
    } else if (!_lanActive && wasLan) {
      await _stopLan();
    }
    if (!_relayActive) {
      blockedReason = null; // 仅局域网模式下被踢状态无意义
      disconnect();
    } else if (!connected && serverAddr.isNotEmpty) {
      unawaited(connect(serverAddr));
    }
    _rebuildPeers();
    notifyListeners();
  }

  /// 构造 register 消息 (接入密码非空时携带; 服务器未启用时多余字段被忽略)
  Future<Map<String, dynamic>> _registerMsg() async => {
    'type': 'register',
    'id': deviceId,
    'name': deviceName,
    'avatar': await _avatarBase64(),
    'ver': kProtocolVersion,
    'platform': Platform.operatingSystem,
    if (serverKey.isNotEmpty) 'key': serverKey,
  };

  /// 下拉刷新 (设备页/聊天页): 局域网立即重播宣告 + 补连掉线的手动设备;
  /// 中继重新 register 换取最新在线列表 (服务器覆盖旧条目并广播 peers),
  /// 未连接时下拉等同于手动重连。顺带补发未送达消息。
  Future<void> refreshPeers() async {
    if (_lanActive) {
      unawaited(_lan.announceNow());
      for (final t in List.of(manualLanTargets)) {
        final linked = _lan.peers.entries.any(
          (e) =>
              e.value.manualTarget == t && _lan.links[e.key]?.closed == false,
        );
        if (!linked) unawaited(_connectManual(t, persist: false));
      }
    }
    if (_relayActive) {
      if (connected) {
        _ch?.sink.add(jsonEncode(await _registerMsg()));
      } else if (serverAddr.isNotEmpty) {
        unawaited(connect(serverAddr));
      }
    }
    unawaited(_resendUndelivered());
    // 给 UDP 回应/中继回包留点时间, 也让刷新动画有最低时长
    await Future.delayed(const Duration(milliseconds: 800));
  }

  /// 启动时恢复聊天会话列表和历史传输记录
  Future<void> _restoreLocalData() async {
    try {
      await _purgePreviewCache();
      for (final pid in await ChatDb.conversationPeerIds()) {
        final h = await ChatDb.history(pid, limit: historyPageSize);
        chats[pid] = h;
        hasMoreHistory[pid] = h.length >= historyPageSize;
      }
      transfers.addAll(await ChatDb.loadTransfers());
      for (final t in transfers) {
        _transferIdx[t.transferId] = t;
      }
      // 恢复失败接收传输的已收字节: .part/分片还在就可以断点续传
      for (final t in transfers) {
        if (!t.outgoing &&
            t.status == TransferStatus.failed &&
            t.savePath != null) {
          try {
            final part = File('${t.savePath}.part');
            if (await part.exists()) {
              final len = await part.length();
              if (len > 0 && len <= t.fileSize) t.bytesDone = len;
            } else {
              // 分片模式: 累计各片长度
              var sum = 0;
              for (var i = 0; ; i++) {
                final f = File('${t.savePath}.seg$i');
                if (!await f.exists()) break;
                sum += await f.length();
              }
              if (sum > 0 && sum <= t.fileSize) t.bytesDone = sum;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  final _notifications = FlutterLocalNotificationsPlugin();

  Future<void> _initNotifications() async {
    try {
      await _notifications.initialize(
        settings: const InitializationSettings(
          windows: WindowsInitializationSettings(
            appName: 'cloudSend',
            appUserModelId: 'top.iletter.cloudserver',
            guid: '7f3a9c21-5b8e-4d6a-9f2c-1e8b3a5d7c90',
          ),
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        // 点击通知跳转到对应会话 (payload = 对端 peerId)
        onDidReceiveNotificationResponse: (resp) {
          final p = resp.payload;
          if (p != null && p.isNotEmpty) {
            Log.i('notify', 'notification tapped, open chat $p');
            onNotificationOpenChat?.call(p);
          }
        },
      );
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (e) {
      Log.e('notify', 'init notifications failed', e);
    }
  }

  void _notify(String title, String body, {String? payload}) {
    // Windows 端不弹系统通知 (应用内弹窗 + 未读角标已足够)
    if (Platform.isWindows) return;
    try {
      _notifications.show(
        id: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          windows: const WindowsNotificationDetails(),
          android: AndroidNotificationDetails(
            'chat',
            tr('chat_notif_channel'),
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: payload,
      );
    } catch (_) {}
  }

  Future<void> setAvatar(String path) async {
    // Android 上 FilePicker 选中的图被复制在缓存目录, 清缓存会丢;
    // 复制一份到应用文档目录 (永久存储) 再保存路径
    if (path.isNotEmpty) {
      try {
        final dot = path.lastIndexOf('.');
        final ext = dot > 0 ? path.substring(dot) : '.png';
        final dir = await getApplicationDocumentsDirectory();
        final dest = '${dir.path}${Platform.pathSeparator}avatar$ext';
        final old = avatarPath;
        if (old.isNotEmpty && old != dest) {
          try {
            await File(old).delete();
          } catch (_) {}
        }
        await File(path).copy(dest);
        path = dest;
      } catch (_) {}
    }
    avatarPath = path;
    (await SharedPreferences.getInstance()).setString('avatarPath', path);
    _avatarB64 = null; // 重新压缩
    _ownAvatarBytes = null; // 头像缓存一并失效
    notifyListeners();
    if (connected) {
      disconnect();
      connect(serverAddr);
    }
  }

  String? _avatarB64;

  /// 压缩头像为 96x96 JPEG base64 (用于中继广播/局域网宣告)
  Future<String?> _avatarBase64() async {
    if (avatarPath.isEmpty) return null;
    if (_avatarB64 != null) return _avatarB64;
    _avatarB64 = await compute(_avatarJob, avatarPath);
    return _avatarB64;
  }

  Future<void> setDeviceName(String name) async {
    deviceName = name;
    (await SharedPreferences.getInstance()).setString('deviceName', name);
    notifyListeners();
    if (connected) {
      disconnect();
      connect(serverAddr);
    }
  }

  /// 切换深色模式 (持久化)
  Future<void> setDarkMode(bool v) async {
    darkMode = v;
    (await SharedPreferences.getInstance()).setBool('darkMode', v);
    notifyListeners();
  }

  /// 切换多文件排队发送 (持久化)
  Future<void> setQueueSends(bool v) async {
    queueSends = v;
    (await SharedPreferences.getInstance()).setBool('queueSends', v);
    Log.i('app', 'queueSends -> $v');
    notifyListeners();
  }

  /// 切换发图前压缩 (持久化)
  Future<void> setCompressImages(bool v) async {
    compressImages = v;
    (await SharedPreferences.getInstance()).setBool('compressImages', v);
    Log.i('app', 'compressImages -> $v');
    notifyListeners();
  }

  /// 远程浏览「直接预览」的大小上限 (MB), 超过只能下载; 默认 20MB
  int fsPreviewMaxMb = 20;

  /// 字节数形式 (浏览页判断用)
  int get fsPreviewMax => fsPreviewMaxMb * 1024 * 1024;

  /// 设置远程预览大小上限 (持久化)
  Future<void> setFsPreviewMaxMb(int v) async {
    fsPreviewMaxMb = v;
    (await SharedPreferences.getInstance()).setInt('fsPreviewMaxMb', v);
    Log.i('app', 'fsPreviewMaxMb -> $v');
    notifyListeners();
  }

  /// 切换剪贴板同步总开关 (持久化)
  Future<void> setClipSyncEnabled(bool v) async {
    clipSyncEnabled = v;
    (await SharedPreferences.getInstance()).setBool('clipSyncEnabled', v);
    Log.i('clip', 'clipSyncEnabled -> $v');
    notifyListeners();
  }

  /// 切换收到剪贴板文本自动写入本机剪贴板 (持久化)
  Future<void> setClipAutoPaste(bool v) async {
    clipAutoPaste = v;
    (await SharedPreferences.getInstance()).setBool('clipAutoPaste', v);
    Log.i('clip', 'clipAutoPaste -> $v');
    notifyListeners();
  }

  /// 切换剪贴板上传黑名单项 (持久化); which = archives / images / videos
  Future<void> setClipBlock(String which, bool v) async {
    switch (which) {
      case 'archives':
        clipBlockArchives = v;
      case 'images':
        clipBlockImages = v;
      case 'videos':
        clipBlockVideos = v;
      default:
        return;
    }
    (await SharedPreferences.getInstance()).setBool(
      'clipBlock${which[0].toUpperCase()}${which.substring(1)}',
      v,
    );
    Log.i('clip', 'clipBlock $which -> $v');
    notifyListeners();
  }

  /// 设置自定义拦截扩展名列表 (持久化; 输入自动小写、去点、去重)
  Future<void> setClipBlockedExts(List<String> exts) async {
    clipBlockedExts = exts
        .map((e) => e.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    (await SharedPreferences.getInstance()).setStringList(
      'clipBlockedExts',
      clipBlockedExts,
    );
    Log.i('clip', 'clipBlockedExts -> $clipBlockedExts');
    notifyListeners();
  }

  /// 保存服务器地址但不连接: 地址和密码要分开填,
  /// 只有点「连接」按钮才发起连接 (connect 内部也会再存一次, 幂等)
  Future<void> setServerAddr(String addr) async {
    final a = addr.trim();
    if (a == serverAddr) return;
    serverAddr = a;
    (await SharedPreferences.getInstance()).setString('serverAddr', serverAddr);
    Log.i('app', 'serverAddr -> $serverAddr');
    // 地址变了旧连接已不适用: 断开但不自动连新地址, 等用户点连接
    if (connected) disconnect();
    notifyListeners();
  }

  /// 设置服务器接入密码 (持久化; 不自动重连, 由用户点「连接」生效)
  Future<void> setServerKey(String key) async {
    final k = key.trim();
    if (k == serverKey) return;
    serverKey = k;
    (await SharedPreferences.getInstance()).setString('serverKey', serverKey);
    unawaited(E2ee.setPassword(serverKey)); // E2EE 密钥随接入密码更新
    Log.i('app', 'serverKey updated (len=${serverKey.length})');
    // 密码变了旧会话用的是旧密码: 断开但不自动重连, 等用户点连接
    if (connected) disconnect();
    notifyListeners();
  }

  /// 切换 P2P 打洞直连 (持久化)
  Future<void> setP2pEnabled(bool v) async {
    p2pEnabled = v;
    (await SharedPreferences.getInstance()).setBool('p2pEnabled', v);
    Log.i('app', 'p2pEnabled -> $v');
    notifyListeners();
  }

  bool isTrusted(String peerId) => trustedPeers.contains(peerId);

  /// 信任/取消信任设备: 信任的设备发来的文件自动接受 (持久化)
  Future<void> setTrusted(String peerId, bool v) async {
    if (v) {
      trustedPeers.add(peerId);
      // 信任与拉黑互斥: 拉黑状态下信任无意义 (消息照样被丢弃)
      blockedPeers.remove(peerId);
      blockedPeerNames.remove(peerId);
    } else {
      trustedPeers.remove(peerId);
    }
    final sp = await SharedPreferences.getInstance();
    sp.setStringList('trustedPeers', trustedPeers.toList());
    sp.setStringList('blockedPeers', blockedPeers.toList());
    sp.setString('blockedPeerNames', jsonEncode(blockedPeerNames));
    Log.i('app', 'trusted $peerId -> $v');
    notifyListeners();
  }

  bool isBlocked(String peerId) => blockedPeers.contains(peerId);

  /// 拉黑/解除拉黑设备: 拉黑后其聊天消息静默丢弃 (回 ack 防对方反复重发),
  /// 文件请求自动拒绝, 局域网直连断开并拒绝握手 (持久化)
  Future<void> setBlocked(String peerId, bool v) async {
    if (v) {
      blockedPeers.add(peerId);
      blockedPeerNames[peerId] = peerName(peerId);
      // 拉黑与信任互斥: 信任会绕过确认弹窗, 与拉黑的意图冲突
      trustedPeers.remove(peerId);
      _lan.links[peerId]?.close();
      // 已在等待确认的文件请求直接拒掉, 不再弹窗
      for (final t
          in transfers
              .where(
                (t) =>
                    t.peerId == peerId &&
                    !t.outgoing &&
                    t.status == TransferStatus.waiting,
              )
              .toList()) {
        rejectFile(t);
      }
      // 进行中的入站传输一并取消并清掉半成品:
      // 拉黑后不应再接收该设备的任何数据 (否则其走中继也能把文件写完)
      for (final t
          in transfers
              .where(
                (t) =>
                    t.peerId == peerId &&
                    !t.outgoing &&
                    (t.status == TransferStatus.accepted ||
                        t.status == TransferStatus.transferring),
              )
              .toList()) {
        _canceled.add(t.transferId);
        _closeIncoming(t.transferId, deletePart: true);
        t.status = TransferStatus.canceled;
        ChatDb.upsertTransfer(t);
        _send({
          'type': 'file_cancel',
          'to': peerId,
          'transferId': t.transferId,
        });
        _cleanupTemp(t);
      }
      // 进行中的流式预览一并断掉: 播放侧报错关缓存, 宿主侧关句柄
      for (final s in _streamRecv.values.toList()) {
        if (s.peerId == peerId) _dropStreamRecv(s.tid);
      }
      for (final s in _streamSend.values.toList()) {
        if (s.peerId == peerId) unawaited(_closeStreamSend(s.tid));
      }
    } else {
      blockedPeers.remove(peerId);
      blockedPeerNames.remove(peerId);
    }
    final sp = await SharedPreferences.getInstance();
    sp.setStringList('blockedPeers', blockedPeers.toList());
    sp.setStringList('trustedPeers', trustedPeers.toList());
    sp.setString('blockedPeerNames', jsonEncode(blockedPeerNames));
    Log.i('app', 'blocked $peerId -> $v');
    notifyListeners();
  }

  /// 拉黑/解除拉黑 IP: 仅影响局域网 (断开来自该 IP 的已有连接, 持久化)
  Future<void> setIpBlocked(String ip, bool v) async {
    if (v) {
      blockedIps.add(ip);
      for (final l in _lan.links.values.toList()) {
        if (l.remoteAddr.address == ip) l.close();
      }
    } else {
      blockedIps.remove(ip);
    }
    (await SharedPreferences.getInstance()).setStringList(
      'blockedIps',
      blockedIps.toList(),
    );
    Log.i('app', 'blocked ip $ip -> $v');
    notifyListeners();
  }

  /// 系统通知被点击时的回调 (参数为对端 peerId), 由 UI 层注册用于跳转会话
  void Function(String peerId)? onNotificationOpenChat;

  Future<void> connect(String addr) async {
    if (!_relayActive) return; // 仅局域网模式下不连中继
    serverAddr = addr.trim();
    blockedReason = null; // 手动/自动重连都视作新一轮, 清除被拦标记
    (await SharedPreferences.getInstance()).setString('serverAddr', serverAddr);
    disconnect();
    _manualClose = false;
    final seq = ++_connectSeq;
    final uri = serverAddr.startsWith('ws') ? serverAddr : 'ws://$serverAddr';
    try {
      final ch = WebSocketChannel.connect(Uri.parse(uri));
      await ch.ready; // 等握手完成, 失败抛异常走退避重连
      if (_manualClose || seq != _connectSeq || _ch != null) {
        // 等待握手期间用户点了断开, 或并发的后一次 connect 已接管:
        // 本连接必须关闭, 否则旧 channel 无人持有, 服务器侧残留幽灵注册
        ch.sink.close();
        return;
      }
      _ch = ch;
      _ch!.sink.add(jsonEncode(await _registerMsg()));
      connected = true;
      _retryCount = 0;
      notifyListeners();
      Log.i('relay', 'connected: $uri');
      // 旧连接的残留事件 (被服务器顶替踢下时的 blocked/onDone 等) 不得作用于
      // 新连接, 否则一条迟到的旧流消息会把新连接 disconnect 掉
      _ch!.stream.listen(
        (d) {
          if (identical(_ch, ch)) _onData(d);
        },
        onDone: () {
          if (identical(_ch, ch)) _onLost();
        },
        onError: (_) {
          if (identical(_ch, ch)) _onLost();
        },
      );
    } catch (e) {
      connected = false;
      notifyListeners();
      Log.e('relay', 'connect $uri failed', e);
      if (!_manualClose) _scheduleReconnect();
    }
  }

  void disconnect() {
    _manualClose = true;
    _connectSeq++; // 使等待握手中的 connect 失效
    _reconnectTimer?.cancel();
    _ch?.sink.close();
    _ch = null;
    connected = false;
    _relayPeers = [];
    _relayIds = {};
    _rebuildPeers(); // 局域网设备不受中继断开影响
  }

  /// 被服务器踢下线/拉黑/白名单拦截: 停止自动重连, 等用户手动重连
  void _onBlocked(String reason) {
    blockedReason = reason;
    Log.w('relay', 'blocked by server: $reason');
    _notify(tr('conn_closed'), blockedText(reason));
    disconnect(); // 置 _manualClose, _onLost 不再安排重连
    notifyListeners();
  }

  /// 用户已知晓被拦提示 (保持断开状态; 重连后由 connect 清除)
  void clearBlocked() {
    blockedReason = null;
    notifyListeners();
  }

  void _onLost() {
    connected = false;
    _relayPeers = [];
    _relayIds = {};
    // 中继断开: 进行中的打洞信令已无法送达, 全部作废 (已建立的直连链路不受影响)
    for (final s in _punches.values.toList()) {
      _failPunch(s);
    }
    _rebuildPeers();
    if (!_manualClose) Log.w('relay', 'connection lost');
    // 断线时进行中的传输标记失败 (接收侧保留 .part, 可断点续传);
    // 走局域网直连的传输不受中继掉线影响
    for (final t in transfers) {
      if (_lanActive && _lan.links.containsKey(t.peerId)) continue;
      if (t.status == TransferStatus.transferring ||
          t.status == TransferStatus.accepted) {
        t.status = TransferStatus.failed;
        ChatDb.upsertTransfer(t);
        _autoRetry(t); // 重连后退避重试; 触发时对端仍不在线则放弃
      }
    }
    for (final tid in _incoming.keys.toList()) {
      // 走局域网直连的接收不受中继掉线影响 (与上面状态标记同一判断)
      final t = _find(tid);
      if (t != null && _lanActive && _lan.links.containsKey(t.peerId)) {
        continue;
      }
      _closeIncoming(tid, deletePart: false);
    }
    for (final ws in _sendWaiters.values) {
      for (final w in ws) {
        if (!w.isCompleted) w.complete();
      }
    }
    _sendWaiters.clear();
    notifyListeners();
    if (!_manualClose) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (serverAddr.isEmpty || !_relayActive) return;
    _reconnectTimer?.cancel();
    // 指数退避: 3s → 6s → 12s → 24s → 48s → 60s 封顶
    final secs = (3 << _retryCount).clamp(3, 60);
    if (_retryCount < 5) _retryCount++;
    Log.i('relay', 'reconnect in ${secs}s (retry #$_retryCount)');
    _reconnectTimer = Timer(Duration(seconds: secs), () => connect(serverAddr));
  }

  /// 合并中继在线列表与局域网发现列表 (同一设备两边都在时标记为两者)
  void _rebuildPeers() {
    // 头像变化时让缓存失效 (与旧列表对比)
    final oldAvatar = {for (final p in peers) p.id: p.avatar};
    final oldIds = oldAvatar.keys.toSet();
    final map = <String, Peer>{};
    for (final p in _relayPeers) {
      map[p.id] = Peer(
        id: p.id,
        name: p.name,
        // 本次没拿到头像时沿用历史记录里的 (局域网宣告可能不带头像)
        avatar: p.avatar ?? knownPeers[p.id]?['avatar'] as String?,
        platform: p.platform,
        viaRelay: true,
        ver: p.ver,
      );
    }
    if (_lanActive) {
      for (final e in _lan.peers.entries) {
        final info = e.value;
        final ex = map[e.key];
        map[e.key] = Peer(
          id: info.id,
          name: ex?.name ?? info.name,
          avatar:
              ex?.avatar ??
              info.avatar ??
              knownPeers[e.key]?['avatar'] as String?,
          platform: ex?.platform ?? info.platform,
          viaRelay: ex != null,
          viaLan: true,
          ver: info.ver != 0 ? info.ver : (ex?.ver ?? 0),
        );
      }
    }
    for (final p in map.values) {
      if (oldAvatar[p.id] != p.avatar) _avatarBytesCache.remove(p.id);
    }
    // 登记历史设备: 新上线或资料变化时更新并持久化 (离线后设备页仍可见)
    var knownChanged = false;
    for (final p in map.values) {
      final k = knownPeers[p.id];
      final appeared = !oldIds.contains(p.id);
      // 本次没拿到头像时保留已存的, 不能用 null 覆盖掉好数据
      final avatar = p.avatar ?? k?['avatar'] as String?;
      if (k == null ||
          appeared ||
          k['name'] != p.name ||
          k['avatar'] != avatar ||
          k['platform'] != p.platform) {
        knownPeers[p.id] = {
          'name': p.name,
          'avatar': avatar,
          'platform': p.platform,
          'lastSeen': DateTime.now().millisecondsSinceEpoch,
        };
        knownChanged = true;
      }
    }
    if (knownChanged) {
      unawaited(
        SharedPreferences.getInstance().then(
          (sp) => sp.setString('knownPeers', jsonEncode(knownPeers)),
        ),
      );
    }
    peers = map.values.toList();
    notifyListeners();
  }

  /// 发送控制消息; 满足 E2EE 条件时先加密成 enc 信封再发
  void _send(Map<String, dynamic> msg) {
    final to = msg['to'] as String?;
    if (to != null && _shouldEncrypt(to, msg)) {
      // 发送者身份放进密文: 中继注入的外层 from 可被伪造, 内层 from 有 GCM 认证
      msg['from'] = deviceId;
      unawaited(() async {
        _sendRaw(await E2ee.wrap(msg));
      }());
      return;
    }
    _sendRaw(msg);
  }

  /// E2EE 条件: 已设接入密码 + 对端协议 v3+ (老端不认识 enc 会丢消息)。
  /// p2p_* 信令除外: 服务器要往里注入 fromIp, 且 sid/token/端口不算敏感
  bool _shouldEncrypt(String to, Map<String, dynamic> msg) {
    if (!E2ee.enabled) return false;
    final t = msg['type'] as String?;
    if (t == null || t == 'enc' || t.startsWith('p2p_')) return false;
    // file_accept 必须明文: 中继靠它建立二进制转发路由 (取 transferId)。
    // 一旦加密, 服务器只看到 enc 信封, 路由不建, 后续文件块全部被静默丢弃,
    // 传输卡死在 0 字节直到超时。内容仅 transferId+offset, 不含敏感信息
    if (t == 'file_accept') return false;
    // file_seg_reset 必须明文: 加密是异步的, 会插到重发数据帧之后到达,
    // 接收端先写后删必坏片; 内容仅 transferId+片号, 不含敏感信息
    if (t == 'file_seg_reset') return false;
    for (final p in peers) {
      if (p.id == to) return p.ver >= 3;
    }
    return false; // 对端不在线列表: 无法确认能力, 保持明文
  }

  /// 实际发送控制消息; 对端在局域网内时优先走直连, 连不上回退中继
  /// (拉黑只在消息层拦截, 传输层保持连通, 否则拒收回执在纯局域网场景送不到)
  void _sendRaw(Map<String, dynamic> msg) {
    final to = msg['to'] as String?;
    if (to != null && _lanActive && _lan.peers.containsKey(to)) {
      unawaited(_sendViaLan(to, msg));
      return;
    }
    _ch?.sink.add(jsonEncode(msg));
  }

  Future<void> _sendViaLan(String to, Map<String, dynamic> msg) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 直连连续失败后退避: 60s 内直接走中继 (宣告还在但 TCP 不可达的场景,
    // 如 NAT 后的模拟器, 避免每条消息都白等 3s 连接超时)
    if ((_lanFailUntil[to] ?? 0) < now) {
      final link = await _lan.ensureLink(to);
      if (link != null && !link.closed) {
        _lanFailCount.remove(to);
        link.sendJson(msg);
        return;
      }
      final n = (_lanFailCount[to] ?? 0) + 1;
      if (n >= 2) {
        _lanFailUntil[to] = now + 60000;
        _lanFailCount.remove(to);
      } else {
        _lanFailCount[to] = n;
      }
    }
    _ch?.sink.add(jsonEncode(msg)); // 回退中继
  }

  /// 到该对端的传输通道是否可用 (直连或中继)
  bool _transportUp(String peerId) =>
      (_lanActive && _lan.links[peerId]?.closed == false) ||
      (_relayActive && connected && _relayIds.contains(peerId));

  /// 局域网直连连续失败计数/退避截止
  final Map<String, int> _lanFailCount = {};
  final Map<String, int> _lanFailUntil = {};

  // ---------- P2P 打洞 (经中继信令建立跨网段 TCP 直连) ----------

  /// 进行中的打洞会话: sid -> 会话
  final Map<String, _PunchSession> _punches = {};

  /// 触发对该对端的 P2P 打洞 (大 id 一方发起, 避免双向同时打);
  /// 传输建立时由收发两侧各自调用, 不满足条件时静默跳过
  void maybeP2p(String peerId) {
    if (!p2pEnabled || !_relayActive || !connected) return;
    if (_lan.links[peerId]?.closed == false) return; // 已有直连
    if (!_relayIds.contains(peerId)) return; // 不在中继在线列表
    if (blockedPeers.contains(peerId)) return;
    if (_punches.values.any((s) => s.peerId == peerId)) return; // 打洞进行中
    // 对端协议 v2 起才认识打洞信令 (旧端收到未知类型会忽略, 但别浪费 12s 等待)
    final pv = _relayPeers
        .firstWhere((p) => p.id == peerId, orElse: () => Peer(id: '', name: ''))
        .ver;
    if (pv < 2) return;
    if (deviceId.compareTo(peerId) < 0) return; // 小 id 等对方发起
    if (_lan.boundTcpPort == 0) return; // 本机 TCP 服务没起来, 无法被连
    final sid = const Uuid().v4();
    final token = const Uuid().v4().replaceAll('-', '');
    final s = _PunchSession(sid, peerId, token, initiator: true);
    _punches[sid] = s;
    Log.i('p2p', 'initiate punch to $peerId (sid=${sid.substring(0, 8)})');
    _send({
      'type': 'p2p_request',
      'to': peerId,
      'sid': sid,
      'token': token,
      'port': _lan.boundTcpPort,
    });
    Timer(const Duration(seconds: 12), () => _punchTimeout(s));
  }

  /// 收到打洞请求: 校验后回 accept (附本机监听端口) 并同步开始打洞
  void _onP2pRequest(Map<String, dynamic> m) {
    final from = m['from'] as String?;
    final sid = m['sid'];
    final token = m['token'];
    final port = m['port'];
    final fromIp = m['fromIp'];
    if (from == null ||
        sid is! String ||
        token is! String ||
        port is! int ||
        fromIp is! String) {
      return;
    }
    if (!p2pEnabled ||
        blockedPeers.contains(from) ||
        _lan.links[from]?.closed == false || // 已有直连: 拒绝, 防止新链路顶替
        _lan.boundTcpPort == 0 ||
        port <= 0 ||
        port > 65535) {
      _send({'type': 'p2p_decline', 'to': from, 'sid': sid});
      return;
    }
    var s = _punches[sid];
    if (s == null) {
      s = _PunchSession(sid, from, token, initiator: false)
        ..peerIp = fromIp
        ..peerPort = port;
      _punches[sid] = s;
      Timer(const Duration(seconds: 12), () => _punchTimeout(s!));
    }
    _send({
      'type': 'p2p_accept',
      'to': from,
      'sid': sid,
      'token': token,
      'port': _lan.boundTcpPort,
    });
    unawaited(_punch(s));
  }

  /// 打洞主流程 (对称): 多轮同时对 对端公网IP:port(+0..2) 发起 TCP 连接,
  /// 双方同步外冲在 NAT 上打出洞; 任一连通即收养为直连链路,
  /// 入站方向由 _validateP2pHello 验证凭证后放行
  Future<void> _punch(_PunchSession s) async {
    final ip = s.peerIp;
    final port = s.peerPort;
    if (ip == null || port == null) return;
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) return _failPunch(s);
    try {
      for (var round = 0; round < 3 && !s.done && !s.failed; round++) {
        final socks = await Future.wait([
          for (var d = 0; d < 3; d++) _tryPunchConnect(addr, port + d),
        ]);
        for (final sock in socks) {
          if (sock == null) continue;
          if (s.done || s.failed) {
            sock.destroy(); // 已有赢家, 多余的连接立即释放
            continue;
          }
          s.done = true;
          if (_lan.links[s.peerId]?.closed == false) {
            // 打洞期间已有直连建立 (UDP 发现/对方连入): 放弃打洞链路,
            // 防止 _register 顶替健康链路打断在途传输
            Log.i('p2p', 'discard punched link to ${s.peerId} (link exists)');
            sock.destroy();
            continue;
          }
          Log.i('p2p', 'punched outbound link to ${s.peerId} ($ip:${sock.port})');
          final link = LanLink(sock, inbound: false, peerId: s.peerId)
            ..remotePort = sock.port;
          _lan.adoptP2pLink(link, s.peerId, s.sid, s.token);
        }
        if (s.done) break;
        await Future.delayed(const Duration(milliseconds: 400));
      }
      // 出站没打中时再等入站方向一会儿 (对方可能正在连我们)
      for (var i = 0; i < 10 && !s.done && !s.failed; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      if (s.done) {
        _punches.remove(s.sid);
      } else if (!s.failed) {
        _failPunch(s); // 静默回落中继 (传输本就在走中继)
      }
    }
  }

  /// 单次打洞连接尝试: 2.5s 超时, 失败返回 null
  Future<Socket?> _tryPunchConnect(InternetAddress addr, int port) async {
    try {
      return await Socket.connect(
        addr,
        port,
        timeout: const Duration(milliseconds: 2500),
      );
    } catch (_) {
      return null;
    }
  }

  /// LanManager 回调: 带 p2p 凭证的入站 hello 是否属于进行中的打洞会话
  bool _validateP2pHello(LanLink link, Map<String, dynamic> hello) {
    final sid = hello['p2p'];
    final token = hello['token'];
    final id = hello['id'];
    if (sid is! String || token is! String || id is! String) return false;
    final s = _punches[sid];
    if (s == null || s.token != token || s.peerId != id || s.failed) return false;
    // 已有直连: 不放行打洞链路, 防止顶替健康链路打断在途传输
    if (_lan.links[id]?.closed == false) return false;
    if (!s.done) {
      s.done = true;
      _punches.remove(sid);
      Log.i('p2p', 'punched inbound link from $id (${link.remoteAddr.address})');
    }
    return true;
  }

  void _punchTimeout(_PunchSession s) {
    if (s.done || s.failed) {
      _punches.remove(s.sid);
      return;
    }
    _failPunch(s);
  }

  /// 打洞失败: 通知对方放弃 (仅发起方), 传输继续走中继
  void _failPunch(_PunchSession s) {
    if (s.done || s.failed) {
      _punches.remove(s.sid);
      return;
    }
    s.failed = true;
    _punches.remove(s.sid);
    Log.i('p2p', 'punch to ${s.peerId} failed, stay on relay');
    if (s.initiator && isOnline(s.peerId)) {
      _send({'type': 'p2p_abort', 'to': s.peerId, 'sid': s.sid});
    }
  }

  // ---------- 局域网 ----------

  /// 局域网发现/直连状态文本 (设置页展示)
  String get lanStatusText {
    if (!_lanActive) return tr('lan_st_disabled');
    final udp = _lan.udpBound
        ? 'UDP ${LanManager.udpPort}'
        : tr('lan_udp_fail');
    final tcp = _lan.boundTcpPort != 0
        ? 'TCP ${_lan.boundTcpPort}'
        : tr('lan_tcp_fail');
    return '$udp · $tcp';
  }

  /// 本机所有网卡 (设置页展示 IP 用)
  Future<List<NetworkInterface>> localInterfaces() async {
    try {
      return await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
    } catch (_) {
      return [];
    }
  }

  /// 局域网 TCP 直连端口 (0 = 未绑定); 二维码配对展示用
  int get lanTcpPort => _lan.boundTcpPort;

  /// 本机全部非回环 IPv4 地址 (二维码配对的局域网网段选择用): (地址, 网卡名)
  Future<List<(String, String)>> lanAddrs() async {
    final out = <(String, String)>[];
    for (final i in await localInterfaces()) {
      for (final a in i.addresses) {
        if (!a.isLoopback) out.add((a.address, i.name));
      }
    }
    return out;
  }

  /// 解析 "ip" 或 "ip:port" (端口缺省 45678); 非法输入返回 null
  Future<(InternetAddress, int)?> _parseTarget(String input) async {
    var host = input.trim();
    var port = LanManager.tcpPort;
    final i = host.lastIndexOf(':');
    if (i > 0 && !host.contains(']')) {
      // ipv4:port 形式 (IPv6 需 [addr]:port, 暂不支持)
      final p = int.tryParse(host.substring(i + 1));
      if (p == null || p <= 0 || p > 65535) return null;
      port = p;
      host = host.substring(0, i);
    }
    var addr = InternetAddress.tryParse(host);
    if (addr == null) {
      try {
        final list = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        );
        if (list.isEmpty) return null;
        addr = list.first;
      } catch (_) {
        return null;
      }
    }
    return (addr, port);
  }

  /// 手动添加局域网设备: 输入 "ip" 或 "ip:port", 直连并握手;
  /// 成功返回对端 peerId, 失败返回 null
  Future<String?> addManualLanPeer(String input) async {
    if (!_lanActive) return null; // 仅中继模式下局域网直连已停用
    final parsed = await _parseTarget(input);
    if (parsed == null) return null;
    final (addr, port) = parsed;
    final target = '${addr.address}:$port';
    final peerId = await _lan.connectTo(addr, port, manualTarget: target);
    if (peerId == null) return null;
    if (!manualLanTargets.contains(target)) {
      manualLanTargets.add(target);
      (await SharedPreferences.getInstance()).setStringList(
        'manualLanPeers',
        manualLanTargets,
      );
    }
    notifyListeners();
    return peerId;
  }

  /// 启动时重连已保存的手动设备
  Future<void> _connectManual(String target, {bool persist = true}) async {
    final parsed = await _parseTarget(target);
    if (parsed == null) return;
    final (addr, port) = parsed;
    await _lan.connectTo(addr, port, manualTarget: target);
  }

  /// 删除手动添加的设备; 对应连接断开, 设备从列表移除
  /// (若对方仍能通过广播发现, 几秒内会重新出现)
  Future<void> removeManualLanPeer(String target) async {
    manualLanTargets.remove(target);
    (await SharedPreferences.getInstance()).setStringList(
      'manualLanPeers',
      manualLanTargets,
    );
    String? removeId;
    for (final e in _lan.peers.entries) {
      if (e.value.manualTarget == target) removeId = e.key;
    }
    if (removeId != null) {
      _lan.peers.remove(removeId);
      _lan.links.remove(removeId)?.close();
      _rebuildPeers();
    }
    notifyListeners();
  }

  void _onData(dynamic data) {
    // 畸形消息不影响连接 (中继流上抛异常会触发 onError 误重连)
    try {
      _handleData(data);
    } catch (e) {
      Log.e('proto', 'handleData error', e);
    }
  }

  /// 并行车道来帧: 车道上只有 40 字节头 (36 tid + 4 片号) 的二进制块,
  /// 标记并行模式后交主通道同一处理 (块落盘/回执/看门狗逻辑一致)
  void _onLaneFrame(LanLink link, dynamic frame) {
    if (frame is! Uint8List || frame.length < 41) return;
    try {
      _parMode.add(utf8.decode(Uint8List.sublistView(frame, 0, 36)));
      _handleData(frame);
    } catch (e) {
      Log.e('proto', 'lane frame error', e);
    }
  }

  /// 解密 E2EE 信封并重新走消息分发; 解密失败 (篡改/密钥不一致) 直接丢弃
  Future<void> _handleEnc(Map<String, dynamic> m) async {
    final outerFrom = m['from'] as String?;
    // 外层 from 由中继注入 (诚实中继下可信): 拉黑设备不浪费解密算力
    if (outerFrom != null && blockedPeers.contains(outerFrom)) {
      Log.i('app', 'dropped enc from blocked $outerFrom');
      return;
    }
    final inner = await E2ee.unwrap(m);
    if (inner == null) {
      Log.w(
        'e2ee',
        'decrypt failed from $outerFrom (${E2ee.enabled ? '密钥不一致或被篡改' : '未设置接入密码'})',
      );
      return;
    }
    // 防冒充: 内层 from 必须与中继注入的外层 from 一致, 否则持密码者可伪造任意设备身份
    if (outerFrom != null && inner['from'] != outerFrom) {
      Log.w('e2ee', 'from mismatch: outer=$outerFrom inner=${inner['from']}');
      return;
    }
    _handleData(jsonEncode(inner));
  }

  void _handleData(dynamic data) {
    if (data is String) {
      final m = jsonDecode(data) as Map<String, dynamic>;
      // E2EE 信封: 先解密再按原始消息分发 (解密是异步的)
      if (m['type'] == 'enc') {
        unawaited(_handleEnc(m));
        return;
      }
      // 拉黑设备的拦截: chat 回拒收通知 (对方气泡显示红色感叹号, 与微信一致),
      // file_offer 直接回拒绝; 其余控制消息 (我方发出的传输回执等) 正常处理
      final from = m['from'] as String?;
      if (from != null && blockedPeers.contains(from)) {
        if (m['type'] == 'chat') {
          _send({'type': 'chat_reject', 'to': from, 'ts': m['ts']});
          Log.i('app', 'dropped chat from blocked $from');
          return;
        }
        if (m['type'] == 'file_offer') {
          _send({
            'type': 'file_reject',
            'to': from,
            'transferId': m['transferId'],
          });
          Log.i('app', 'rejected offer from blocked $from');
          return;
        }
        // 远程文件浏览请求一并丢弃 (不给拉黑设备列目录/发文件/取缩略图)
        if (m['type'] == 'fs_list' ||
            m['type'] == 'fs_get' ||
            m['type'] == 'fs_thumb') {
          Log.i('app', 'dropped ${m['type']} from blocked $from');
          return;
        }
        // 剪贴板同步一并丢弃 (信任校验之外的第二道闸)
        if (m['type'] == 'clip_text') {
          Log.i('app', 'dropped clip_text from blocked $from');
          return;
        }
        // 打洞信令一并丢弃 (不与拉黑设备建立任何直连)
        if (m['type'] is String && (m['type'] as String).startsWith('p2p_')) {
          Log.i('app', 'dropped ${m['type']} from blocked $from');
          return;
        }
      }
      switch (m['type']) {
        case 'blocked':
          _onBlocked(m['reason'] as String? ?? 'kick');
          break;
        case 'p2p_request':
          _onP2pRequest(m);
          return; // 内部信令, 不触发 UI 重建
        case 'p2p_accept':
          // 我方发起的打洞被接受: 记下对端公网地址/端口, 开始外冲
          final ps = _punches[m['sid']];
          if (ps != null && ps.initiator && !ps.done && !ps.failed) {
            final fromIp = m['fromIp'];
            final port = m['port'];
            if (fromIp is String &&
                port is int &&
                m['token'] == ps.token &&
                port > 0 &&
                port <= 65535) {
              ps.peerIp = fromIp;
              ps.peerPort = port;
              unawaited(_punch(ps));
            }
          }
          return;
        case 'p2p_decline':
        case 'p2p_abort':
          final ab = _punches.remove(m['sid']);
          if (ab != null && !ab.done) {
            ab.failed = true;
            Log.i('p2p', 'punch ${m['type']} from ${ab.peerId}');
          }
          return;
        case 'peers':
          _relayPeers = (m['peers'] as List)
              .map((e) => Peer.fromJson(e))
              .where((p) => p.id != deviceId)
              .toList();
          _relayIds = _relayPeers.map((p) => p.id).toSet();
          _rebuildPeers();
          _resendUndelivered();
          _abortTransfersWithOfflinePeers();
          break;
        case 'chat':
          final from = m['from'] as String;
          final ts = m['ts'];
          final text = m['text'];
          if (ts is! int || text is! String) break; // 畸形消息直接丢
          // 回 ack (无论是否重复都回, 让发送方确认送达)
          _send({'type': 'chat_ack', 'to': from, 'ts': ts});
          // 去重: 同一对端同一 ts 的消息只存一次 (对方可能重发)
          final existing = chats[from];
          if (existing != null && existing.any((e) => e.ts == ts)) {
            notifyListeners();
            break;
          }
          final msg = ChatMessage(
            peerId: from,
            fromMe: false,
            text: text,
            ts: ts,
          );
          chats.putIfAbsent(from, () => []).add(msg);
          unawaited(() async {
            // DB 兜底去重: 会话被隐藏过(内存无记录)或分页未加载时,
            // 重发的同 ts 消息已在库里 — 撤掉内存副本, 不再二次入库
            if (await ChatDb.exists(from, ts)) {
              chats[from]?.remove(msg);
              notifyListeners();
              return;
            }
            final id = await ChatDb.insert(msg);
            final withId = ChatMessage(
              id: id,
              peerId: from,
              fromMe: false,
              text: msg.text,
              ts: msg.ts,
            );
            final list = chats[from];
            final i = list?.indexOf(msg) ?? -1;
            if (i >= 0) list![i] = withId;
          }());
          // 仅在前台且正在和对方聊天时: 不计未读也不弹系统通知
          if (!(_appForeground && activePeerId == from)) {
            unread[from] = (unread[from] ?? 0) + 1;
            _unreadChanged();
            _notify(peerName(from), text, payload: from);
          } else {
            // 正在看会话: 立即回已读回执
            _send({'type': 'chat_read', 'to': from, 'ts': ts});
          }
          break;
        case 'chat_ack':
          final from = m['from'] as String;
          final ts = m['ts'] as int;
          ChatDb.markDelivered(from, ts);
          final list = chats[from];
          if (list != null) {
            for (final msg in list) {
              if (msg.fromMe && msg.ts == ts) {
                msg.delivered = true;
                break;
              }
            }
          }
          break;
        case 'chat_reject':
          // 对方拒收 (我方被对方拉黑): 标记消息, 气泡显示红色感叹号, 不再重发
          final from = m['from'] as String;
          final ts = m['ts'] as int;
          ChatDb.markRejected(from, ts);
          final list = chats[from];
          if (list != null) {
            for (final msg in list) {
              if (msg.fromMe && msg.ts == ts) {
                msg.rejected = true;
                break;
              }
            }
          }
          Log.w('app', 'chat rejected by $from (blocked by peer)');
          break;
        case 'chat_recall':
          // 对方撤回消息: 本地标记 recalled, 气泡换占位文案
          final from = m['from'] as String;
          final ts = m['ts'];
          if (ts is! int) break;
          ChatDb.markRecalled(from, ts);
          final list = chats[from];
          if (list != null) {
            for (final msg in list) {
              if (!msg.fromMe && msg.ts == ts) {
                msg.recalled = true;
                break;
              }
            }
          }
          notifyListeners();
          break;
        case 'chat_read':
          // 已读回执: 对方读到了 readTs, 把我方该会话 ts<=readTs 的消息标记已读
          final from = m['from'] as String;
          final readTs = m['ts'];
          if (readTs is! int) break;
          ChatDb.markReadUpTo(from, readTs);
          final list = chats[from];
          if (list != null) {
            for (final msg in list) {
              if (msg.fromMe && msg.ts <= readTs && !msg.read) {
                msg.read = true;
              }
            }
          }
          notifyListeners();
          break;
        case 'clip_text':
          // 剪贴板文本同步 (仅信任设备生效, 详见 _handleClipText)
          unawaited(_handleClipText(m));
          break;
        case 'file_offer':
          final tidRaw = m['transferId'];
          if (tidRaw is! String || tidRaw.isEmpty) break;
          final tid = tidRaw;
          if (m['v2'] == true) _offerV2.add(tid);
          final existing = _find(tid);
          if (existing != null) {
            // 同 transferId 重发 (对方点了"重发"): 复用记录以保留 .part 续传进度;
            // rejected = 我方之前拒收过, 对方重发要重新弹确认框
            if (!existing.outgoing &&
                (existing.status == TransferStatus.failed ||
                    existing.status == TransferStatus.canceled ||
                    existing.status == TransferStatus.rejected)) {
              existing.status = TransferStatus.waiting;
              ChatDb.upsertTransfer(existing);
              if (isTrusted(existing.peerId)) {
                // 信任设备: 自动续传, 不再询问
                Log.i(
                  'transfer',
                  'auto-resume ${existing.fileName} from trusted ${existing.peerId}',
                );
                unawaited(_autoAccept(existing));
              } else {
                _fileOfferCtrl.add(existing);
                if (!(_appForeground && activePeerId == existing.peerId)) {
                  _notify(
                    peerName(existing.peerId),
                    trf('notif_offer_file', {'name': existing.fileName}),
                    payload: existing.peerId,
                  );
                }
              }
            }
            break;
          }
          final nameRaw = m['name'];
          final sizeRaw = m['size'];
          if (nameRaw is! String ||
              nameRaw.isEmpty ||
              sizeRaw is! int ||
              sizeRaw <= 0) {
            // 畸形请求: 回拒绝, 别让对方挂满 60s 超时
            _send({'type': 'file_reject', 'to': m['from'], 'transferId': tid});
            break;
          }
          final t = FileTransfer(
            transferId: tid,
            peerId: m['from'],
            // 文件名必须清洗: 对端可发 ../../ 把文件写出下载目录
            fileName: _safeFileName(nameRaw),
            fileSize: sizeRaw,
            outgoing: false,
          );
          // 流式预览应答 (fs_stream_open 的回包): 只认登记过的打开请求,
          // 否则拒绝 — 未登记的 stream offer 是恶意对端诱骗本机开 HTTP 映射
          if (m['stream'] == true) {
            final r = _streamOpens.remove('${t.peerId}|${t.fileName}');
            if (r == null || r.$1.isCompleted) {
              _send({
                'type': 'file_reject',
                'to': m['from'],
                'transferId': tid,
              });
              break;
            }
            unawaited(_acceptStream(t, r.$1, r.$2));
            break;
          }
          // 剪贴板同步文件: 仅信任设备; 存剪贴板目录、自动接收、
          // 不弹窗不入传输记录 (完成后写 clip_items, 见 _finishIncoming);
          // 非信任设备伪造的 clip 标志直接无视, 回落到普通弹窗流程
          if (m['clip'] == true && clipSyncEnabled && isTrusted(t.peerId)) {
            t.ephemeral = true;
            t.clipboard = true;
            _addTransfer(t);
            ChatDb.upsertTransfer(t);
            Log.i(
              'clip',
              'auto-accept clipboard file ${t.fileName} from ${t.peerId}',
            );
            unawaited(_autoAccept(t));
            break;
          }
          // 远程浏览页「预览」拉取的小文件: 临时传输 (存缓存、不入库不上 UI),
          // 自动接收, 页面等它完成直接预览, 不弹确认框也不发通知
          final pulled = _consumeFsPull(t.peerId, t.fileName, t.fileSize);
          t.ephemeral = pulled;
          _addTransfer(t);
          ChatDb.upsertTransfer(t);
          if (pulled) {
            Log.i('fs', 'auto-accept pulled ${t.fileName} from ${t.peerId}');
            unawaited(_autoAccept(t));
            break;
          }
          // 保证会话出现在消息列表 (纯文件会话没有文字消息)
          chats.putIfAbsent(t.peerId, () => []);
          if (isTrusted(t.peerId)) {
            // 信任设备: 自动接受 (断点续传逻辑在 acceptFile 内)
            Log.i(
              'transfer',
              'auto-accept ${t.fileName} from trusted ${t.peerId}',
            );
            unawaited(_autoAccept(t));
            if (!(_appForeground && activePeerId == t.peerId)) {
              unread[t.peerId] = (unread[t.peerId] ?? 0) + 1;
              _unreadChanged();
              _notify(
                peerName(t.peerId),
                trf('notif_auto_accept', {'name': t.fileName}),
                payload: t.peerId,
              );
            }
            break;
          }
          _fileOfferCtrl.add(t); // 触发全局接收弹窗
          // 与聊天消息一致: 前台且正在和对方聊天时不计未读不弹系统通知
          if (!(_appForeground && activePeerId == t.peerId)) {
            unread[t.peerId] = (unread[t.peerId] ?? 0) + 1;
            _unreadChanged();
            _notify(
              peerName(t.peerId),
              trf('notif_offer_file', {'name': t.fileName}),
              payload: t.peerId,
            );
          }
          break;
        case 'file_accept':
          final t = _find(m['transferId']);
          if (t != null && t.outgoing) {
            // 对方接受 (可能带 offset 续传偏移); 失败/取消后的重试也走这里
            if (t.status == TransferStatus.waiting ||
                t.status == TransferStatus.failed ||
                t.status == TransferStatus.canceled) {
              _offerTimers.remove(t.transferId)?.cancel();
              if (m['v2'] == true && m['parallel'] == true) {
                _acceptPar[t.transferId] = true; // _startSend 读取后移除
              }
              var offset = m['offset'] as int? ?? 0;
              if (offset < 0 || offset > t.fileSize) offset = 0;
              t.status = TransferStatus.accepted;
              ChatDb.upsertTransfer(t);
              maybeP2p(t.peerId); // 传输将走中继时尝试升级为 P2P 直连
              if (queueSends && _sendingPeers.contains(t.peerId)) {
                // 同一对端已有发送任务: 排队, 当前任务完成后自动开始
                (_sendQueue[t.peerId] ??= []).add(t.transferId);
                _queuedOffsets[t.transferId] = offset;
                Log.i(
                  'transfer',
                  'queued ${t.fileName} (send to ${t.peerId} busy)',
                );
              } else {
                _sendingPeers.add(t.peerId);
                unawaited(_startSend(t, offset));
              }
            }
          }
          break;
        case 'file_reject':
          // 流式 offer 被拒 (对端没有对应打开登记): 宿主侧会话清理
          unawaited(_closeStreamSend(m['transferId'] as String? ?? ''));
          final t = _find(m['transferId']);
          if (t != null) {
            _offerTimers.remove(t.transferId)?.cancel();
            t.status = TransferStatus.rejected;
            ChatDb.upsertTransfer(t);
            _cleanupTemp(t);
          }
          break;
        case 'fs_list':
          // 对端请求列目录 (远程文件浏览的被浏览方)
          unawaited(_handleFsList(m));
          break;
        case 'fs_list_result':
          // 列目录应答: 唤醒 fsListDir 的等待者
          final w = _fsWaiters.remove(m['req']);
          if (w != null && !w.isCompleted) w.complete(m);
          return; // 浏览页自己等 future, 不用全局重建
        case 'fs_get':
          // 对端请求下载本机文件: 直接走既有 sendFile 回传;
          // preview = 对方只要临时预览 (本端这条外发记录也不入库不上 UI)
          final from = m['from'] as String;
          final path = m['path'];
          // 仅信任设备可拉取本机文件, 防中继上的陌生对端任意读盘
          if (!isTrusted(from)) {
            Log.i('fs', 'fs_get from untrusted $from, rejected');
            break;
          }
          if (path is String && path.isNotEmpty) {
            Log.i('fs', 'fs_get $path from $from');
            unawaited(sendFile(from, path, preview: m['preview'] == true));
          }
          break;
        case 'fs_stream_open':
          // 对端请求流式打开本机文件 (视频边下边播): 仅信任设备可读本机盘
          final from = m['from'] as String;
          final path = m['path'];
          if (!isTrusted(from)) {
            Log.i('fs', 'fs_stream_open from untrusted $from, rejected');
            break;
          }
          if (path is String && path.isNotEmpty) {
            Log.i('fs', 'fs_stream_open $path from $from');
            unawaited(_openStreamSend(from, path));
          }
          break;
        case 'fs_stream_req':
          // 播放端按需拉取字节区间: 急需 (播放点/seek 目标) 插队首,
          // 预读排队尾; 同区间去重 (急需可升级已在队列里的预读)
          final s = _streamSend[m['transferId']];
          final off = m['offset'] as int?;
          final len = m['length'] as int?;
          if (s == null || s.peerId != m['from']) return; // 无会话/冒名
          if (off == null || len == null || off < 0 || len <= 0) return;
          if (off >= s.size) return;
          final entry = (off, min(off + len, s.size) - off);
          s.queue.removeWhere((e) => e.$1 == entry.$1 && e.$2 == entry.$2);
          if (m['pri'] == true) {
            s.queue.insert(0, entry);
          } else {
            s.queue.add(entry);
          }
          unawaited(_pumpStream(s));
          return; // 高频控制消息, 不触发 UI 重建
        case 'fs_stream_skip':
          // 播放端 seek: 丢弃当前队列里完全早于 before 的请求 (省带宽)。
          // 注意只能一次性清队列, 不能记永久抛弃线: 回拖 (向后 seek) 的
          // 新请求也早于 before, 记线会把真实需求当过期请求静默丢掉,
          // 播放端等不到数据超时断流, 播放器按流结束处理 (卡死后直接结束)
          final s = _streamSend[m['transferId']];
          final before = m['before'] as int?;
          if (s != null && s.peerId == m['from'] && before != null) {
            s.queue.removeWhere((e) => e.$1 + e.$2 <= before);
          }
          return;
        case 'fs_stream_close':
          // 双向: 播放端关闭 -> 宿主侧清理; 宿主侧断流 -> 播放侧报错关缓存
          final tid = m['transferId'] as String?;
          if (tid != null && _streamSend.containsKey(tid)) {
            unawaited(_closeStreamSend(tid));
            return;
          }
          if (tid != null) {
            _dropStreamRecv(tid);
            return;
          }
          // open 失败的应答 (无 tid): 唤醒等待中的打开登记
          final name = m['name'] as String?;
          if (name != null) {
            final r = _streamOpens.remove('${m['from']}|$name');
            if (r != null && !r.$1.isCompleted) r.$1.complete(null);
          }
          return;
        case 'fs_thumb':
          // 对端请求本机文件缩略图 (远程文件浏览列表的预览图)
          unawaited(_handleFsThumb(m));
          break;
        case 'fs_thumb_result':
          // 缩略图应答: 唤醒 fsThumb 的等待者
          final w = _fsThumbWaiters.remove(m['req']);
          if (w != null && !w.isCompleted) {
            final data = m['data'];
            w.complete(data is String ? base64Decode(data) : null);
          }
          return; // 浏览页自己等 future, 不用全局重建
        case 'file_progress':
          // 接收端回执: 更新已确认字节数, 唤醒背压等待 (并行时多个 worker)
          final tid = m['transferId'] as String;
          final bytes = m['bytes'] as int? ?? 0;
          if (bytes > (_sendAcked[tid] ?? 0)) _sendAcked[tid] = bytes;
          final ws = _sendWaiters.remove(tid);
          if (ws != null) {
            for (final w in ws) {
              if (!w.isCompleted) w.complete();
            }
          }
          return; // 纯内部账本, 不触发 UI 重建 (每 2MB 一帧, 频率高)
        case 'file_result':
          // 接收端校验结果: 失败则把"发送完成"改判为失败
          final t = _find(m['transferId']);
          _unverified.remove(m['transferId']);
          if (t != null && t.outgoing) {
            final ok = m['ok'] == true;
            if (!ok &&
                (t.status == TransferStatus.done ||
                    t.status == TransferStatus.transferring)) {
              t.status = TransferStatus.failed;
              ChatDb.upsertTransfer(t);
              _autoRetry(t);
            }
          }
          break;
        case 'file_cancel':
          final t = _find(m['transferId']);
          if (t != null) _remoteCancel(t);
          break;
        case 'file_accept_pending':
          // 接收端在做秒传哈希/分片校验等耗时准备: 续期 offer 等待
          final tid = m['transferId'] as String?;
          if (tid != null) _armOfferTimer(tid, 120);
          return; // 不触发 UI 重建
        case 'file_instant':
          // 秒传: 接收端声称已有同名同大小文件; 后台哈希比对后决定免传或回退
          final t = _find(m['transferId']);
          final theirHex = m['sha256'] as String?;
          if (t != null &&
              t.outgoing &&
              t.status == TransferStatus.waiting &&
              t.savePath != null &&
              theirHex != null &&
              theirHex.isNotEmpty) {
            _armOfferTimer(t.transferId, 600); // 本端哈希期间不超时
            unawaited(_handleInstant(t, theirHex));
          }
          break;
        case 'file_instant_nack':
          // 秒传哈希不一致: 回退正常接收流程
          final t = _find(m['transferId']);
          if (t != null &&
              !t.outgoing &&
              _instantPending.containsKey(t.transferId)) {
            _clearInstant(t.transferId);
            Log.i('transfer', 'instant nack ${t.fileName}, fallback to recv');
            unawaited(acceptFile(t));
          }
          break;
        case 'file_parallel':
          // 发送端确认本传输走并行车道: 主链路分块切换为 40 字节头
          final tid = m['transferId'] as String?;
          if (tid != null) _parMode.add(tid);
          return; // 不触发 UI 重建
        case 'file_seg_reset':
          // 并行车道断线: 发送端将从 0 重发该片。回退该片已收计数
          // (防重发字节触发 overflow 误判), 并排进写盘串行链删掉半片:
          // 链上已排队的旧写盘先执行后删除, 之后到达的重发帧重新 append
          final tid = m['transferId'] as String?;
          final seg = m['seg'] as int?;
          final t = tid != null ? _find(tid) : null;
          if (tid != null && seg != null && t != null && !t.outgoing) {
            final got = _parRecvBytes[tid]?[seg] ?? 0;
            if (got > 0) {
              t.bytesDone -= got;
              _parRecvBytes[tid]?[seg] = 0;
            }
            final chain = _recvChain[tid] ?? Future<void>.value();
            _recvChain[tid] = chain.then((_) async {
              try {
                await _parSinks[tid]?.remove(seg)?.close();
                final p = t.savePath;
                if (p != null) {
                  final f = File('$p.seg$seg');
                  if (await f.exists()) await f.delete();
                }
              } catch (_) {}
            });
          }
          return; // 不触发 UI 重建
        case 'file_seg_hash':
          // 发送端报某一片的 SHA-256: 存内存 + 追加 .seghash 边车 (续传校验用)
          final tid = m['transferId'] as String?;
          final seg = m['seg'] as int?;
          final hex = m['sha256'] as String?;
          if (tid != null && seg != null && hex != null && hex.isNotEmpty) {
            (_segHashes[tid] ??= {})[seg] = hex;
            final t = _find(tid);
            if (t?.savePath != null) {
              unawaited(
                File('${t!.savePath}.seghash')
                    .writeAsString(
                      '$seg $hex\n',
                      mode: FileMode.append,
                      flush: true,
                    )
                    .catchError((_) => File('')),
              );
            }
          }
          return; // 不触发 UI 重建
        case 'file_done':
          final t = _find(m['transferId']);
          if (t != null && !t.outgoing) {
            if (m['instant'] == true) {
              // 秒传确认: 本地候选文件哈希与发送端一致, 直接落成
              final p = _instantPending[t.transferId];
              if (p != null) {
                _clearInstant(t.transferId);
                _finishInstant(t, p);
              }
            } else {
              _finishIncoming(t, sha256: m['sha256'] as String?);
            }
          }
          break;
      }
      notifyListeners();
    } else if (data is List<int>) {
      // 二进制文件块; socket/WebSocket 来的本就是 Uint8List, 用视图零拷贝
      // (每块 64~256KB, 高速传输时 fromList 拷贝是 UI isolate 的纯浪费)
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final tid = utf8.decode(Uint8List.sublistView(bytes, 0, 36));
      // 流式预览数据帧: 36 tid + 8 大端偏移 + 负载, 帧自带偏移乱序无害
      final ss = _streamRecv[tid];
      if (ss != null) {
        if (bytes.length < 45) return;
        final off = ByteData.sublistView(bytes, 36, 44).getUint64(0);
        ss.onFrame(off, Uint8List.sublistView(bytes, 44));
        return;
      }
      final t = _find(tid);
      // _recvLastTs 在 accept 时登记: 含 tid 即接收活跃 (sink 懒开, 见下)
      if (t == null || !_recvLastTs.containsKey(tid)) return;
      // 拉黑后在途的分块直接丢弃 (setBlocked 已取消传输并清理现场)
      if (blockedPeers.contains(t.peerId)) return;
      // 并行模式 (file_parallel 协商或车道来帧): 40 字节头 = 36 tid + 4 片号
      // 大端, 按帧自带片号写对应片的独立 sink; 顺序模式为 36 字节头
      int? parSeg;
      Uint8List chunk;
      if (_parMode.contains(tid)) {
        if (bytes.length < 41) return;
        parSeg = ByteData.sublistView(bytes, 36, 40).getUint32(0);
        // 片号越界即异常/恶意对端, 丢弃防写出垃圾 .segN 文件
        if (parSeg * _segSize >= t.fileSize) return;
        chunk = Uint8List.sublistView(bytes, 40);
      } else {
        chunk = Uint8List.sublistView(bytes, 36);
      }
      // 文件写入必须排进串行链: dart:io IOSink 在 flush() 进行中再 add()
      // 会抛 "StreamSink is bound to a stream" (上一版回执前 flush 的修复
      // 正是这样把分块丢出洞 -> 哈希校验必挂)。add 与 flush 同链串行,
      // 两者永不重叠; 链内吞异常 (sink 已关的迟到块) 防止链断。
      // 分片模式按字节位置切块: 跨片边界时先在链内封存当前片、再开下一片。
      // 切分只依赖接收位置, 与发送端块对齐无关 (旧版对端同样兼容)
      var pos = t.bytesDone;
      final segMode = _recvSeg.containsKey(tid);
      if (parSeg != null) {
        // 并行块: 帧自带片号; 每片只由一条车道顺序发送, 按序追加即正确
        final seg = parSeg;
        final piece = chunk;
        pos += piece.length;
        // 每片已收字节记账: file_seg_reset 时据此回退 bytesDone
        final rb = _parRecvBytes[tid] ??= {};
        rb[seg] = (rb[seg] ?? 0) + piece.length;
        final wchain = _recvChain[tid] ?? Future<void>.value();
        _recvChain[tid] = wchain.then((_) async {
          try {
            final sinks = _parSinks[tid] ??= {};
            (sinks[seg] ??= File(
              '${t.savePath}.seg$seg',
            ).openWrite(mode: FileMode.append)).add(piece);
          } catch (_) {}
        });
      } else {
        var rest = chunk;
        while (rest.isNotEmpty) {
          var take = rest.length;
          int? seg;
          if (segMode) {
            seg = pos ~/ _segSize;
            final remain = (seg + 1) * _segSize - pos;
            if (remain < take) take = remain;
          }
          final piece = take == rest.length
              ? rest
              : Uint8List.sublistView(rest, 0, take);
          rest = take == rest.length
              ? Uint8List(0)
              : Uint8List.sublistView(rest, take);
          pos += take;
          final wchain = _recvChain[tid] ?? Future<void>.value();
          _recvChain[tid] = wchain.then((_) async {
            try {
              if (seg != null && _recvSeg[tid] != seg) {
                // 片边界: 封存当前片, 记下新片序号 (sink 懒开)
                await _incoming.remove(tid)?.close();
                _recvSeg[tid] = seg;
              }
              // sink 懒开: accept 时不预开文件 — 并行协商 (file_parallel)
              // 与车道首帧可能先于任何主链路块到达, 预开的顺序 sink 会与
              // 并行片 sink 写同一 .seg0 冲突
              _incoming[tid] ??= File(
                seg != null ? '${t.savePath}.seg$seg' : '${t.savePath}.part',
              ).openWrite(mode: FileMode.append);
              _incoming[tid]?.add(piece);
            } catch (_) {}
          });
        }
      }
      // 不在此逐块算 SHA-256: crypto 是纯 Dart 实现, 大文件高速接收时
      // 会把 UI isolate 跑满 (Android 整机卡死/ANR 的根因), 改为收完后
      // 在后台 isolate 对整个 .part 一次性校验 (见 _finishIncoming)
      t.bytesDone += chunk.length;
      if (t.bytesDone > t.fileSize) {
        // 对端发超了声明大小: 异常/恶意, 掐断防止被写满磁盘
        Log.w('transfer', 'overflow from ${t.peerId}: ${t.bytesDone}/${t.fileSize}');
        unawaited(cancelTransfer(t));
        return;
      }
      _recvLastTs[tid] = DateTime.now().millisecondsSinceEpoch;
      t.sampleSpeed();
      if (t.status == TransferStatus.accepted ||
          t.status == TransferStatus.waiting) {
        t.status = TransferStatus.transferring;
      }
      // 流控回执: 每收 2MB 汇报一次, 发送端据此控制发送窗口
      if (t.bytesDone - (_recvAcked[tid] ?? 0) >= 2 * 1024 * 1024) {
        final acked = t.bytesDone;
        _recvAcked[tid] = acked;
        // 回执排在这 2MB 的写入 + flush 之后发出: 落盘多少才确认多少,
        // 发送端窗口耗尽即停, 接收端内存被窗口大小封顶 (大文件 OOM 的修复)。
        // flush 与上面的 add 同一条链, 时序天然有序
        final prev = _recvChain[tid] ?? Future<void>.value();
        _recvChain[tid] = prev.then((_) async {
          try {
            // 实时查找: 分片换片后 sink 已替换, 不能用它时的旧引用
            await _incoming[tid]?.flush();
            final parSinks = _parSinks[tid];
            if (parSinks != null) {
              for (final s in parSinks.values) {
                await s.flush();
              }
            }
            _send({
              'type': 'file_progress',
              'to': t.peerId,
              'transferId': tid,
              'bytes': acked,
            });
          } catch (_) {
            // 落盘失败/sink 已关: 不回执, 发送端窗口耗尽自会停下 (可断点续传)
          }
        });
      }
      if (t.bytesDone - _lastNotifyBytes >= 256 * 1024 &&
          DateTime.now().millisecondsSinceEpoch - _lastNotifyTs >= 200) {
        // 节流: 进度推进 256KB 且距上次通知 200ms 以上, 避免高速传输时 UI 频繁重建
        // 轻量 tick: 只刷新进度条 (ValueListenableBuilder), 不触发整页重建
        _lastNotifyBytes = t.bytesDone;
        _lastNotifyTs = DateTime.now().millisecondsSinceEpoch;
        _bumpProgress();
      }
    }
  }

  FileTransfer? _find(String tid) => _transferIdx[tid];

  /// 清洗对端发来的文件名: 只保留最后一段并去掉盘符/前导点,
  /// 防止恶意文件名 (../../ 或 ..\\..\\) 把文件写出下载目录
  String _safeFileName(String name) {
    var n = name.replaceAll('\\', '/').split('/').last;
    n = n.replaceAll(':', '').trim();
    while (n.startsWith('.')) {
      n = n.substring(1);
    }
    return n.isEmpty ? 'unnamed' : n;
  }

  /// 对端掉线时中止进行中的传输:
  /// 发送侧唤醒发送循环标记失败 (可重发), 接收侧标记失败并保留 .part (可续传);
  /// 已发完但未收到校验结果的 (小文件) 同样改判失败
  void _abortTransfersWithOfflinePeers() {
    var changed = false;
    for (final t in transfers) {
      if (_transportUp(t.peerId)) continue;
      final busy =
          t.status == TransferStatus.transferring ||
          t.status == TransferStatus.accepted;
      if (busy) {
        if (t.outgoing) {
          // 发送循环检测到 _aborted 后自行退出并标记失败
          _aborted.add(t.transferId);
          final ws = _sendWaiters.remove(t.transferId);
          if (ws != null) {
            for (final w in ws) {
              if (!w.isCompleted) w.complete();
            }
          }
          // 还在队列里未启动的: 发送循环不会跑到, 直接出队标记失败
          if ((_sendQueue[t.peerId] ?? const []).contains(t.transferId)) {
            _sendQueue[t.peerId]!.remove(t.transferId);
            _queuedOffsets.remove(t.transferId);
            _aborted.remove(t.transferId);
            t.status = TransferStatus.failed;
            ChatDb.upsertTransfer(t);
            Log.i('transfer', 'queued ${t.fileName} failed (peer offline)');
            _autoRetry(t); // 对端短时间内回来会自动重发
          }
        } else {
          _closeIncoming(t.transferId, deletePart: false);
          t.status = TransferStatus.failed;
          ChatDb.upsertTransfer(t);
          _autoRetry(t);
        }
        changed = true;
      } else if (t.outgoing &&
          t.status == TransferStatus.done &&
          _unverified.remove(t.transferId)) {
        t.status = TransferStatus.failed;
        ChatDb.upsertTransfer(t);
        changed = true;
      }
    }
    // 流式预览会话: 对端掉线即断流 (播放侧等待者报错, 宿主侧关句柄)
    for (final s in _streamRecv.values.toList()) {
      if (!_transportUp(s.peerId)) _dropStreamRecv(s.tid);
    }
    for (final s in _streamSend.values.toList()) {
      if (!_transportUp(s.peerId)) unawaited(_closeStreamSend(s.tid));
    }
    if (changed) notifyListeners();
  }

  // ---------- 聊天 ----------

  /// 聊天历史每页条数 (聊天页向上翻时分页加载)
  static const int historyPageSize = 50;

  /// 各会话是否还有更早的历史消息可加载
  final Map<String, bool> hasMoreHistory = {};

  Future<List<ChatMessage>> loadHistory(String peerId) async {
    final h = await ChatDb.history(peerId, limit: historyPageSize);
    chats[peerId] = h;
    hasMoreHistory[peerId] = h.length >= historyPageSize;
    markConversationRead(peerId);
    notifyListeners();
    return h;
  }

  /// 会话列表左滑「标记已读」: 只清零未读数 (含角标), 不动消息内容
  void markConversationRead(String peerId) {
    if ((unread[peerId] ?? 0) == 0) return;
    unread[peerId] = 0;
    _unreadChanged();
    notifyListeners();
  }

  /// 抓取更早的一页历史 (只查库不并入列表; 由聊天页在滚动停止后
  /// 调用 applyOlderHistory 拼接, 防止惯性滑动中列表变长导致穿透)
  Future<List<ChatMessage>> fetchOlderHistory(String peerId) async {
    final list = chats[peerId] ?? [];
    if (list.isEmpty) return [];
    final older = await ChatDb.history(
      peerId,
      limit: historyPageSize,
      beforeTs: list.first.ts,
      beforeId: list.first.id,
    );
    if (older.isEmpty) {
      hasMoreHistory[peerId] = false;
      notifyListeners();
    }
    return older;
  }

  /// 把已抓取的更早一页拼接到会话前面 (滚动停止后调用)
  void applyOlderHistory(String peerId, List<ChatMessage> older) {
    if (older.isEmpty) return;
    final list = chats[peerId] ?? [];
    // 防重: 拼接期间可能刚好有新消息进来;
    // 优先按 DB id 判重 (同毫秒多条消息时 ts 判重会误杀)
    final existingIds = list.map((m) => m.id).whereType<int>().toSet();
    final existingTs = list.map((m) => m.ts).toSet();
    final fresh = older
        .where(
          (m) => m.id != null
              ? !existingIds.contains(m.id)
              : !existingTs.contains(m.ts),
        )
        .toList();
    chats[peerId] = [...fresh, ...list];
    hasMoreHistory[peerId] = older.length >= historyPageSize;
    notifyListeners();
  }

  /// 向上翻时加载更早的一页 (立即拼接版, 搜索跳转定位用); 返回加载条数
  Future<int> loadMoreHistory(String peerId) async {
    final older = await fetchOlderHistory(peerId);
    applyOlderHistory(peerId, older);
    return older.length;
  }

  void sendChat(String to, String text) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    var msg = ChatMessage(
      peerId: to,
      fromMe: true,
      text: text,
      ts: ts,
      delivered: false,
    );
    final id = await ChatDb.insert(msg);
    msg = ChatMessage(
      id: id,
      peerId: to,
      fromMe: true,
      text: text,
      ts: ts,
      delivered: false,
    );
    chats.putIfAbsent(to, () => []).add(msg);
    // 仅当对方在线时立即发送; 否则留在本地, 等 peers 刷新时重发
    if (isOnline(to)) {
      _send({'type': 'chat', 'to': to, 'text': text, 'ts': ts});
    }
    notifyListeners();
  }

  /// 重发被对方拒收的消息 (点击气泡旁红色感叹号):
  /// 清除拒收标记回到未送达状态并立即重发; 若对方仍拉黑本机会再次被拒
  void resendChat(String to, ChatMessage msg) {
    msg.rejected = false;
    msg.delivered = false;
    ChatDb.clearRejected(to, msg.ts);
    if (isOnline(to)) {
      _send({'type': 'chat', 'to': to, 'text': msg.text, 'ts': msg.ts});
    }
    notifyListeners();
  }

  /// 重发所有未送达消息 (peers 刷新后调用; 直接查库, 不受分页加载影响)
  Future<void> _resendUndelivered() async {
    for (final pid in chats.keys) {
      if (!isOnline(pid)) continue;
      for (final msg in await ChatDb.undelivered(pid)) {
        _send({'type': 'chat', 'to': pid, 'text': msg.text, 'ts': msg.ts});
      }
    }
  }

  Future<void> deleteMessage(String peerId, ChatMessage m) async {
    if (m.id != null) await ChatDb.delete(m.id!);
    chats[peerId]?.remove(m);
    notifyListeners();
  }

  /// 撤回时限 (微信为 2 分钟): 超时的消息不允许撤回
  static const recallWindowMs = 2 * 60 * 1000;

  bool canRecall(ChatMessage m) =>
      m.fromMe &&
      !m.recalled &&
      DateTime.now().millisecondsSinceEpoch - m.ts <= recallWindowMs;

  /// 撤回一条我方消息: 本地标记 + 通知对端 (对端不在线则只本地生效,
  /// 但撤回通知不走离线补发 — 对方上线后看到的是未撤回状态, 从简)
  Future<bool> recallMessage(String peerId, ChatMessage m) async {
    if (!canRecall(m)) return false;
    m.recalled = true;
    await ChatDb.markRecalled(peerId, m.ts);
    if (isOnline(peerId)) {
      _send({'type': 'chat_recall', 'to': peerId, 'ts': m.ts});
    }
    notifyListeners();
    return true;
  }

  /// 打开会话时回已读回执: 取对方发来的最新一条消息 ts 作为已读位置
  void sendReadReceipt(String peerId) {
    if (!isOnline(peerId)) return;
    final list = chats[peerId];
    if (list == null) return;
    var latest = 0;
    for (final msg in list) {
      if (!msg.fromMe && msg.ts > latest) latest = msg.ts;
    }
    if (latest == 0) return;
    if (_lastReadSent[peerId] == latest) return; // 已读位置没推进, 不重复发
    _lastReadSent[peerId] = latest;
    _send({'type': 'chat_read', 'to': peerId, 'ts': latest});
  }

  final Map<String, int> _lastReadSent = {}; // peerId -> 已回执的最新 ts

  /// 仅从列表移除会话(保留聊天记录,下次启动会恢复)
  void hideConversation(String peerId) {
    chats.remove(peerId);
    unread.remove(peerId);
    _unreadChanged();
    notifyListeners();
  }

  /// 删除整个会话(含聊天记录)
  Future<void> deleteConversation(String peerId) async {
    await ChatDb.deleteConversation(peerId);
    chats.remove(peerId);
    unread.remove(peerId);
    _unreadChanged();
    notifyListeners();
  }

  /// 删除一条传输记录; deleteFile=true 时连同本地文件一起删除
  /// 传输中的记录先取消再删除
  Future<void> deleteTransfer(FileTransfer t, {bool deleteFile = false}) async {
    if (t.status == TransferStatus.accepted ||
        t.status == TransferStatus.transferring) {
      await cancelTransfer(t);
    }
    await ChatDb.deleteTransfer(t.transferId);
    if (t.outgoing && t.status == TransferStatus.waiting) {
      _send({
        'type': 'file_reject',
        'to': t.peerId,
        'transferId': t.transferId,
      });
    }
    if (deleteFile && t.savePath != null) {
      try {
        final f = File(t.savePath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    // 未完成的临时文件始终清掉 (.part 和各分片)
    if (t.savePath != null) {
      try {
        final part = File('${t.savePath}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
      for (var i = 0; ; i++) {
        try {
          final f = File('${t.savePath}.seg$i');
          if (!await f.exists()) break;
          await f.delete();
        } catch (_) {}
      }
      try {
        final sh = File('${t.savePath}.seghash');
        if (await sh.exists()) await sh.delete();
      } catch (_) {}
    }
    _segHashes.remove(t.transferId);
    _offerV2.remove(t.transferId);
    _clearInstant(t.transferId);
    _offerTimers.remove(t.transferId)?.cancel();
    _cleanupTemp(t);
    _removeTransfer(t);
    notifyListeners();
  }

  /// 批量删除传输记录
  Future<void> deleteTransfers(
    List<FileTransfer> list, {
    bool deleteFile = false,
  }) async {
    for (final t in List.of(list)) {
      await deleteTransfer(t, deleteFile: deleteFile);
    }
  }

  /// 传输记录列表的「删除」: 仅对列表隐藏 — 不删本地文件, 不删 DB 记录,
  /// 聊天页的文件消息不受影响 (聊天页自己的删除仍走 deleteTransfer 全删)
  Future<void> hideTransfers(List<FileTransfer> list) async {
    for (final t in list) {
      if (t.hidden) continue;
      t.hidden = true;
      await ChatDb.hideTransfer(t.transferId);
    }
    notifyListeners();
  }

  /// 外发临时文件 (zip 等) 在传输终结后删除; 失败状态保留以便重试
  void _cleanupTemp(FileTransfer t) {
    if (!t.outgoing || t.savePath == null) return;
    if (_tempSendPaths.remove(t.savePath)) {
      File(t.savePath!).delete().catchError((_) => File(''));
    }
  }

  // ---------- 文件 ----------
  String? _downloadDirOverride; // 用户自定义保存目录
  Future<String>? _downloadDirCache; // 缓存: FutureBuilder 每次 build 都调, 避免反复建目录

  Future<String> downloadDir() => _downloadDirCache ??= _resolveDownloadDir();

  Future<String> _resolveDownloadDir() async {
    if (_downloadDirOverride != null && _downloadDirOverride!.isNotEmpty) {
      final dir = Directory(_downloadDirOverride!);
      await dir.create(recursive: true);
      return dir.path;
    }
    Directory base;
    if (Platform.isAndroid) {
      base = Directory('/storage/emulated/0/Download');
    } else {
      base =
          (await getDownloadsDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}cloudSend');
    await dir.create(recursive: true);
    return dir.path;
  }

  /// 设置自定义保存目录; 传 null 恢复默认
  Future<void> setDownloadDir(String? path) async {
    _downloadDirOverride = (path == null || path.isEmpty) ? null : path;
    _downloadDirCache = null; // 路径变了, 缓存作废
    final sp = await SharedPreferences.getInstance();
    if (_downloadDirOverride == null) {
      await sp.remove('downloadDir');
    } else {
      await sp.setString('downloadDir', _downloadDirOverride!);
    }
    notifyListeners();
  }

  /// 缓存目录。Android 上是应用私有 cache/ (系统文件选择器返回 content://
  /// URI, file_picker 会把选中的文件复制到 cache/file_picker, 所以发文件后
  /// 这里会变大); Windows/Linux 上 getTemporaryDirectory 是系统共享临时目录,
  /// 不能整个清, 只统计/清理应用子目录 (桌面端 file_picker 不复制文件)
  Future<Directory> _cacheDir() async {
    final dir = await getTemporaryDirectory();
    if (Platform.isAndroid || Platform.isIOS) return dir;
    return Directory('${dir.path}${Platform.pathSeparator}cloudSend');
  }

  /// 缓存总大小 (字节)
  Future<int> cacheSize() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空缓存内容 (不影响下载目录中已接收的文件)
  Future<void> clearCache() async {
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  /// 预览临时文件的存放目录 (缓存子目录, 重启清空; 与下载目录隔离,
  /// 预览不会在「已接收文件」里留下痕迹)
  Future<Directory> _previewDir() async {
    final dir = Directory(
      '${(await _cacheDir()).path}${Platform.pathSeparator}preview',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 启动时清空上次的预览临时文件 (含没收完的 .part 与流式稀疏缓存)
  Future<void> _purgePreviewCache() async {
    try {
      final dir = Directory(
        '${(await _cacheDir()).path}${Platform.pathSeparator}preview',
      );
      if (await dir.exists()) await dir.delete(recursive: true);
      final sdir = Directory(
        '${(await _cacheDir()).path}${Platform.pathSeparator}streams',
      );
      if (await sdir.exists()) await sdir.delete(recursive: true);
    } catch (_) {}
  }

  /// 发送用的临时文件 (如文件夹 zip 包), 传输终结后自动清理
  final Set<String> _tempSendPaths = {};

  /// 把文件夹打包成 zip (流式写盘, 不占用大内存), 返回 zip 路径 (缓存目录)
  Future<String> zipFolder(String dirPath) async {
    final name = dirPath
        .split(RegExp(r'[\\/]'))
        .where((e) => e.isNotEmpty)
        .last;
    final cache = await _cacheDir();
    await cache.create(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final zipPath = '${cache.path}${Platform.pathSeparator}${name}_$ts.zip';
    await compute(_zipFolderJob, [dirPath, zipPath]);
    return zipPath;
  }

  /// 发送图片: 开启压缩时用 Luban 算法压成 ~1440p JPEG 再发;
  /// 压缩不适用 (gif/解码失败/压完更大) 或未开压缩时直接发原文件
  Future<bool> sendImage(String to, String path) async {
    // gif 不动 (压缩会毁掉动画); 其他解码失败的格式由 lubanCompress 返回 null 兜底
    final isGif = path.toLowerCase().endsWith('.gif');
    if (compressImages && !isGif && isOnline(to)) {
      try {
        final cache = await _cacheDir();
        final outDir = '${cache.path}${Platform.pathSeparator}compressed';
        final r = await lubanCompress(path, outDir);
        if (r != null) {
          Log.i(
            'image',
            'luban ${path.split(RegExp(r'[\\/]')).last}: '
                '${r.origBytes ~/ 1024}KB -> ${r.newBytes ~/ 1024}KB',
          );
          // 压缩产物保留在缓存目录 (聊天气泡缩略图要用), 由「清理缓存」统一清
          final base = path.split(RegExp(r'[\\/]')).last;
          final dot = base.lastIndexOf('.');
          final jpgName = '${dot > 0 ? base.substring(0, dot) : base}.jpg';
          return sendFile(to, r.path, displayName: jpgName);
        }
        Log.i('image', 'luban skipped (not worth it): $path');
      } catch (e) {
        Log.e('image', 'luban compress failed', e);
      }
    }
    return sendFile(to, path);
  }

  /// 发送文件请求; 对方不在线时返回 false, 不创建记录
  /// isTemp: 发送用临时文件, 传输终结后自动删除 (如文件夹 zip)
  /// displayName: 对方看到的文件名 (默认取路径 basename)
  Future<bool> sendFile(
    String to,
    String path, {
    bool isTemp = false,
    String? displayName,
    bool preview = false,
    bool clip = false,
  }) async {
    if (!isOnline(to)) {
      if (isTemp) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      return false;
    }
    final f = File(path);
    final size = await f.length();
    final tid = const Uuid().v4();
    final t = FileTransfer(
      transferId: tid,
      peerId: to,
      fileName: displayName ?? path.split(RegExp(r'[\\/]')).last,
      fileSize: size,
      outgoing: true,
    )..savePath = path;
    // 预览回传 / 剪贴板同步: 本端记录同样不入库不上 UI
    t.ephemeral = preview || clip;
    t.clipboard = clip;
    if (isTemp) _tempSendPaths.add(path);
    _addTransfer(t);
    ChatDb.upsertTransfer(t);
    if (!preview && !clip) {
      // 保证会话出现在消息列表 (纯文件会话没有文字消息)
      chats.putIfAbsent(to, () => []);
    }
    _send({
      'type': 'file_offer',
      'to': to,
      'transferId': tid,
      'name': t.fileName,
      'size': size,
      'v2': true, // 支持分片哈希/秒传/并行; 旧版对端忽略该字段
      if (clip) 'clip': true,
    });
    notifyListeners();
    _armOfferTimer(tid, 60);
    return true;
  }

  /// 外发 offer 的 waiting 超时 (可续期): 对端做秒传哈希/分片校验等
  /// 耗时准备工作时发 file_accept_pending 续期, 避免误判超时
  void _armOfferTimer(String tid, int secs) {
    _offerTimers.remove(tid)?.cancel();
    _offerTimers[tid] = Timer(Duration(seconds: secs), () {
      _offerTimers.remove(tid);
      final t = _find(tid);
      if (t != null &&
          t.status == TransferStatus.waiting &&
          transfers.contains(t)) {
        t.status = TransferStatus.failed;
        ChatDb.upsertTransfer(t);
        notifyListeners();
      }
    });
  }

  // ---------- 剪贴板同步 (信任设备间) ----------

  // 黑名单用的扩展名集合 (与 ui/file_preview_page.dart 的分类保持一致)
  static const _clipArchiveExts = {
    'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso',
  };
  static const _clipImageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
  static const _clipVideoExts = {
    'mp4', 'mkv', 'avi', 'mov', 'flv', 'webm', 'm4v', '3gp',
  };

  /// 文本同步上限: 剪贴板可能粘进整篇日志, 超大文本不值得走消息通道
  static const _clipTextCap = 256 * 1024;

  // 去重游标: 记录「上次已同步」的内容指纹, 轮询读到相同内容不重发
  String? _lastClipText;
  String? _lastClipFilesKey;
  String? _lastClipImageKey;

  /// 回环抑制: 本机主动写入剪贴板的内容 (自动粘贴/列表页点复制),
  /// 轮询读到时消费一次并视为已同步, 防止 A→B→A 回声
  final Set<String> _clipSuppress = {};

  /// 剪贴板记录变更事件 (本地同步/收到对端/收妥文件时触发);
  /// 独立流是为了让剪贴板页避开 ChangeNotifier 的高频进度通知
  final StreamController<void> _clipChangeCtrl =
      StreamController<void>.broadcast();
  Stream<void> get clipChanges => _clipChangeCtrl.stream;
  void _clipChanged() {
    if (!_clipChangeCtrl.isClosed) _clipChangeCtrl.add(null);
  }

  /// 轮询入口: 总开关 + 有可送达的信任设备才扫描
  bool _clipScanBusy = false; // 慢扫描 (大文件 stat) 时防止下一轮重入双发
  void _clipTick() {
    if (!clipSyncEnabled) return;
    // Android 后台读剪贴板被系统拒绝 (返回 null), 这里直接跳过省一轮调用
    if (Platform.isAndroid && !_appForeground) return;
    if (_clipScanBusy) return;
    final targets = peers
        .where((p) => trustedPeers.contains(p.id))
        .toList(growable: false);
    if (targets.isEmpty) return;
    _clipScanBusy = true;
    unawaited(
      _clipScan(targets).whenComplete(() => _clipScanBusy = false),
    );
  }

  /// 扫描一次剪贴板: 文件 > 图片 > 文本 (复制文件时三者可能同时有值,
  /// 只取最高优先级的一类; 内容指纹不变则什么都不做)
  Future<void> _clipScan(List<Peer> targets) async {
    try {
      // 1) 文件 (桌面端复制文件; Android 拿到的是 content:// URI, 读不了直接跳过)
      final rawFiles = await Pasteboard.files();
      final files = <String>[];
      for (final path in rawFiles) {
        if (path.startsWith('content://')) continue;
        final f = File(path);
        if (await f.exists() &&
            (await f.stat()).type == FileSystemEntityType.file) {
          files.add(path);
        }
      }
      if (files.isNotEmpty) {
        final parts = <String>[];
        for (final path in files) {
          final st = await File(path).stat();
          parts.add('$path|${st.size}|${st.modified.millisecondsSinceEpoch}');
        }
        parts.sort();
        final key = parts.join('\n');
        if (_consumeClipSuppress(key)) {
          _lastClipFilesKey = key;
          return;
        }
        if (key != _lastClipFilesKey) {
          _markClipSynced(files: key);
          for (final path in files) {
            if (_clipExtBlocked(path)) {
              Log.i('clip', 'skip blocked ext: $path');
              continue;
            }
            final ts = DateTime.now().millisecondsSinceEpoch;
            await ChatDb.insertClip(
              ClipItem(
                kind: 'file',
                content: path,
                ts: ts,
                fromMe: true,
                peerId: deviceId,
              ),
            );
            for (final t in targets) {
              unawaited(sendFile(t.id, path, clip: true));
            }
          }
          _clipChanged();
        }
        return;
      }
      // 2) 图片 (截图/相册复制; pasteboard 统一给 PNG 字节)
      final bytes = await Pasteboard.image;
      if (bytes != null && bytes.isNotEmpty) {
        final key = await compute(sha256HexOfBytes, bytes);
        if (_consumeClipSuppress(key)) {
          _lastClipImageKey = key;
          return;
        }
        if (key != _lastClipImageKey) {
          _markClipSynced(image: key);
          if (clipBlockImages) {
            Log.i('clip', 'skip blocked image (${bytes.length}B)');
            return;
          }
          // 落到剪贴板目录再发: 本地记录指向的文件在列表页可回开
          final name = 'clip_${DateTime.now().millisecondsSinceEpoch}.png';
          final path =
              '${await clipboardDir()}${Platform.pathSeparator}$name';
          await File(path).writeAsBytes(bytes, flush: true);
          await ChatDb.insertClip(
            ClipItem(
              kind: 'file',
              content: path,
              ts: DateTime.now().millisecondsSinceEpoch,
              fromMe: true,
              peerId: deviceId,
            ),
          );
          for (final t in targets) {
            unawaited(sendFile(t.id, path, displayName: name, clip: true));
          }
          _clipChanged();
        }
        return;
      }
      // 3) 文本
      final text = await Pasteboard.text;
      if (text == null || text.isEmpty) return;
      if (_consumeClipSuppress(text)) {
        _lastClipText = text;
        return;
      }
      if (text == _lastClipText) return;
      _markClipSynced(text: text);
      if (text.length > _clipTextCap) {
        Log.w('clip', 'text too long (${text.length}), skip');
        return;
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      await ChatDb.insertClip(
        ClipItem(
          kind: 'text',
          content: text,
          ts: ts,
          fromMe: true,
          peerId: deviceId,
        ),
      );
      for (final t in targets) {
        _send({'type': 'clip_text', 'to': t.id, 'text': text, 'ts': ts});
      }
      _clipChanged();
    } catch (e) {
      Log.e('clip', 'scan failed', e);
    }
  }

  /// 记录本次已同步的指纹; 三类互斥, 同步一类就清掉另两类的游标
  /// (复制文件后再复制文本, 指纹比较才不会被旧游标挡住)
  void _markClipSynced({String? text, String? files, String? image}) {
    _lastClipText = text;
    _lastClipFilesKey = files;
    _lastClipImageKey = image;
  }

  /// 消费一次回环抑制标记; 集合有界 (>32 直接清空防泄漏)
  bool _consumeClipSuppress(String value) {
    if (_clipSuppress.length > 32) _clipSuppress.clear();
    return _clipSuppress.remove(value);
  }

  /// 本机把文本写入剪贴板 (自动粘贴 / 剪贴板页点复制): 登记抑制后写入,
  /// 轮询 2s 内读到该内容不会回传给对方
  void writeClipText(String text) {
    _clipSuppress.add(text);
    Pasteboard.writeText(text);
  }

  /// 扩展名是否命中上传黑名单
  bool _clipExtBlocked(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0) return false;
    final ext = name.substring(i + 1).toLowerCase();
    if (clipBlockedExts.contains(ext)) return true;
    if (clipBlockArchives && _clipArchiveExts.contains(ext)) return true;
    if (clipBlockImages && _clipImageExts.contains(ext)) return true;
    if (clipBlockVideos && _clipVideoExts.contains(ext)) return true;
    return false;
  }

  /// 剪贴板同步文件的保存目录: 下载目录/cloudSend/clipboard
  /// (downloadDir 本身已是 Download/cloudSend 或用户自定义目录)
  Future<String> clipboardDir() async {
    final dir = Directory(
      '${await downloadDir()}${Platform.pathSeparator}clipboard',
    );
    await dir.create(recursive: true);
    return dir.path;
  }

  /// 收到对端剪贴板文本: 仅信任设备; 默认只进列表,
  /// clipAutoPaste 打开时才写入本机剪贴板 (并登记回环抑制)
  Future<void> _handleClipText(Map<String, dynamic> m) async {
    if (!clipSyncEnabled) return;
    final from = m['from'] as String;
    if (!isTrusted(from)) return;
    final text = m['text'];
    if (text is! String || text.isEmpty) return;
    final tsRaw = m['ts'];
    final ts = tsRaw is int
        ? tsRaw
        : DateTime.now().millisecondsSinceEpoch;
    await ChatDb.insertClip(
      ClipItem(kind: 'text', content: text, ts: ts, fromMe: false, peerId: from),
    );
    if (clipAutoPaste) writeClipText(text);
    _clipChanged();
  }

  // ---------- 远程文件浏览 (浏览对方设备目录/下载) ----------

  /// fs_list 的应答等待表: req -> Completer
  final Map<String, Completer<Map<String, dynamic>>> _fsWaiters = {};

  /// 请求列出对端设备的目录; 返回 fs_list_result 消息,
  /// 对端不在线返回 null, 在线但超时返回 {'error': 'timeout'}
  Future<Map<String, dynamic>?> fsListDir(String peerId, String path) async {
    // 注意不能用 _transportUp: 局域网发现的设备平时只有 UDP 宣告,
    // 还没建 TCP 直连, _send 会按需建连; 用 isOnline 判断即可
    if (!isOnline(peerId)) return null;
    final req = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _fsWaiters[req] = completer;
    _send({'type': 'fs_list', 'to': peerId, 'req': req, 'path': path});
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {'error': 'timeout'};
    } finally {
      _fsWaiters.remove(req);
    }
  }

  /// fs_thumb 的应答等待表: req -> Completer
  final Map<String, Completer<Uint8List?>> _fsThumbWaiters = {};

  /// 请求对端生成文件缩略图 (图片缩到 128px JPEG / 视频抽帧 PNG);
  /// maxSide 指定图片最长边 (远程图片预览用, 如 1280 → JPEG q80);
  /// 对端不在线/超时/失败返回 null (调用方回退占位图标)。
  /// 旧版对端不认识 max 字段会忽略 → 回 128px 小图 (能看但糊, 优雅降级)
  Future<Uint8List?> fsThumb(String peerId, String path, {int? maxSide}) async {
    if (!isOnline(peerId)) return null;
    final req = const Uuid().v4();
    final completer = Completer<Uint8List?>();
    _fsThumbWaiters[req] = completer;
    _send({
      'type': 'fs_thumb',
      'to': peerId,
      'req': req,
      'path': path,
      'max': ?maxSide,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      return null;
    } finally {
      _fsThumbWaiters.remove(req);
    }
  }

  /// 被浏览方: 生成缩略图回传 (仅信任设备; 仅图片/视频扩展名)
  Future<void> _handleFsThumb(Map<String, dynamic> m) async {
    final from = m['from'] as String;
    final req = m['req'];
    final path = m['path'];
    if (req is! String || path is! String) return;
    if (!isTrusted(from)) {
      Log.i('fs', 'fs_thumb from untrusted $from, rejected');
      return;
    }
    Log.i('fs', 'fs_thumb $path from $from');
    // 预览大图请求: 最长边上限 (clamp 防异常值; 旧版无此字段 → 128)
    final maxSide = (m['max'] as int?)?.clamp(32, 4096) ?? 128;
    Uint8List? bytes;
    try {
      final dot = path.lastIndexOf('.');
      final ext = dot > 0 ? path.substring(dot + 1).toLowerCase() : '';
      if (_clipImageExts.contains(ext)) {
        bytes = await _imageThumb(path, maxSide);
      } else if (_clipVideoExts.contains(ext)) {
        bytes = await VideoThumbs.get(path);
      }
    } catch (_) {
      bytes = null;
    }
    _send({
      'type': 'fs_thumb_result',
      'to': from,
      'req': req,
      if (bytes != null) 'data': base64Encode(bytes),
    });
  }

  /// 图片缩略图: 解码→等比缩到 maxSide→JPEG; 超过 100MB 放弃 (防解码 OOM)。
  /// 纯 Dart 解码大图要几百毫秒到数秒, 必须放后台 isolate (UI isolate 上
  /// 同步解码是「软件未响应」ANR 的来源之一)
  Future<Uint8List?> _imageThumb(String path, int maxSide) =>
      compute(_imageThumbJob, (path, maxSide));

  /// 我主动从对端拉取并登记自动接收的小文件 (浏览页内直接预览用):
  /// key = 'peerId|name|size', value = 登记毫秒时间戳
  final Map<String, int> _fsPulls = {};

  /// 请求下载对端文件并自动接收 (不弹确认框): 对端回传的 file_offer 与
  /// 登记的 设备+文件名+大小 完全一致才生效, 30 秒过期;
  /// preview = 临时预览传输 (双方都不入库不上 UI, 存缓存目录)
  void fsGetFileAuto(
    String peerId,
    String path, {
    required String name,
    required int size,
  }) {
    if (!isOnline(peerId)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 顺手清扫过期登记: 否则只在匹配成功时才删, 长期累积
    _fsPulls.removeWhere((_, ts) => now - ts >= 30000);
    _fsPulls['$peerId|$name|$size'] = now;
    _send({'type': 'fs_get', 'to': peerId, 'path': path, 'preview': true});
  }

  /// file_offer 到达时匹配并消费拉取登记; 超期的登记视为无效 (转普通弹窗)
  bool _consumeFsPull(String peerId, String name, int size) {
    final ts = _fsPulls.remove('$peerId|$name|$size');
    if (ts == null) return false;
    return DateTime.now().millisecondsSinceEpoch - ts < 30000;
  }

  // ---- 远程视频流式预览 (协议 v5, 见 stream_server.dart) ----

  /// 本地 HTTP 映射服务 (惰性启动, 只绑回环)
  final StreamHttpServer _streamHttp = StreamHttpServer();

  /// 播放侧会话: tid -> 稀疏缓存+调度
  final Map<String, StreamSession> _streamRecv = {};

  /// 宿主侧会话: tid -> 读盘发送状态
  final Map<String, _StreamSendSession> _streamSend = {};

  /// 待应答的流式打开登记: 'peerId|name' -> (等待者, 对端路径) (offer 回包匹配)
  final Map<String, (Completer<StreamSession?>, String)> _streamOpens = {};

  /// 对端协议版本 (0 = 旧版未上报); 按能力启用新协议特性 (如 v5 流式预览)
  int peerVer(String id) {
    for (final p in peers) {
      if (p.id == id) return p.ver;
    }
    return 0;
  }

  /// 请求对端以流式方式打开远程文件 (仅视频): 对端回 file_offer(stream:true)
  /// 后会话建立并带播放 URL; 对端不支持/文件已不存在/超时返回 null
  Future<StreamSession?> fsStreamOpen(String peerId, String path, String name) {
    if (!isOnline(peerId)) return Future.value(null);
    final key = '$peerId|$name';
    final c = Completer<StreamSession?>();
    // 同名旧登记作废 (浏览页保证一次只开一个, 这里兜底)
    final old = _streamOpens.remove(key);
    if (old != null && !old.$1.isCompleted) old.$1.complete(null);
    _streamOpens[key] = (c, path);
    _send({'type': 'fs_stream_open', 'to': peerId, 'path': path});
    Timer(const Duration(seconds: 6), () {
      if (!c.isCompleted) {
        _streamOpens.remove(key);
        c.complete(null);
      }
    });
    return c.future;
  }

  /// 关闭播放侧会话 (播放器退出时调用): 通知对端停拉, 删除稀疏缓存
  Future<void> fsStreamClose(String tid) async {
    final s = _streamRecv.remove(tid);
    _streamHttp.unmount(tid);
    if (s == null) return;
    _send({'type': 'fs_stream_close', 'to': s.peerId, 'transferId': tid});
    await s.close();
  }

  /// 播放侧会话查询 (视频播放页「下载」按钮取对端 id/文件名用)
  StreamSession? streamSession(String tid) => _streamRecv[tid];

  /// 流式预览中点「下载」: 按原路径另起一整文件传输 (免确认拉取存缓存,
  /// 播放页盯到完成后复制到下载目录)。会话不在/对端离线返回 false
  bool fsStreamDownload(String tid) {
    final s = _streamRecv[tid];
    if (s == null || !isOnline(s.peerId)) return false;
    fsGetFileAuto(s.peerId, s.path, name: s.name, size: s.size);
    return true;
  }

  /// 建立播放侧会话: 稀疏缓存 + 本地 HTTP 映射, 明文 accept 让中继建路由
  Future<void> _acceptStream(
    FileTransfer t,
    Completer<StreamSession?> reg,
    String path,
  ) async {
    try {
      final dir = Directory(
        '${(await _cacheDir()).path}${Platform.pathSeparator}streams',
      );
      await dir.create(recursive: true);
      final s = StreamSession(
        tid: t.transferId,
        peerId: t.peerId,
        name: t.fileName,
        path: path,
        size: t.fileSize,
        file: File('${dir.path}${Platform.pathSeparator}${t.transferId}'),
        token: const Uuid().v4().replaceAll('-', ''),
        sendReq: (off, len, pri) => _send({
          'type': 'fs_stream_req',
          'to': t.peerId,
          'transferId': t.transferId,
          'offset': off,
          'length': len,
          'pri': pri,
        }),
        sendSkip: (before) => _send({
          'type': 'fs_stream_skip',
          'to': t.peerId,
          'transferId': t.transferId,
          'before': before,
        }),
      );
      _streamRecv[t.transferId] = s;
      s.url = await _streamHttp.mount(s);
      // accept 必须明文 (中继靠它建二进制路由, 与文件传输同理);
      // offset 字段在流式模式无意义, 数据帧自带偏移
      _sendRaw({
        'type': 'file_accept',
        'to': t.peerId,
        'transferId': t.transferId,
        'offset': 0,
        'stream': true,
      });
      if (!reg.isCompleted) reg.complete(s);
    } catch (_) {
      if (!reg.isCompleted) reg.complete(null);
    }
  }

  /// 宿主侧: 应答流式打开 — 文件在则登记会话并发 stream offer,
  /// 不在则回 close 让对端等待者立刻失败 (不必等 6s 超时)
  Future<void> _openStreamSend(String peerId, String path) async {
    final name = path.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).last;
    try {
      final f = File(path);
      if (!await f.exists()) throw StateError('gone');
      final size = await f.length();
      if (size <= 0) throw StateError('empty');
      final tid = const Uuid().v4();
      _streamSend[tid] = _StreamSendSession(tid, peerId, path, size);
      _send({
        'type': 'file_offer',
        'to': peerId,
        'transferId': tid,
        'name': name,
        'size': size,
        'stream': true,
      });
      Log.i('fs', 'stream offer $path ($size B) -> $peerId');
    } catch (_) {
      _send({
        'type': 'fs_stream_close',
        'to': peerId,
        'path': path,
        'name': name,
      });
    }
  }

  /// 宿主侧: 顺序消费某会话的区间请求队列 (一帧一块, 帧自带偏移)
  Future<void> _pumpStream(_StreamSendSession s) async {
    if (s.pumping) return;
    s.pumping = true;
    final tidBytes = utf8.encode(s.tid);
    try {
      while (_streamSend[s.tid] == s && s.queue.isNotEmpty) {
        var (off, len) = s.queue.removeAt(0);
        s.raf ??= await File(s.path).open();
        while (len > 0) {
          if (_streamSend[s.tid] != s) return;
          final n = len < kStreamBlock ? len : kStreamBlock;
          await s.raf!.setPosition(off);
          final data = await s.raf!.read(n);
          if (data.isEmpty) throw StateError('eof');
          final header = ByteData(8)..setUint64(0, off);
          final b = BytesBuilder(copy: false)
            ..add(tidBytes)
            ..add(header.buffer.asUint8List())
            ..add(data);
          _sendBinaryTo(s.peerId, b.toBytes());
          off += data.length;
          len -= data.length;
        }
      }
    } catch (_) {
      // 文件被移走/读盘失败: 断流, 播放端等待者报错
      _send({'type': 'fs_stream_close', 'to': s.peerId, 'transferId': s.tid});
      unawaited(_closeStreamSend(s.tid));
    } finally {
      s.pumping = false;
    }
  }

  Future<void> _closeStreamSend(String tid) async {
    final s = _streamSend.remove(tid);
    if (s != null) await s.close();
  }

  /// 发二进制帧到指定对端: 优先局域网直连, 不在则中继
  /// (流式帧自带偏移, 通道间乱序无害, 无需像文件传输那样锁定通道)
  void _sendBinaryTo(String peerId, Uint8List frame) {
    if (_lanActive) {
      final link = _lan.links[peerId];
      if (link != null && !link.closed) {
        link.sendBinary(frame);
        return;
      }
    }
    _ch?.sink.add(frame);
  }

  /// 播放侧会话被对端断流 (文件被删/读盘失败): 等待者报错, 关缓存
  void _dropStreamRecv(String tid, {bool error = true}) {
    final s = _streamRecv.remove(tid);
    if (s == null) return;
    _streamHttp.unmount(tid);
    unawaited(s.close(error: error));
  }

  /// 被浏览方: 列出指定目录 (Android 需「所有文件访问」权限),
  /// 目录按名称升序排前, 文件随后; 最多返回 2000 条防超大目录卡消息通道
  Future<void> _handleFsList(Map<String, dynamic> m) async {
    final from = m['from'] as String;
    final req = m['req'];
    final path = m['path'];
    if (req is! String || path is! String) return;
    Log.i('fs', 'fs_list $path from $from');
    Map<String, dynamic> reply = {
      'type': 'fs_list_result',
      'to': from,
      'req': req,
      'path': path,
    };
    // 仅信任设备可浏览本机目录, 防中继上的陌生对端枚举全盘文件
    if (!isTrusted(from)) {
      Log.i('fs', 'fs_list from untrusted $from, rejected');
      reply['error'] = 'not_trusted';
      _send(reply);
      return;
    }
    try {
      // Windows 虚拟根: 列出所有磁盘分区 (C:\ D:\ ...)
      if (Platform.isWindows && (path.isEmpty || path == '/')) {
        final drives = <Map<String, dynamic>>[];
        for (var code = 67; code <= 90; code++) {
          // C..Z
          final letter = String.fromCharCode(code);
          if (Directory('$letter:\\').existsSync()) {
            drives.add({'name': '$letter:', 'dir': true});
          }
        }
        reply['entries'] = drives;
        _send(reply);
        return;
      }
      if (Platform.isAndroid &&
          !await Permission.manageExternalStorage.isGranted) {
        // 没权限: 在本机弹出系统授权页 (对方在浏览, 用户大概率就在设备旁),
        // 同时回 no_permission 让浏览端显示引导文案
        Log.i('fs', 'fs_list without storage perm, requesting...');
        unawaited(Permission.manageExternalStorage.request());
        reply['error'] = 'no_permission';
      } else {
        final dir = Directory(path);
        final dirs = <Map<String, dynamic>>[];
        final files = <Map<String, dynamic>>[];
        var count = 0;
        await for (final e in dir.list(followLinks: false)) {
          if (++count > 2000) break;
          final name = e.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue; // 隐藏文件不列
          try {
            if (e is Directory) {
              dirs.add({'name': name, 'dir': true});
            } else {
              final st = await e.stat();
              if (st.type != FileSystemEntityType.file) continue;
              files.add({
                'name': name,
                'dir': false,
                'size': st.size,
                'mtime': st.modified.millisecondsSinceEpoch,
              });
            }
          } catch (_) {}
        }
        int byName(a, b) => (a['name'] as String).toLowerCase().compareTo(
          (b['name'] as String).toLowerCase(),
        );
        dirs.sort(byName);
        files.sort(byName);
        reply['entries'] = [...dirs, ...files];
      }
    } catch (e) {
      reply['error'] = '$e';
    }
    _send(reply);
  }

  Future<void> _startSend(FileTransfer t, int offset) async {
    final tid = t.transferId;
    _canceled.remove(tid);
    _aborted.remove(tid);
    // retry 复用同 transferId: 清掉上一轮残留的片重置标记,
    // 否则误发 file_seg_reset 把接收端已续传的好片删掉
    _parSegReset.removeWhere((k) => k.startsWith('$tid:'));
    t.status = TransferStatus.transferring;
    t.bytesDone = offset;
    _sendAcked[tid] = offset;
    _lastNotifyBytes = offset;
    notifyListeners();
    // 通道在传输开始时锁定, 全程不切换: 中途打洞成功/新直连建立也不换路,
    // 否则旧路径里排队的中继分块会被新路径的后发分块插队, 接收端乱序写盘,
    // 最后 SHA 校验必然失败 (限速拉长了中继排队, 乱序窗口被放大到必然触发)
    final link = _lanActive && _lan.links[t.peerId]?.closed == false
        ? _lan.links[t.peerId]
        : null;
    LanLink? lane;
    try {
      // 并行车道: LAN 直连 + 分片大文件 + 全新发送 + 对端 accept 声明支持;
      // 车道拨不通自动退化为单链接顺序传输
      if (link != null &&
          offset == 0 &&
          t.fileSize > _segThreshold &&
          _acceptPar.remove(tid) == true) {
        lane = await _lan.dialLane(t.peerId);
        if (lane != null) {
          _send({
            'type': 'file_parallel',
            'to': t.peerId,
            'transferId': tid,
            'lanes': 2,
          });
          Log.i(
            'transfer',
            'parallel send ${t.fileName} -> ${t.peerId} (2 lanes)',
          );
        }
      } else {
        _acceptPar.remove(tid);
      }
      // 分片/并行模式逐片算哈希 (file_seg_hash), file_done 不带总哈希;
      // 小文件照旧总算总哈希带上
      final hex = lane != null
          ? await _sendLanes(t, link!, lane)
          : await _sendSequential(t, link, offset);
      t.status = TransferStatus.done; // 发送完成; 校验失败会被 file_result 改判
      _resetRetry(tid);
      final doneMsg = <String, dynamic>{
        'type': 'file_done',
        'to': t.peerId,
        'transferId': tid,
        if (hex != null) 'sha256': hex,
        'size': t.bytesDone,
      };
      // file_done 必须与分块同路: 中继传的就强制走中继,
      // 否则它经直连插队到达时, 中继管道里还有分块没送完, 接收端误判失败
      if (link != null) {
        _send(doneMsg);
      } else {
        _ch?.sink.add(jsonEncode(doneMsg));
      }
      Log.i('transfer', 'send done ${t.fileName} (${t.bytesDone}B)');
      // 等待接收端校验结果的窗口期: 期间对端掉线要改判失败 (防小文件误判完成)
      _unverified.add(tid);
      Timer(const Duration(seconds: 30), () => _unverified.remove(tid));
      _cleanupTemp(t);
    } catch (e) {
      t.status = _canceled.contains(tid)
          ? TransferStatus.canceled
          : TransferStatus.failed; // 失败可从 bytesDone 续传
      if (t.status == TransferStatus.canceled) {
        Log.i('transfer', 'send canceled ${t.fileName}');
        _cleanupTemp(t);
      } else {
        Log.e('transfer', 'send failed ${t.fileName}', e);
        // 通道还在就通知对端取消, 防接收端永远卡在「传输中」;
        // 通道已断则靠接收端自己的停滞看门狗兜底
        if (_transportUp(t.peerId)) {
          _send({'type': 'file_cancel', 'to': t.peerId, 'transferId': tid});
        }
        _autoRetry(t);
      }
    } finally {
      lane?.close(); // 并行车道随传输终结回收
      _aborted.remove(tid);
      _sendAcked.remove(tid);
      final ws = _sendWaiters.remove(tid);
      if (ws != null) {
        for (final w in ws) {
          if (!w.isCompleted) w.complete();
        }
      }
      _sendingPeers.remove(t.peerId);
      _pumpSendQueue(t.peerId); // 本对端队列里的下一个接着发
    }
    ChatDb.upsertTransfer(t);
    notifyListeners();
  }

  /// 顺序发送主体: 返回 file_done 要带的总哈希; 分片模式逐片哈希
  /// (每发完一片发 file_seg_hash), 总哈希被逐片校验取代, 返回 null。
  /// 哈希在后台 isolate 算: 纯 Dart crypto 在 UI isolate 逐块算是高速
  /// 发送时界面卡的根因; Uint8List 过 SendPort 只是 native memcpy
  Future<String?> _sendSequential(
    FileTransfer t,
    LanLink? link,
    int offset,
  ) async {
    final tid = t.transferId;
    final viaLan = link != null;
    // 通道参数: 局域网直连块大窗口大, 中继保守 (服务器按帧转发有开销)
    // 窗口即内存上限: 发送端原生 socket 缓冲 + 接收端落盘前的在途数据都被它封顶,
    // 128MB 的 LAN 上限在 Android 上足以撑爆内存, 统一压到 32MB
    final chunkSize = viaLan ? 256 * 1024 : 64 * 1024;
    var window = viaLan ? 16 * 1024 * 1024 : 8 * 1024 * 1024;
    const windowCap = 32 * 1024 * 1024;
    final segMode = t.fileSize > _segThreshold;
    var waitMs = 0; // 累计被窗口卡住的时间
    var evalAt = DateTime.now().millisecondsSinceEpoch + 2000; // 下次评估窗口的时间点
    Log.i(
      'transfer',
      'send start ${t.fileName} -> ${t.peerId} '
          '(${viaLan ? "lan" : "relay"}, offset=$offset${segMode ? ", seg" : ""})',
    );
    // 控制消息与分块同路 (见 file_done 处注释)
    void sendCtrl(Map<String, dynamic> msg) {
      if (link != null) {
        _send(msg);
      } else {
        _ch?.sink.add(jsonEncode(msg));
      }
    }

    RandomAccessFile? raf;
    _HashWorker? hash; // 非分片: 总哈希; 分片: 当前片哈希
    var pos = offset;
    var segFed = false; // 当前片 worker 已喂过数据 (空 worker 不发片哈希)
    try {
      hash = await _HashWorker.start();
      raf = await File(t.savePath!).open();
      if (segMode) {
        // 分片续传: 只需把当前半片的已发部分补进片哈希; 之前完整片的
        // 哈希在上个会话已发给对方 (边车仍在), 无需重读重算
        final segStart = (offset ~/ _segSize) * _segSize;
        if (offset > segStart) {
          await for (final chunk in File(
            t.savePath!,
          ).openRead(segStart, offset)) {
            hash.add(chunk);
            segFed = true;
            await hash.credit(); // 背压: 未消化数据不超 32MB
          }
        }
        await raf.setPosition(offset);
      } else if (offset > 0) {
        // 哈希需覆盖整个文件: 先把已发送的部分喂进哈希
        await for (final chunk in File(t.savePath!).openRead(0, offset)) {
          hash.add(chunk);
          await hash.credit();
        }
        await raf.setPosition(offset);
      }
      final tidBytes = ascii.encode(tid);
      // 锁定通道的可用性: 只认开始时的那条路 (新链路建立不算数)
      bool pinnedUp() => link != null ? !link.closed : connected;
      while (true) {
        while (t.bytesDone - (_sendAcked[tid] ?? 0) >= window) {
          // 窗口满: 等接收端 file_progress 回执
          if (_canceled.contains(tid) ||
              _aborted.contains(tid) ||
              !pinnedUp()) {
            throw StateError('aborted');
          }
          final before = _sendAcked[tid] ?? 0;
          final w = Completer<void>();
          (_sendWaiters[tid] ??= []).add(w);
          final waitStart = DateTime.now().millisecondsSinceEpoch;
          try {
            await w.future.timeout(
              const Duration(seconds: 120),
              onTimeout: () {
                if ((_sendAcked[tid] ?? 0) == before) {
                  throw TimeoutException('file_progress timeout');
                }
              },
            );
          } finally {
            final ws = _sendWaiters[tid];
            if (ws != null) {
              ws.remove(w);
              if (ws.isEmpty) _sendWaiters.remove(tid);
            }
          }
          waitMs += DateTime.now().millisecondsSinceEpoch - waitStart;
        }
        if (_canceled.contains(tid) ||
            _aborted.contains(tid) ||
            !pinnedUp()) {
          throw StateError('aborted');
        }
        // 自适应窗口: 若发送端超过 1/3 时间在等回执, 说明窗口是瓶颈, 翻倍扩
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs >= evalAt) {
          if (waitMs * 3 > nowMs - (evalAt - 2000) && window < windowCap) {
            window = window * 2 > windowCap ? windowCap : window * 2;
            Log.i(
              'transfer',
              'window up -> ${window ~/ (1024 * 1024)}MB ($tid)',
            );
          }
          waitMs = 0;
          evalAt = nowMs + 2000;
        }
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        if (segMode) {
          // 按片边界切开喂哈希: 喂满一片即发出其 file_seg_hash 并起新片
          var rest = chunk;
          while (rest.isNotEmpty) {
            final segEnd = (pos ~/ _segSize + 1) * _segSize;
            var take = rest.length;
            if (segEnd - pos < take) take = segEnd - pos;
            final piece = take == rest.length
                ? rest
                : Uint8List.sublistView(rest, 0, take);
            rest = take == rest.length
                ? Uint8List(0)
                : Uint8List.sublistView(rest, take);
            hash!.add(piece);
            segFed = true;
            pos += take;
            if (pos == segEnd) {
              final segHex = await hash.close();
              sendCtrl({
                'type': 'file_seg_hash',
                'to': t.peerId,
                'transferId': tid,
                'seg': segEnd ~/ _segSize - 1,
                'sha256': segHex,
              });
              hash = await _HashWorker.start();
              segFed = false;
            }
          }
          await hash!.credit();
        } else {
          hash!.add(chunk);
          await hash.credit(); // 哈希消化不过来时暂停, 与网络窗口同理
        }
        final b = BytesBuilder()
          ..add(tidBytes)
          ..add(chunk);
        // 走锁定的那条通道 (不用 _sendBinary: 它按当前链路状态动态选路)
        if (link != null) {
          link.sendBinary(b.toBytes());
        } else {
          _ch?.sink.add(b.toBytes());
        }
        t.bytesDone += chunk.length;
        t.sampleSpeed();
        final notifyNow = DateTime.now().millisecondsSinceEpoch;
        if (t.bytesDone - _lastNotifyBytes >= 1024 * 1024 &&
            notifyNow - _lastNotifyTs >= 200) {
          // 轻量 tick: 只刷新进度条, 不触发整页重建
          _lastNotifyBytes = t.bytesDone;
          _lastNotifyTs = notifyNow;
          _bumpProgress();
        }
      }
      if (segMode) {
        // 最后一片 (通常不足 _segSize): 发片哈希; 若恰在片边界收尾,
        // 当前 worker 未喂过数据 (segFed=false), 该片哈希已发过不再重复
        if (segFed) {
          final segHex = await hash!.close();
          hash = null;
          sendCtrl({
            'type': 'file_seg_hash',
            'to': t.peerId,
            'transferId': tid,
            'seg': (pos - 1) ~/ _segSize,
            'sha256': segHex,
          });
        } else {
          hash?.dispose();
          hash = null;
        }
        return null;
      }
      final hex = await hash!.close();
      hash = null;
      return hex;
    } finally {
      hash?.dispose(); // 中止/失败时回收 worker isolate (close 后重复 kill 无害)
      await raf?.close();
    }
  }

  /// 并行发送主体 (LAN 双车道): 主链路 + 一条车道各跑一个 worker, 按片领取
  /// 任务; 帧头 40 字节 (36 tid + 4 片号大端), 每片只由一条车道顺序发送,
  /// 接收端按片号独立 sink 追加即天然有序。车道中断时未发完的半片交回
  /// (进度记在 segProgress), 由还活着的 worker 续发, 不因此整单失败
  Future<String?> _sendLanes(
    FileTransfer t,
    LanLink mainLink,
    LanLink lane,
  ) async {
    final tid = t.transferId;
    final nseg = (t.fileSize + _segSize - 1) ~/ _segSize;
    final segProgress = List<int>.filled(nseg, 0);
    var nextSeg = 0;
    var pendingSeg = -1; // 车道断线交回待重派的半片
    const chunkSize = 256 * 1024;
    const window = 16 * 1024 * 1024; // 两 worker 共享一个窗口
    final tidBytes = ascii.encode(tid);
    var parAborted = false; // 任一 worker 出错: 另一个尽快退出, 不要白发剩余片
    int takeSeg() {
      if (pendingSeg >= 0) {
        final s = pendingSeg;
        pendingSeg = -1;
        return s;
      }
      return nextSeg < nseg ? nextSeg++ : -1;
    }

    Future<void> windowWait() async {
      while (t.bytesDone - (_sendAcked[tid] ?? 0) >= window) {
        if (parAborted ||
            _canceled.contains(tid) ||
            _aborted.contains(tid) ||
            mainLink.closed) {
          throw StateError('aborted');
        }
        final before = _sendAcked[tid] ?? 0;
        final w = Completer<void>();
        (_sendWaiters[tid] ??= []).add(w);
        try {
          await w.future.timeout(
            const Duration(seconds: 120),
            onTimeout: () {
              if ((_sendAcked[tid] ?? 0) == before) {
                throw TimeoutException('file_progress timeout');
              }
            },
          );
        } finally {
          final ws = _sendWaiters[tid];
          if (ws != null) {
            ws.remove(w);
            if (ws.isEmpty) _sendWaiters.remove(tid);
          }
        }
      }
    }

    Future<void> worker(LanLink myLink) async {
      while (true) {
        if (parAborted) return; // 搭档已出错, 整体即将判失败
        if (_canceled.contains(tid) ||
            _aborted.contains(tid) ||
            mainLink.closed) {
          throw StateError('aborted');
        }
        if (myLink.closed) return; // 车道已断: 剩余片让另一条领
        final i = takeSeg();
        if (i < 0) return;
        if (_parSegReset.remove('$tid:$i')) {
          // 该片是死车道交回的半片: 通知接收端清空再重发。
          // 控制消息与重发数据同走幸存主链路 (TCP 保序), 接收端先删后写
          _send({
            'type': 'file_seg_reset',
            'to': t.peerId,
            'transferId': tid,
            'seg': i,
          });
        }
        final segStart = i * _segSize;
        final segLen = (t.fileSize - segStart).clamp(0, _segSize);
        RandomAccessFile? raf;
        _HashWorker? segHash;
        var completed = false;
        try {
          raf = await File(t.savePath!).open();
          await raf.setPosition(segStart + segProgress[i]);
          segHash = await _HashWorker.start();
          // 重派的半片: 已发部分补进片哈希 (从片头重读)
          if (segProgress[i] > 0) {
            await for (final c in File(
              t.savePath!,
            ).openRead(segStart, segStart + segProgress[i])) {
              segHash.add(c);
              await segHash.credit();
            }
          }
          while (segProgress[i] < segLen) {
            await windowWait();
            if (myLink.closed) break; // 车道中途断: 交回半片
            final want = segLen - segProgress[i];
            final chunk = await raf.read(
              want < chunkSize ? want : chunkSize,
            );
            if (chunk.isEmpty) {
              throw StateError('file shrunk during send');
            }
            segHash.add(chunk);
            await segHash.credit();
            final frame = BytesBuilder()
              ..add(tidBytes)
              ..add((ByteData(4)..setUint32(0, i)).buffer.asUint8List())
              ..add(chunk);
            myLink.sendBinary(frame.toBytes());
            segProgress[i] += chunk.length;
            t.bytesDone += chunk.length;
            t.sampleSpeed();
            final notifyNow = DateTime.now().millisecondsSinceEpoch;
            if (t.bytesDone - _lastNotifyBytes >= 1024 * 1024 &&
                notifyNow - _lastNotifyTs >= 200) {
              _lastNotifyBytes = t.bytesDone;
              _lastNotifyTs = notifyNow;
              _bumpProgress();
            }
          }
          completed = segProgress[i] >= segLen;
          if (completed) {
            final hex = await segHash.close();
            segHash = null;
            if (mainLink.closed) throw StateError('aborted');
            // 片哈希走主链路控制帧 (接收端记入 .seghash 边车)
            _send({
              'type': 'file_seg_hash',
              'to': t.peerId,
              'transferId': tid,
              'seg': i,
              'sha256': hex,
            });
          }
        } finally {
          segHash?.dispose();
          await raf?.close();
        }
        if (!completed) {
          // 半片交回重派 (车道断线): 已送入死车道socket缓冲的字节是否
          // 到达对端不可知, 幸存 worker 若从 segProgress 偏移续发, 接收端
          // 纯 append 必产生空洞/重复 (校验失败后整轮白传)。
          // 回退该片进度从 0 重发, 并标记重派时先让接收端清空该片
          if (segProgress[i] > 0) {
            t.bytesDone -= segProgress[i];
            segProgress[i] = 0;
            _parSegReset.add('$tid:$i');
          }
          pendingSeg = i;
          return;
        }
      }
    }

    // 等两个 worker 都退出; 任一出错置 parAborted 让另一个尽快停,
    // Future.wait 收齐后抛第一个异常
    Future<void> guarded(LanLink l) => worker(l).catchError((Object e) {
      parAborted = true;
      throw e;
    });
    await Future.wait([guarded(mainLink), guarded(lane)]);
    if (t.bytesDone < t.fileSize) throw StateError('incomplete send');
    return null; // 并行模式无总哈希 (逐片校验)
  }

  /// 发送队列泵: 当前发送结束后启动该对端队列里的下一个
  void _pumpSendQueue(String peerId) {
    final q = _sendQueue[peerId];
    if (q == null) return;
    while (q.isNotEmpty) {
      final nextId = q.removeAt(0);
      final offset = _queuedOffsets.remove(nextId) ?? 0;
      final next = _find(nextId);
      if (next != null && next.status == TransferStatus.accepted) {
        _sendingPeers.add(peerId);
        Log.i('transfer', 'dequeue ${next.fileName}');
        unawaited(_startSend(next, offset));
        return;
      }
    }
    _sendQueue.remove(peerId);
  }

  /// 信任设备自动接受的包装: 出错只记日志标记失败, 不产生未捕获异步异常
  Future<void> _autoAccept(FileTransfer t) async {
    try {
      await acceptFile(t);
    } catch (e) {
      Log.e('transfer', 'auto-accept ${t.fileName} failed', e);
      t.status = TransferStatus.failed;
      ChatDb.upsertTransfer(t);
      notifyListeners();
    }
  }

  /// 接受文件; 若已有 .part 临时文件则从其长度偏移处续传
  Future<void> acceptFile(FileTransfer t) async {
    // 防重入: 失败重试的 acceptFile 还在 await 大 .part 哈希, 对方重发的
    // file_offer 把状态重置为 waiting 又触发一次接受, 两个 append IOSink
    // 并存写同一 .part (前者永不关闭, Windows 上还会锁文件)
    if (!_accepting.add(t.transferId)) {
      Log.w('transfer', 'acceptFile re-entry ignored ${t.transferId}');
      return;
    }
    // 校验/合并进行中或已完成: 发送端重发带来的迟到 accept 不得再碰分片
    // (合并 isolate 正在边写边删 .segN, 再开 sink 必乱)
    if (t.status == TransferStatus.verifying ||
        t.status == TransferStatus.done) {
      _accepting.remove(t.transferId);
      Log.w(
        'transfer',
        'acceptFile during ${t.status.name} ignored ${t.transferId}',
      );
      return;
    }
    try {
      await _acceptFile(t);
    } finally {
      _accepting.remove(t.transferId);
    }
  }

  Future<void> _acceptFile(FileTransfer t) async {
    // 秒传: v2 对端 + 本地已有同名同大小文件 → 后台哈希比对, 一致则免传
    if (t.savePath == null && await _tryInstant(t)) return;
    var save = t.savePath;
    if (save == null) {
      // 剪贴板同步存「下载目录/cloudSend/clipboard」; 预览临时传输存
      // 缓存目录 (重启清空); 普通接收存下载目录
      final dir = t.clipboard
          ? await clipboardDir()
          : t.ephemeral
          ? (await _previewDir()).path
          : await downloadDir();
      var candidate = '$dir${Platform.pathSeparator}${t.fileName}';
      var i = 1;
      // 磁盘占用之外还要排除其他进行中传输已选定但未落盘的路径:
      // sink 懒开 (见分块处理器), 两个同名 offer 并发接受时只看磁盘会
      // 拿到同一路径, 两个 append sink 交错写同一 .part 必坏。
      // takenByOther 必须放 || 链最后同步求值: 它与循环退出后的
      // t.savePath 赋值之间无 await, 单 isolate 下与另一协程不会交错
      bool takenByOther(String p) => transfers.any(
        (x) =>
            !x.outgoing &&
            x.transferId != t.transferId &&
            x.savePath == p &&
            (x.status == TransferStatus.waiting ||
                x.status == TransferStatus.accepted ||
                x.status == TransferStatus.transferring ||
                x.status == TransferStatus.verifying),
      );
      while (await File(candidate).exists() ||
          await File('$candidate.part').exists() ||
          await File('$candidate.seg0').exists() ||
          takenByOther(candidate)) {
        final dot = t.fileName.lastIndexOf('.');
        candidate = dot > 0
            ? '$dir${Platform.pathSeparator}${t.fileName.substring(0, dot)}($i)${t.fileName.substring(dot)}'
            : '$dir${Platform.pathSeparator}${t.fileName}($i)';
        i++;
      }
      save = candidate;
      t.savePath = save;
    }
    final part = File('$save.part');
    var offset = 0;
    if (await part.exists()) {
      // 旧版单临时文件: 原样续传 (本次仍不分片)
      offset = await part.length();
      if (offset < 0 || offset > t.fileSize) {
        // 临时文件异常, 重头再来
        try {
          await part.delete();
        } catch (_) {}
        offset = 0;
      }
    } else if (t.fileSize > _segThreshold) {
      // v2 分片续传: 载入 .seghash 边车, 后台逐片校验已收完整片
      // (坏片及其后续删除), 只从可信前缀后续传; 校验耗时可达数分钟,
      // 期间向发送端发 file_accept_pending 保活防 offer 超时
      final sidecar = await _loadSegHashes(save);
      if (sidecar.isNotEmpty) {
        _segHashes[t.transferId] = sidecar;
        if (_offerV2.contains(t.transferId)) {
          _send({
            'type': 'file_accept_pending',
            'to': t.peerId,
            'transferId': t.transferId,
          });
          final keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
            _send({
              'type': 'file_accept_pending',
              'to': t.peerId,
              'transferId': t.transferId,
            });
          });
          try {
            await compute(verifySegsJob, {
              'save': save,
              'size': t.fileSize,
              'seg': _segSize,
              'hashes': sidecar,
            });
          } catch (_) {}
          keepAlive.cancel();
        }
      }
      _segHashes.putIfAbsent(t.transferId, () => {});
      // 大文件分片: 扫描已有片 — 完整片累计, 半片从长度处追加续传
      var i = 0;
      while (i * _segSize < t.fileSize) {
        final f = File('$save.seg$i');
        if (!await f.exists()) break;
        final expect = (t.fileSize - i * _segSize).clamp(0, _segSize);
        final len = await f.length();
        if (len == expect) {
          offset += len;
          i++;
          continue;
        }
        if (len > expect) {
          // 片比预期还长: 数据不可信, 删掉从这片重收
          try {
            await f.delete();
          } catch (_) {}
        } else {
          offset += len; // 半片
        }
        break;
      }
      if (offset >= t.fileSize) {
        // 片已收齐 (上次合并失败): 不再开新片, 等 file_done 重新合并
        i = (t.fileSize + _segSize - 1) ~/ _segSize - 1;
      }
      _recvSeg[t.transferId] = i;
    }
    // 写盘 sink 懒开: 首个分块到达时才打开 (见分块处理器),
    // 避免与并行车道协商前的预开 sink 冲突
    _canceled.remove(t.transferId);
    _recvAcked[t.transferId] = offset;
    // 接受时也记时间戳: 发送端若在 accept 后、首分块前死掉,
    // 0 字节挂起的盲区靠看门狗按"对端离线+超时"兜底
    _recvLastTs[t.transferId] = DateTime.now().millisecondsSinceEpoch;
    t.bytesDone = offset;
    _lastNotifyBytes = offset;
    t.status = TransferStatus.accepted;
    ChatDb.upsertTransfer(t);
    _send({
      'type': 'file_accept',
      'to': t.peerId,
      'transferId': t.transferId,
      'offset': offset,
      'v2': true,
      'parallel': true, // 支持并行车道; 是否启用由发送端决定
    });
    maybeP2p(t.peerId); // 传输将走中继时尝试升级为 P2P 直连
    notifyListeners();
  }

  /// 秒传尝试: 本地已有同名同大小的完成文件时, 后台算其哈希发给发送端比对,
  /// 一致则双方免传 (见 file_instant/file_done 处理)。返回 true = 已接管
  /// (正等待比对结果), false = 无候选, 走正常接收
  Future<bool> _tryInstant(FileTransfer t) async {
    if (t.ephemeral || t.clipboard || t.bytesDone != 0) return false;
    if (t.status != TransferStatus.waiting) return false;
    if (!_offerV2.contains(t.transferId)) return false; // 旧版发送端不认识 file_instant
    if (t.fileSize < _instantThreshold) return false;
    // 候选: 下载目录同名文件 + 已完成接收记录里同名同大小的文件
    final dir = await downloadDir();
    final paths = <String>['$dir${Platform.pathSeparator}${t.fileName}'];
    for (final x in transfers) {
      if (x.outgoing || x.status != TransferStatus.done || x.savePath == null) {
        continue;
      }
      if (x.fileName == t.fileName &&
          x.fileSize == t.fileSize &&
          !paths.contains(x.savePath)) {
        paths.add(x.savePath!);
      }
    }
    // 哈希大文件可达数分钟: 期间向发送端发 pending 保活, 防 offer 超时
    _send({
      'type': 'file_accept_pending',
      'to': t.peerId,
      'transferId': t.transferId,
    });
    final keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
      _send({
        'type': 'file_accept_pending',
        'to': t.peerId,
        'transferId': t.transferId,
      });
    });
    List<dynamic>? res;
    try {
      res = await compute(_instantHashJob, [t.fileSize, ...paths]);
    } catch (_) {}
    keepAlive.cancel();
    if (res == null) return false; // 没有大小相符的候选: 正常接收
    // 哈希期间被取消/删除/状态已变: 静默放弃, 不再走正常接收
    if (!transfers.contains(t) || t.status != TransferStatus.waiting) {
      return true;
    }
    _instantPending[t.transferId] = res[0] as String;
    t.status = TransferStatus.accepted; // 等待发送端哈希比对结果
    ChatDb.upsertTransfer(t);
    _send({
      'type': 'file_instant',
      'to': t.peerId,
      'transferId': t.transferId,
      'sha256': res[1],
    });
    Log.i('transfer', 'instant probe ${t.fileName} -> ${t.peerId}');
    notifyListeners();
    // 对端哈希兜底: 超时无回应回退正常接收
    _instantTimers[t.transferId]?.cancel();
    _instantTimers[t.transferId] = Timer(const Duration(seconds: 600), () {
      _instantTimers.remove(t.transferId);
      if (_instantPending.remove(t.transferId) != null &&
          t.status == TransferStatus.accepted &&
          t.bytesDone == 0 &&
          transfers.contains(t)) {
        Log.w('transfer', 'instant wait timeout ${t.fileName}, fallback');
        unawaited(acceptFile(t));
      }
    });
    return true;
  }

  /// 秒传比对 (发送侧): 后台哈希本端文件, 一致则直接完成并通知对方,
  /// 不一致回 file_instant_nack 让对方回退正常接收
  Future<void> _handleInstant(FileTransfer t, String theirHex) async {
    String? hex;
    try {
      hex = await compute(sha256HexOfFile, t.savePath!);
    } catch (_) {}
    // 哈希期间可能已被取消或走了正常流程: 结果作废
    if (t.status != TransferStatus.waiting) return;
    if (hex != null && hex == theirHex) {
      _offerTimers.remove(t.transferId)?.cancel();
      t.bytesDone = t.fileSize;
      t.status = TransferStatus.done;
      _resetRetry(t.transferId);
      ChatDb.upsertTransfer(t);
      _send({
        'type': 'file_done',
        'to': t.peerId,
        'transferId': t.transferId,
        'instant': true,
        'size': t.fileSize,
      });
      _cleanupTemp(t);
      Log.i('transfer', 'instant send ${t.fileName} (${t.fileSize}B)');
      notifyListeners();
    } else {
      _send({
        'type': 'file_instant_nack',
        'to': t.peerId,
        'transferId': t.transferId,
      });
      _armOfferTimer(t.transferId, 120); // 等对方回退后重新 accept
    }
  }

  /// 秒传落成 (接收侧): 发送端确认本地候选文件与其一致, 直接指向已有文件
  void _finishInstant(FileTransfer t, String path) {
    t.savePath = path;
    t.bytesDone = t.fileSize;
    t.status = TransferStatus.done;
    _resetRetry(t.transferId);
    _offerV2.remove(t.transferId);
    ChatDb.upsertTransfer(t);
    _send({
      'type': 'file_result',
      'to': t.peerId,
      'transferId': t.transferId,
      'ok': true,
    });
    Log.i('transfer', 'instant done ${t.fileName} (${t.fileSize}B)');
    notifyListeners();
  }

  /// 载入 .seghash 边车 (每行 "片号 hex"): 续传时校验已收分片的可信性
  Future<Map<int, String>> _loadSegHashes(String save) async {
    final m = <int, String>{};
    try {
      final f = File('$save.seghash');
      if (await f.exists()) {
        for (final line in await f.readAsLines()) {
          final sp = line.trim().split(' ');
          if (sp.length == 2) {
            final i = int.tryParse(sp[0]);
            if (i != null && sp[1].isNotEmpty) m[i] = sp[1];
          }
        }
      }
    } catch (_) {}
    return m;
  }

  void rejectFile(FileTransfer t) {
    t.status = TransferStatus.rejected;
    ChatDb.upsertTransfer(t);
    _send({'type': 'file_reject', 'to': t.peerId, 'transferId': t.transferId});
    notifyListeners();
  }

  /// 取消传输 (双向皆可); waiting 的外发请求走 file_reject 语义
  Future<void> cancelTransfer(FileTransfer t) async {
    if (t.status == TransferStatus.waiting) {
      if (t.outgoing) {
        _offerTimers.remove(t.transferId)?.cancel();
        t.status = TransferStatus.canceled;
        ChatDb.upsertTransfer(t);
        _send({
          'type': 'file_reject',
          'to': t.peerId,
          'transferId': t.transferId,
        });
        _cleanupTemp(t);
        notifyListeners();
      } else {
        rejectFile(t);
      }
      return;
    }
    if (t.status != TransferStatus.accepted &&
        t.status != TransferStatus.transferring) {
      return;
    }
    _canceled.add(t.transferId);
    _clearInstant(t.transferId); // 秒传等待一并终止
    final ws = _sendWaiters.remove(t.transferId);
    if (ws != null) {
      for (final w in ws) {
        if (!w.isCompleted) w.complete();
      }
    }
    // 若还在发送队列里排队: 直接出队 (队列泵会跳过非 accepted 状态, 这里顺手清掉)
    if ((_sendQueue[t.peerId] ?? const []).contains(t.transferId)) {
      _sendQueue[t.peerId]!.remove(t.transferId);
      _queuedOffsets.remove(t.transferId);
    }
    // 显式取消: 半成品 .part 没有保留价值
    await _closeIncoming(t.transferId, deletePart: true);
    t.status = TransferStatus.canceled;
    ChatDb.upsertTransfer(t);
    _send({'type': 'file_cancel', 'to': t.peerId, 'transferId': t.transferId});
    _cleanupTemp(t);
    notifyListeners();
  }

  /// 对方取消: 停发送/关接收, 删除 .part
  void _remoteCancel(FileTransfer t) {
    if (t.status != TransferStatus.waiting &&
        t.status != TransferStatus.accepted &&
        t.status != TransferStatus.transferring) {
      return;
    }
    _canceled.add(t.transferId);
    _clearInstant(t.transferId);
    final ws = _sendWaiters.remove(t.transferId);
    if (ws != null) {
      for (final w in ws) {
        if (!w.isCompleted) w.complete();
      }
    }
    _closeIncoming(t.transferId, deletePart: true);
    t.status = TransferStatus.canceled;
    _resetRetry(t.transferId);
    ChatDb.upsertTransfer(t);
    _cleanupTemp(t);
    notifyListeners();
  }

  /// 重发失败/已取消的外发文件 (同 transferId, 对方可从 .part 续传)
  Future<bool> retrySend(FileTransfer t) async {
    if (!t.outgoing || t.savePath == null) return false;
    if (t.status != TransferStatus.failed &&
        t.status != TransferStatus.canceled &&
        t.status != TransferStatus.rejected) {
      return false;
    }
    if (!isOnline(t.peerId) || !await File(t.savePath!).exists()) return false;
    t.status = TransferStatus.waiting;
    t.bytesDone = 0;
    ChatDb.upsertTransfer(t);
    _send({
      'type': 'file_offer',
      'to': t.peerId,
      'transferId': t.transferId,
      'name': t.fileName,
      'size': t.fileSize,
      'v2': true,
      // 剪贴板同步的重发也要带标志: 对端重启后临时记录已丢,
      // 否则会落成普通弹窗传输而不是进剪贴板目录
      if (t.clipboard) 'clip': true,
    });
    notifyListeners();
    _armOfferTimer(t.transferId, 60);
    return true;
  }

  /// 续传失败的接收文件: 重新发 file_accept, 带上 .part 偏移
  Future<bool> retryReceive(FileTransfer t) async {
    if (t.outgoing || t.savePath == null) return false;
    if (t.status != TransferStatus.failed) return false;
    if (!isOnline(t.peerId)) return false;
    await acceptFile(t);
    return true;
  }

  /// 关闭接收侧状态; deletePart=false 时保留 .part 供断点续传
  Future<void> _closeIncoming(String tid, {required bool deletePart}) async {
    // 先排空写盘串行链再关 sink: 否则尾部排队中的分块还没落盘,
    // 校验改名可能拿到缺尾巴的文件 (链内异常已各自吞掉, 这里只为等待)
    final chain = _recvChain.remove(tid);
    if (chain != null) {
      try {
        await chain;
      } catch (_) {}
    }
    final sink = _incoming.remove(tid);
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    // 并行接收的片 sink 一并关闭 (与主链共用上面的串行链, 已无在途写)
    final parSinks = _parSinks.remove(tid);
    if (parSinks != null) {
      for (final s in parSinks.values) {
        try {
          await s.close();
        } catch (_) {}
      }
    }
    _parMode.remove(tid);
    _parRecvBytes.remove(tid);
    _parSegReset.removeWhere((k) => k.startsWith('$tid:'));
    _recvAcked.remove(tid);
    _recvLastTs.remove(tid);
    _recvSeg.remove(tid);
    if (deletePart) {
      _segHashes.remove(tid);
      _offerV2.remove(tid);
      final t = _find(tid);
      if (t?.savePath != null) {
        try {
          final part = File('${t!.savePath}.part');
          if (await part.exists()) await part.delete();
        } catch (_) {}
        // 分片与分片哈希边车一并清掉
        for (var i = 0; ; i++) {
          try {
            final f = File('${t!.savePath}.seg$i');
            if (!await f.exists()) break;
            await f.delete();
          } catch (_) {}
        }
        try {
          final sh = File('${t.savePath}.seghash');
          if (await sh.exists()) await sh.delete();
        } catch (_) {}
      }
    }
  }

  /// 收到 file_done: 校验字节数和 SHA-256, 通过则 .part 改名为正式文件
  Future<void> _finishIncoming(FileTransfer t, {String? sha256}) async {
    final tid = t.transferId;
    // 防重入: 合并+校验可达数分钟, 期间发送端重发带来的重复 file_done
    // 必须忽略 — 两个合并任务并发写同一 .part 必坏 (100% 后失败重传
    // 循环的根因之一); 已完成的同样不再处理
    if (t.status == TransferStatus.verifying ||
        t.status == TransferStatus.done ||
        !_finishing.add(tid)) {
      return;
    }
    // 校验中: 停滞看门狗按「无分块 45s」会误判 (合并期间本就没有分块),
    // 独立状态让看门狗跳过、UI 显示校验中而不是像卡死
    t.status = TransferStatus.verifying;
    ChatDb.upsertTransfer(t);
    notifyListeners();
    try {
      await _finishIncomingInner(t, sha256: sha256);
    } finally {
      _finishing.remove(tid);
    }
  }

  Future<void> _finishIncomingInner(FileTransfer t, {String? sha256}) async {
    final tid = t.transferId;
    final segmented = _recvSeg.containsKey(tid);
    final segHashes = _segHashes[tid];
    final origSave = t.savePath; // 合并改名前的路径 (.segN/.seghash 以它命名)
    await _closeIncoming(tid, deletePart: false);
    var ok = t.bytesDone == t.fileSize;
    if (ok && t.savePath != null) {
      final nseg = (t.fileSize + _segSize - 1) ~/ _segSize;
      if (segmented && segHashes != null && segHashes.length >= nseg) {
        // v2 分片校验: 逐片后台哈希比对 (能定位坏片, 失败保留好片供续传),
        // 全部通过后纯拷贝合并; 不再重算总哈希
        try {
          ok = await compute(verifySegsJob, {
            'save': t.savePath,
            'size': t.fileSize,
            'seg': _segSize,
            'hashes': segHashes,
          });
          if (ok) {
            await compute(copySegsAndDelete, [
              '${t.savePath}.part',
              for (var i = 0; i < nseg; i++) '${t.savePath}.seg$i',
            ]);
          }
        } catch (_) {
          ok = false;
        }
      } else if (sha256 != null && sha256.isNotEmpty) {
        // 后台 isolate 流式哈希: 几 GB 的文件在主 isolate 上跑
        // 纯 Dart SHA-256 会把整机拖死; compute 另起 isolate, UI 保持流畅。
        // 分片模式先顺序合并成 .part, 边合并边算哈希, 合完的片即删
        // (合并中磁盘占用 ≈ 一份文件; 合并失败片还在, 重试可再合并)
        String? hex;
        try {
          if (segmented) {
            hex = await compute(mergeSegmentsAndHash, [
              '${t.savePath}.part',
              for (var i = 0; i < nseg; i++) '${t.savePath}.seg$i',
            ]);
          } else {
            hex = await compute(sha256HexOfFile, '${t.savePath}.part');
          }
        } catch (_) {}
        ok = hex != null && hex == sha256;
      } else if (segmented) {
        // 分片模式但片哈希不全, file_done 也没带总哈希: 无法校验,
        // 且 .segN 未合并成文件 — 若判完成用户会看到"完成"却没有文件。
        // 判失败保留好片, 重试续收缺失片即可
        Log.e(
          'transfer',
          'seg hashes missing (${segHashes?.length ?? 0}/$nseg) ${t.fileName}, fail',
        );
        ok = false;
      }
    }
    if (ok && t.savePath != null) {
      try {
        final part = File('${t.savePath}.part');
        if (await part.exists()) {
          final dir = t.savePath!.substring(
            0,
            t.savePath!.length - t.fileName.length,
          );
          var dest = t.savePath!;
          var i = 1;
          while (await File(dest).exists()) {
            final dot = t.fileName.lastIndexOf('.');
            dest = dot > 0
                ? '$dir${t.fileName.substring(0, dot)}($i)${t.fileName.substring(dot)}'
                : '$dir${t.fileName}($i)';
            i++;
          }
          await part.rename(dest);
          t.savePath = dest;
        }
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      // 数据不可信: 删掉 .part; 分片模式下校验通过的前缀片保留,
      // 重试续传只需重收坏片及之后 (见 _acceptFile 的边车校验)
      Log.e(
        'transfer',
        'recv verify failed ${t.fileName} (${t.bytesDone}/${t.fileSize}B)',
      );
      t.bytesDone = 0;
      if (t.savePath != null) {
        try {
          final part = File('${t.savePath}.part');
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    } else if (origSave != null) {
      // 成功: 分片已合并删除, 边车一并清掉 (按改名前的原始路径)
      try {
        final sh = File('$origSave.seghash');
        if (await sh.exists()) await sh.delete();
      } catch (_) {}
    }
    _segHashes.remove(tid);
    _offerV2.remove(tid);
    t.status = ok ? TransferStatus.done : TransferStatus.failed;
    if (ok) {
      Log.i('transfer', 'recv done ${t.fileName} (${t.bytesDone}B)');
      _resetRetry(tid);
      // 剪贴板同步文件收妥: 写入剪贴板记录 (列表页展示/点击打开)
      if (t.clipboard && t.savePath != null) {
        await ChatDb.insertClip(
          ClipItem(
            kind: 'file',
            content: t.savePath!,
            ts: DateTime.now().millisecondsSinceEpoch,
            fromMe: false,
            peerId: t.peerId,
          ),
        );
        _clipChanged();
      }
    }
    ChatDb.upsertTransfer(t);
    _send({'type': 'file_result', 'to': t.peerId, 'transferId': tid, 'ok': ok});
    notifyListeners();
  }

  String peerName(String id) {
    for (final p in peers) {
      if (p.id == id) return p.name;
    }
    // 离线设备回退到历史记录里的名字
    final k = knownPeers[id];
    final kn = k?['name'] as String?;
    if (kn != null && kn.isNotEmpty) return kn;
    return id.substring(0, 8);
  }

  bool isOnline(String id) => peers.any((p) => p.id == id);

  /// 历史设备中当前不在线的, 按最后在线时间倒序 (设备页「未在线」分组)
  List<Peer> get offlinePeers {
    final online = {for (final p in peers) p.id};
    final entries =
        knownPeers.entries.where((e) => !online.contains(e.key)).toList()
          ..sort(
            (a, b) => (b.value['lastSeen'] as int? ?? 0).compareTo(
              a.value['lastSeen'] as int? ?? 0,
            ),
          );
    return [
      for (final e in entries)
        Peer(
          id: e.key,
          name: e.value['name'] as String? ?? e.key.substring(0, 8),
          avatar: e.value['avatar'] as String?,
          platform: e.value['platform'] as String?,
        ),
    ];
  }

  /// 删除历史设备记录 (连同其信任/拉黑标记; 聊天记录保留)
  Future<void> removeKnownPeer(String peerId) async {
    knownPeers.remove(peerId);
    trustedPeers.remove(peerId);
    blockedPeers.remove(peerId);
    blockedPeerNames.remove(peerId);
    _avatarBytesCache.remove(peerId);
    final sp = await SharedPreferences.getInstance();
    sp.setString('knownPeers', jsonEncode(knownPeers));
    sp.setStringList('trustedPeers', trustedPeers.toList());
    sp.setStringList('blockedPeers', blockedPeers.toList());
    sp.setString('blockedPeerNames', jsonEncode(blockedPeerNames));
    Log.i('app', 'removed known peer $peerId');
    notifyListeners();
  }

  /// 对端头像 (base64 PNG), 无则 null
  String? peerAvatar(String id) {
    for (final p in peers) {
      if (p.id == id) return p.avatar;
    }
    return knownPeers[id]?['avatar'] as String?;
  }

  /// 解码后的对端头像字节(缓存, 避免每次 build 重新解码导致闪烁)
  final Map<String, Uint8List> _avatarBytesCache = {};

  Uint8List? peerAvatarBytes(String id) {
    final b64 = peerAvatar(id);
    if (b64 == null || b64.isEmpty) return null;
    final cached = _avatarBytesCache[id];
    if (cached != null) return cached;
    try {
      final bytes = base64Decode(b64);
      _avatarBytesCache[id] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 本机头像字节 (96px 缓存): 未加载时触发异步加载,
  /// 避免每个「我」的气泡都同步 existsSync + 全尺寸解码原图
  Uint8List? _ownAvatarBytes;
  bool _ownAvatarLoading = false;

  Uint8List? ownAvatarBytes() {
    if (avatarPath.isEmpty) return null;
    if (_ownAvatarBytes != null) return _ownAvatarBytes;
    if (!_ownAvatarLoading) {
      _ownAvatarLoading = true;
      _avatarBase64().then((b64) {
        _ownAvatarLoading = false;
        if (b64 == null) return;
        try {
          _ownAvatarBytes = base64Decode(b64);
          notifyListeners();
        } catch (_) {}
      });
    }
    return null;
  }
}

/// 一次 P2P 打洞会话: 发起方生成 sid+token, 双方凭 token 验证打进来的连接
class _PunchSession {
  final String sid;
  final String peerId;
  final String token;
  final bool initiator;
  String? peerIp; // 服务器注入的对端公网 IP (fromIp)
  int? peerPort; // 对端 TCP 监听端口 (NAT 端口保持时可直连)
  bool done = false; // 已成功 (出站被收养或入站验证通过)
  bool failed = false;

  _PunchSession(this.sid, this.peerId, this.token, {required this.initiator});
}

/// 后台 SHA-256 worker: 独立 isolate 流式哈希, 发送端喂块不占 UI isolate
/// (纯 Dart crypto 逐块算是高速发送时界面卡的根因; Uint8List 过 SendPort
/// 只是 native memcpy, 比哈希本身便宜一个量级)。
/// 带背压: 未消化数据超 32MB 时 add 方 await credit() 暂停喂入
class _HashWorker {
  _HashWorker._(this._isolate, this._send, this._hex, this._port);

  static const _creditLimit = 32 * 1024 * 1024;

  final Isolate _isolate;
  final SendPort _send;
  final Future<String> _hex;
  final ReceivePort _port;
  int _fed = 0; // 已喂入字节
  int _hashed = 0; // worker 已消化字节
  Completer<void>? _credit;

  static Future<_HashWorker> start() async {
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(_hashWorkerMain, fromWorker.sendPort);
    final events = fromWorker.asBroadcastStream();
    final send = await events.first as SendPort;
    final hex = events.firstWhere((e) => e is String).then((e) => e as String);
    // dispose 时 port 关闭, 若 hex 还没出来 (中止路径) firstWhere 会以
    // StateError 收尾; 挂个错误处理防无人 await 时抛 unhandled async error
    unawaited(hex.catchError((_) => ''));
    final w = _HashWorker._(isolate, send, hex, fromWorker);
    unawaited(
      events.where((e) => e is int).forEach((e) {
        w._hashed = e as int;
        final c = w._credit;
        if (c != null &&
            !c.isCompleted &&
            w._fed - w._hashed <= _creditLimit) {
          w._credit = null;
          c.complete();
        }
      }),
    );
    return w;
  }

  /// 喂一块数据 (拷贝发生在 native 层, 远便宜于在 UI isolate 跑哈希)
  void add(List<int> chunk) {
    _fed += chunk.length;
    _send.send(chunk);
  }

  /// 未消化数据超背压阈值时等 worker 赶上 (与网络发送窗口同理)
  Future<void> credit() async {
    if (_fed - _hashed <= _creditLimit) return;
    final c = _credit ??= Completer<void>();
    await c.future;
  }

  /// 结束喂入, 等最终 hex; worker 退出后回收 isolate 与 ReceivePort
  /// (原生端口不回收, 并行模式每片泄漏一个)
  Future<String> close() async {
    _send.send('close');
    try {
      return await _hex;
    } finally {
      dispose();
    }
  }

  void dispose() {
    _port.close();
    _isolate.kill();
  }
}

/// 宿主侧的流式发送会话: 播放端按需请求的区间排进队列, 顺序读盘发帧
class _StreamSendSession {
  final String tid;
  final String peerId;
  final String path;
  final int size;
  final List<(int, int)> queue = []; // (offset, length) 待发送区间
  bool pumping = false;
  RandomAccessFile? raf;

  _StreamSendSession(this.tid, this.peerId, this.path, this.size);

  Future<void> close() async {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

/// worker isolate 入口 (必须顶层函数): 字节列表喂哈希, 每消化 8MB 上报
/// 一次进度 (背压用), 收到 'close' 回发最终 hex 后退出
void _hashWorkerMain(SendPort mainPort) {  Digest? digest;
  final sink = sha256.startChunkedConversion(_DigestSink((d) => digest = d));
  var hashed = 0;
  var reported = 0;
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg is List<int>) {
      sink.add(msg);
      hashed += msg.length;
      if (hashed - reported >= 8 * 1024 * 1024) {
        reported = hashed;
        mainPort.send(hashed);
      }
    } else {
      sink.close();
      mainPort.send(digest.toString());
      inbox.close();
    }
  });
}

/// 后台 isolate 用: 流式计算整个文件的 SHA-256 hex。
/// 必须是顶层函数 (compute 的入口要求); 大文件放后台跑,
/// 避免纯 Dart 哈希拖满 UI isolate (Android 大文件接收卡死的修复)
Future<String> sha256HexOfFile(String path) async {
  Digest? digest;
  final sink = sha256.startChunkedConversion(_DigestSink((d) => digest = d));
  await for (final chunk in File(path).openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return digest.toString();
}

/// 后台 isolate 用: 读图→解码→等比缩到最长边 maxSide (已更小则不动)→
/// JPEG (列表缩略图 q70, 远程图片预览大图 q80) (compute 入口, 必须顶层)
Future<Uint8List?> _imageThumbJob((String, int) args) async {
  final (path, maxSide) = args;
  try {
    final f = File(path);
    final len = await f.length();
    if (len <= 0 || len > 100 * 1024 * 1024) return null;
    final im = img.decodeImage(await f.readAsBytes());
    if (im == null) return null;
    var out = im;
    if (im.width >= im.height && im.width > maxSide) {
      out = img.copyResize(im, width: maxSide);
    } else if (im.height > maxSide) {
      out = img.copyResize(im, height: maxSide);
    }
    return Uint8List.fromList(
      img.encodeJpg(out, quality: maxSide > 256 ? 80 : 70),
    );
  } catch (_) {
    return null;
  }
}

/// 后台 isolate 用: 头像读图→解码→裁方 96px→JPEG q85→base64 (compute 入口)
/// 用 JPEG 不用 PNG: 照片内容 PNG 有 20KB+ (base64 超局域网宣告的
/// 16KB 上限直接被丢弃, 对端永远看不到头像), JPEG 只有 ~4KB
Future<String?> _avatarJob(String path) async {
  try {
    final decoded = img.decodeImage(await File(path).readAsBytes());
    if (decoded == null) return null;
    final resized = img.copyResizeCropSquare(decoded, size: 96);
    return base64Encode(img.encodeJpg(resized, quality: 85));
  } catch (_) {
    return null;
  }
}

/// 后台 isolate 用: 流式打包文件夹为 zip (compute 入口; args = [dirPath, zipPath])
Future<void> _zipFolderJob(List<String> args) =>
    ZipFileEncoder().zipDirectory(Directory(args[0]), filename: args[1]);

/// 后台 isolate 用: 内存字节 SHA-256 hex (compute 入口;
/// 剪贴板轮询每 2s 一次, 大截图的纯 Dart 哈希不能占 UI isolate)
String sha256HexOfBytes(Uint8List bytes) => sha256.convert(bytes).toString();

/// 后台 isolate 用: 把分片按顺序合并成 dest, 边合并边算 SHA-256, 返回 hex。
/// args[0] = 目标路径, 其余 = 各分片路径 (按序)。
/// 每片完整写入目标后才删源片: 中途失败时剩余片还在, 重试只需再合并;
/// 合并期间磁盘占用 ≈ 一份文件 + 当前片 (目标随合并增长, 源片随删减小)
Future<String> mergeSegmentsAndHash(List<String> args) async {
  final dest = args.first;
  final segs = args.sublist(1);
  Digest? digest;
  final hashSink = sha256.startChunkedConversion(_DigestSink((d) => digest = d));
  final out = File(dest).openWrite();
  try {
    for (final p in segs) {
      final f = File(p);
      await for (final chunk in f.openRead()) {
        hashSink.add(chunk);
        out.add(chunk);
      }
      await out.flush();
      await f.delete();
    }
    hashSink.close();
    await out.close();
    return digest.toString();
  } catch (_) {
    // 清理半成品 dest, 源片未删的部分保留 (可重试合并)
    try {
      await out.close();
    } catch (_) {}
    try {
      await File(dest).delete();
    } catch (_) {}
    rethrow;
  }
}

/// 后台 isolate 内部共用: 流式算一个文件的 SHA-256 hex
Future<String> _hashFileHex(File f) async {
  Digest? digest;
  final sink = sha256.startChunkedConversion(_DigestSink((d) => digest = d));
  await for (final chunk in f.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return digest.toString();
}

/// 后台 isolate 用 (秒传): 在候选路径里找第一个大小相符的文件,
/// 流式算其 SHA-256, 返回 [路径, hex]; 无相符候选返回 null。
/// args[0] = 期望大小, 其余 = 候选路径 (按优先级)
Future<List<dynamic>?> _instantHashJob(List<dynamic> args) async {
  final size = args[0] as int;
  for (final p in args.sublist(1)) {
    final f = File(p as String);
    try {
      if (!await f.exists() || await f.length() != size) continue;
      return [p, await _hashFileHex(f)];
    } catch (_) {}
  }
  return null;
}

/// 后台 isolate 用: 逐片校验 .segN 与给定哈希 (compute 入口)。
/// args: {save, size, seg, hashes:{片号:hex}}。从 0 起连续检查:
/// 完整片有哈希则比对, 校验不符/超长即删该片及后续全部并返回 false;
/// 无哈希的完整片照旧信任; 遇缺失/半片停止 (半片留给追加续传)。
/// 片数齐全且全部通过返回 true (收完校验); 续传修剪场景只看删除副作用
Future<bool> verifySegsJob(Map<String, dynamic> args) async {
  final save = args['save'] as String;
  final fileSize = args['size'] as int;
  final segSize = args['seg'] as int;
  final hashes = (args['hashes'] as Map).map(
    (k, v) => MapEntry(k is int ? k : int.parse('$k'), '$v'),
  );
  var i = 0;
  while (i * segSize < fileSize) {
    final f = File('$save.seg$i');
    if (!await f.exists()) break; // 缺失: 后续还没收/已被修剪, 停
    final expect = (fileSize - i * segSize).clamp(0, segSize);
    final len = await f.length();
    if (len < expect) break; // 半片: 追加续传, 不算坏
    if (len > expect ||
        (hashes[i] != null && await _hashFileHex(f) != hashes[i])) {
      // 超长或校验不符: 该片及之后全部不可信, 删除 (好前缀保留)
      for (var j = i; ; j++) {
        try {
          final g = File('$save.seg$j');
          if (!await g.exists()) break;
          await g.delete();
        } catch (_) {}
      }
      return false;
    }
    i++;
  }
  final nseg = (fileSize + segSize - 1) ~/ segSize;
  return i >= nseg;
}

/// 后台 isolate 用: 把已校验通过的分片顺序合并成 dest (纯拷贝, 不算哈希),
/// 每片完整写入后删源片; 失败清理半成品 dest, 未删的源片保留可重试。
/// args[0] = 目标路径, 其余 = 各分片路径 (按序)
Future<void> copySegsAndDelete(List<String> args) async {
  final dest = args.first;
  final segs = args.sublist(1);
  final out = File(dest).openWrite();
  try {
    for (final p in segs) {
      final f = File(p);
      await for (final chunk in f.openRead()) {
        out.add(chunk);
      }
      await out.flush();
      await f.delete();
    }
    await out.close();
  } catch (_) {
    try {
      await out.close();
    } catch (_) {}
    try {
      await File(dest).delete();
    } catch (_) {}
    rethrow;
  }
}

class _DigestSink implements Sink<Digest> {
  final void Function(Digest) onDigest;
  _DigestSink(this.onDigest);

  @override
  void add(Digest event) => onDigest(event);

  @override
  void close() {}
}
