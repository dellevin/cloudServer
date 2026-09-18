import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'db.dart';
import 'lan.dart';
import 'log.dart';
import 'models.dart';
import 'transfer_service.dart';

/// 中继协议:
/// 文本帧(JSON):
///  C->S {type:'register', id, name}
///  S->C {type:'peers', peers:[{id,name}...]}
///  转发(带 from/to): chat / chat_ack / file_offer / file_accept / file_reject
///    / file_done / file_progress / file_result / file_cancel
/// 二进制帧: 36字节 transferId(ASCII) + 文件数据块, 服务器按 transferId 路由
///
/// 传输可靠性:
///  - 接收端写入 `<savePath>.part` 临时文件, 校验通过后改名
///  - file_accept 带 offset: 已收字节数, 发送端从该偏移续传
///  - file_progress: 接收端每收 2MB 回执一次, 发送端 8MB 窗口背压
///  - file_done 带 sha256, 接收端校验后回 file_result {ok}
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

  /// 信任的设备 (设备ID): 这些设备发来的文件自动接受, 不再弹窗询问
  Set<String> trustedPeers = {};
  List<Peer> peers = []; // 中继 + 局域网合并后的在线设备
  List<Peer> _relayPeers = []; // 仅中继服务器下发的在线设备
  Set<String> _relayIds = {};
  List<String> manualLanTargets = []; // 手动添加的局域网设备 "ip:port"
  final List<FileTransfer> transfers = [];
  final Map<String, List<ChatMessage>> chats = {};
  final Map<String, int> unread = {};

  late LanManager _lan; // 仅中继模式下为已 dispose 的空实例 (不启动发现/直连)

  WebSocketChannel? _ch;
  Timer? _reconnectTimer;
  bool _manualClose = false;
  int _retryCount = 0; // 重连次数 (指数退避用, 连上后归零)
  bool _svcSyncPending = false;

  /// 被服务器拒绝的原因 (kick=踢下线/black_id=拉黑ID/black_ip=拉黑IP/white=不在白名单)
  /// null=正常; 被拦后停止自动重连, 由用户手动重连 (connect 时清除)
  String? blockedReason;

  /// 被拦原因 → 用户可读文案
  static String blockedText(String reason) => switch (reason) {
    'kick' => '你已被管理员踢下线',
    'black_id' => '你的设备已被管理员拉黑 (设备ID)',
    'black_ip' => '当前 IP 已被管理员拉黑',
    'white' => '你的设备不在服务器白名单内',
    'rate' => '操作过于频繁，已被服务器暂时断开',
    _ => '服务器拒绝了连接',
  };

  /// 传输状态变化时同步 Android 前台服务 (microtask 节流)
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!Platform.isAndroid || _svcSyncPending) return;
    _svcSyncPending = true;
    scheduleMicrotask(() {
      _svcSyncPending = false;
      TransferForegroundService.sync(
        transfers
            .where(
              (t) =>
                  t.status == TransferStatus.accepted ||
                  t.status == TransferStatus.transferring,
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

  /// 应用是否在前台 (后台时即使开着聊天页也要计未读+弹通知)
  bool _appForeground = true;

  void _initLifecycle() {
    AppLifecycleListener(
      onStateChange: (s) => _appForeground = s == AppLifecycleState.resumed,
    );
  }

  final Map<String, IOSink> _incoming = {};
  final Map<String, _HashState> _recvHash = {}; // 接收侧累积哈希
  final Map<String, int> _recvAcked = {}; // 接收侧上次回执的字节数
  final Map<String, int> _sendAcked = {}; // 发送侧: 对方已确认收到的字节数
  final Map<String, Completer<void>> _sendWaiters = {}; // 背压等待
  final Set<String> _canceled = {}; // 已取消的 transferId (发送循环据此退出)
  final Set<String> _aborted = {}; // 对端掉线中止的 transferId
  final Set<String> _unverified = {}; // 已发完但尚未收到接收端校验结果的 transferId
  int _lastNotifyBytes = 0;

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
    connMode = sp.getString('connMode') ?? 'both';
    queueSends = sp.getBool('queueSends') ?? true;
    trustedPeers = (sp.getStringList('trustedPeers') ?? []).toSet();
    Log.i('app', 'init: id=$deviceId name=$deviceName mode=$connMode '
        'queue=$queueSends trusted=${trustedPeers.length}');
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
    if (serverAddr.isNotEmpty && _relayActive) connect(serverAddr);
  }

  /// 构造局域网管理器 (未启动状态; 仅中继模式下作为空实例占位)
  LanManager _createLan() => LanManager(
    deviceId: deviceId,
    getName: () => deviceName,
    getAvatarB64: _avatarBase64,
  );

  /// 启动局域网发现与直连 (both/lan 模式)
  void _startLan() {
    _lan = _createLan();
    _lan.onPeersChanged = () {
      _rebuildPeers();
      _abortTransfersWithOfflinePeers();
      _resendUndelivered();
    };
    _lan.onFrame = _onData; // 直连通道的消息与中继走同一处理
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
        _ch?.sink.add(
          jsonEncode({
            'type': 'register',
            'id': deviceId,
            'name': deviceName,
            'avatar': await _avatarBase64(),
            'ver': kProtocolVersion,
          }),
        );
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
      for (final pid in await ChatDb.conversationPeerIds()) {
        final h = await ChatDb.history(pid, limit: historyPageSize);
        chats[pid] = h;
        hasMoreHistory[pid] = h.length >= historyPageSize;
      }
      transfers.addAll(await ChatDb.loadTransfers());
      // 恢复失败接收传输的已收字节: .part 文件还在就可以断点续传
      for (final t in transfers) {
        if (!t.outgoing &&
            t.status == TransferStatus.failed &&
            t.savePath != null) {
          try {
            final part = File('${t.savePath}.part');
            if (await part.exists()) {
              final len = await part.length();
              if (len > 0 && len <= t.fileSize) t.bytesDone = len;
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
        notificationDetails: const NotificationDetails(
          windows: WindowsNotificationDetails(),
          android: AndroidNotificationDetails(
            'chat',
            '聊天消息',
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
    notifyListeners();
    if (connected) {
      disconnect();
      connect(serverAddr);
    }
  }

  String? _avatarB64;

  /// 压缩头像为 96x96 PNG base64 (用于中继广播)
  Future<String?> _avatarBase64() async {
    if (avatarPath.isEmpty) return null;
    if (_avatarB64 != null) return _avatarB64;
    try {
      final bytes = await File(avatarPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final resized = img.copyResizeCropSquare(decoded, size: 96);
      _avatarB64 = base64Encode(img.encodePng(resized));
      return _avatarB64;
    } catch (_) {
      return null;
    }
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

  bool isTrusted(String peerId) => trustedPeers.contains(peerId);

  /// 信任/取消信任设备: 信任的设备发来的文件自动接受 (持久化)
  Future<void> setTrusted(String peerId, bool v) async {
    if (v) {
      trustedPeers.add(peerId);
    } else {
      trustedPeers.remove(peerId);
    }
    (await SharedPreferences.getInstance()).setStringList(
      'trustedPeers',
      trustedPeers.toList(),
    );
    Log.i('app', 'trusted $peerId -> $v');
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
    try {
      final uri = serverAddr.startsWith('ws') ? serverAddr : 'ws://$serverAddr';
      final ch = WebSocketChannel.connect(Uri.parse(uri));
      await ch.ready; // 等握手完成, 失败抛异常走退避重连
      if (_manualClose) {
        // 等待握手期间用户点了断开
        ch.sink.close();
        return;
      }
      _ch = ch;
      _ch!.sink.add(
        jsonEncode({
          'type': 'register',
          'id': deviceId,
          'name': deviceName,
          'avatar': await _avatarBase64(),
          'ver': kProtocolVersion,
        }),
      );
      connected = true;
      _retryCount = 0;
      notifyListeners();
      Log.i('relay', 'connected: $uri');
      _ch!.stream.listen(_onData, onDone: _onLost, onError: (_) => _onLost());
    } catch (e) {
      connected = false;
      notifyListeners();
      Log.e('relay', 'connect $uri failed', e);
      if (!_manualClose) _scheduleReconnect();
    }
  }

  void disconnect() {
    _manualClose = true;
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
    _notify('连接被服务器断开', blockedText(reason));
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
      }
    }
    for (final tid in _incoming.keys.toList()) {
      _closeIncoming(tid, deletePart: false);
    }
    for (final w in _sendWaiters.values) {
      if (!w.isCompleted) w.complete();
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
    final map = <String, Peer>{};
    for (final p in _relayPeers) {
      map[p.id] = Peer(
        id: p.id,
        name: p.name,
        avatar: p.avatar,
        viaRelay: true,
      );
    }
    if (_lanActive) {
      for (final e in _lan.peers.entries) {
        final info = e.value;
        final ex = map[e.key];
        map[e.key] = Peer(
          id: info.id,
          name: ex?.name ?? info.name,
          avatar: ex?.avatar ?? info.avatar,
          viaRelay: ex != null,
          viaLan: true,
        );
      }
    }
    for (final p in map.values) {
      if (oldAvatar[p.id] != p.avatar) _avatarBytesCache.remove(p.id);
    }
    peers = map.values.toList();
    notifyListeners();
  }

  /// 发送控制消息; 对端在局域网内时优先走直连, 连不上回退中继
  void _send(Map<String, dynamic> msg) {
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

  /// 发送二进制文件块; 有直连走直连
  void _sendBinary(String to, Uint8List bytes) {
    final link = _lanActive ? _lan.links[to] : null;
    if (link != null && !link.closed) {
      link.sendBinary(bytes);
      return;
    }
    _ch?.sink.add(bytes);
  }

  /// 到该对端的传输通道是否可用 (直连或中继)
  bool _transportUp(String peerId) =>
      (_lanActive && _lan.links[peerId]?.closed == false) ||
      (_relayActive && connected && _relayIds.contains(peerId));

  /// 局域网直连连续失败计数/退避截止
  final Map<String, int> _lanFailCount = {};
  final Map<String, int> _lanFailUntil = {};

  // ---------- 局域网 ----------

  /// 局域网发现/直连状态文本 (设置页展示)
  String get lanStatusText {
    if (!_lanActive) return '已停用 (仅中继模式)';
    final udp = _lan.udpBound ? 'UDP ${LanManager.udpPort}' : 'UDP 绑定失败';
    final tcp = _lan.boundTcpPort != 0
        ? 'TCP ${_lan.boundTcpPort}'
        : 'TCP 绑定失败';
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

  void _handleData(dynamic data) {
    if (data is String) {
      final m = jsonDecode(data) as Map<String, dynamic>;
      switch (m['type']) {
        case 'blocked':
          _onBlocked(m['reason'] as String? ?? 'kick');
          break;
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
          final ts = m['ts'] as int;
          // 回 ack (无论是否重复都回, 让发送方确认送达)
          _send({'type': 'chat_ack', 'to': from, 'ts': ts});
          // 去重: 同一对端同一 ts 的消息只存一次 (对方可能重发)
          final existing = chats[from];
          if (existing != null && existing.any((e) => e.ts == ts)) {
            notifyListeners();
            break;
          }
          var msg = ChatMessage(
            peerId: from,
            fromMe: false,
            text: m['text'] as String,
            ts: ts,
          );
          ChatDb.insert(msg).then((id) {
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
          });
          chats.putIfAbsent(from, () => []).add(msg);
          // 仅在前台且正在和对方聊天时: 不计未读也不弹系统通知
          if (!(_appForeground && activePeerId == from)) {
            unread[from] = (unread[from] ?? 0) + 1;
            _unreadChanged();
            _notify(peerName(from), m['text'] as String, payload: from);
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
        case 'file_offer':
          final tid = m['transferId'] as String;
          final existing = _find(tid);
          if (existing != null) {
            // 同 transferId 重发 (对方点了"重发"): 复用记录以保留 .part 续传进度
            if (!existing.outgoing &&
                (existing.status == TransferStatus.failed ||
                    existing.status == TransferStatus.canceled)) {
              existing.status = TransferStatus.waiting;
              ChatDb.upsertTransfer(existing);
              if (isTrusted(existing.peerId)) {
                // 信任设备: 自动续传, 不再询问
                Log.i(
                  'transfer',
                  'auto-resume ${existing.fileName} from trusted ${existing.peerId}',
                );
                unawaited(acceptFile(existing));
              } else {
                _fileOfferCtrl.add(existing);
                if (!(_appForeground && activePeerId == existing.peerId)) {
                  _notify(
                    peerName(existing.peerId),
                    '向您发送文件: ${existing.fileName}',
                    payload: existing.peerId,
                  );
                }
              }
            }
            break;
          }
          final t = FileTransfer(
            transferId: tid,
            peerId: m['from'],
            fileName: m['name'],
            fileSize: m['size'],
            outgoing: false,
          );
          transfers.add(t);
          ChatDb.upsertTransfer(t);
          // 保证会话出现在消息列表 (纯文件会话没有文字消息)
          chats.putIfAbsent(t.peerId, () => []);
          if (isTrusted(t.peerId)) {
            // 信任设备: 自动接受 (断点续传逻辑在 acceptFile 内)
            Log.i(
              'transfer',
              'auto-accept ${t.fileName} from trusted ${t.peerId}',
            );
            unawaited(acceptFile(t));
            if (!(_appForeground && activePeerId == t.peerId)) {
              unread[t.peerId] = (unread[t.peerId] ?? 0) + 1;
              _unreadChanged();
              _notify(
                peerName(t.peerId),
                '正在自动接收: ${t.fileName}',
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
              '向您发送文件: ${t.fileName}',
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
              var offset = m['offset'] as int? ?? 0;
              if (offset < 0 || offset > t.fileSize) offset = 0;
              t.status = TransferStatus.accepted;
              ChatDb.upsertTransfer(t);
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
          final t = _find(m['transferId']);
          if (t != null) {
            t.status = TransferStatus.rejected;
            ChatDb.upsertTransfer(t);
            _cleanupTemp(t);
          }
          break;
        case 'file_progress':
          // 接收端回执: 更新已确认字节数, 唤醒背压等待
          final tid = m['transferId'] as String;
          final bytes = m['bytes'] as int? ?? 0;
          if (bytes > (_sendAcked[tid] ?? 0)) _sendAcked[tid] = bytes;
          final w = _sendWaiters.remove(tid);
          if (w != null && !w.isCompleted) w.complete();
          break;
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
            }
          }
          break;
        case 'file_cancel':
          final t = _find(m['transferId']);
          if (t != null) _remoteCancel(t);
          break;
        case 'file_done':
          final t = _find(m['transferId']);
          if (t != null && !t.outgoing) {
            _finishIncoming(t, sha256: m['sha256'] as String?);
          }
          break;
      }
      notifyListeners();
    } else if (data is List<int>) {
      // 二进制文件块
      final bytes = Uint8List.fromList(data);
      final tid = utf8.decode(bytes.sublist(0, 36));
      final chunk = bytes.sublist(36);
      final t = _find(tid);
      final sink = _incoming[tid];
      if (t == null || sink == null) return;
      sink.add(chunk);
      _recvHash[tid]?.input.add(chunk);
      t.bytesDone += chunk.length;
      t.sampleSpeed();
      if (t.status == TransferStatus.accepted ||
          t.status == TransferStatus.waiting) {
        t.status = TransferStatus.transferring;
      }
      // 流控回执: 每收 2MB 汇报一次, 发送端据此控制发送窗口
      if (t.bytesDone - (_recvAcked[tid] ?? 0) >= 2 * 1024 * 1024) {
        _recvAcked[tid] = t.bytesDone;
        _send({
          'type': 'file_progress',
          'to': t.peerId,
          'transferId': tid,
          'bytes': t.bytesDone,
        });
      }
      if (t.bytesDone - _lastNotifyBytes >= 256 * 1024) {
        // 节流: 每 256KB 才通知一次, 避免整个 UI 每 64KB 重建导致头像闪烁
        _lastNotifyBytes = t.bytesDone;
        notifyListeners();
      }
    }
  }

  FileTransfer? _find(String tid) {
    for (final t in transfers) {
      if (t.transferId == tid) return t;
    }
    return null;
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
          final w = _sendWaiters.remove(t.transferId);
          if (w != null && !w.isCompleted) w.complete();
          // 还在队列里未启动的: 发送循环不会跑到, 直接出队标记失败
          if ((_sendQueue[t.peerId] ?? const []).contains(t.transferId)) {
            _sendQueue[t.peerId]!.remove(t.transferId);
            _queuedOffsets.remove(t.transferId);
            _aborted.remove(t.transferId);
            t.status = TransferStatus.failed;
            ChatDb.upsertTransfer(t);
            Log.i('transfer', 'queued ${t.fileName} failed (peer offline)');
          }
        } else {
          _closeIncoming(t.transferId, deletePart: false);
          t.status = TransferStatus.failed;
          ChatDb.upsertTransfer(t);
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
    if ((unread[peerId] ?? 0) != 0) {
      unread[peerId] = 0;
      _unreadChanged();
    }
    notifyListeners();
    return h;
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
    // 防重: 拼接期间可能刚好有新消息进来
    final existing = list.map((m) => m.ts).toSet();
    final fresh = older.where((m) => !existing.contains(m.ts)).toList();
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
    // 未完成的临时文件始终清掉
    if (t.savePath != null) {
      try {
        final part = File('${t.savePath}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    _cleanupTemp(t);
    transfers.remove(t);
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

  /// 外发临时文件 (zip 等) 在传输终结后删除; 失败状态保留以便重试
  void _cleanupTemp(FileTransfer t) {
    if (!t.outgoing || t.savePath == null) return;
    if (_tempSendPaths.remove(t.savePath)) {
      File(t.savePath!).delete().catchError((_) => File(''));
    }
  }

  // ---------- 文件 ----------
  String? _downloadDirOverride; // 用户自定义保存目录

  Future<String> downloadDir() async {
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
    await ZipFileEncoder().zipDirectory(Directory(dirPath), filename: zipPath);
    return zipPath;
  }

  /// 发送文件请求; 对方不在线时返回 false, 不创建记录
  /// isTemp: 发送用临时文件, 传输终结后自动删除 (如文件夹 zip)
  /// displayName: 对方看到的文件名 (默认取路径 basename)
  Future<bool> sendFile(
    String to,
    String path, {
    bool isTemp = false,
    String? displayName,
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
    if (isTemp) _tempSendPaths.add(path);
    transfers.add(t);
    ChatDb.upsertTransfer(t);
    _send({
      'type': 'file_offer',
      'to': to,
      'transferId': tid,
      'name': t.fileName,
      'size': size,
    });
    notifyListeners();
    // waiting 超时: 60 秒无响应标记失败
    Timer(const Duration(seconds: 60), () {
      if (t.status == TransferStatus.waiting && transfers.contains(t)) {
        t.status = TransferStatus.failed;
        ChatDb.upsertTransfer(t);
        notifyListeners();
      }
    });
    return true;
  }

  Future<void> _startSend(FileTransfer t, int offset) async {
    final tid = t.transferId;
    _canceled.remove(tid);
    _aborted.remove(tid);
    t.status = TransferStatus.transferring;
    t.bytesDone = offset;
    _sendAcked[tid] = offset;
    _lastNotifyBytes = offset;
    notifyListeners();
    // 通道参数: 局域网直连块大窗口大, 中继保守 (服务器按帧转发有开销)
    final viaLan = _lanActive && _lan.links[t.peerId]?.closed == false;
    final chunkSize = viaLan ? 256 * 1024 : 64 * 1024;
    var window = viaLan ? 16 * 1024 * 1024 : 8 * 1024 * 1024;
    final windowCap = viaLan ? 128 * 1024 * 1024 : 32 * 1024 * 1024;
    var waitMs = 0; // 累计被窗口卡住的时间
    var evalAt =
        DateTime.now().millisecondsSinceEpoch + 2000; // 下次评估窗口的时间点
    Log.i(
      'transfer',
      'send start ${t.fileName} -> ${t.peerId} '
          '(${viaLan ? "lan" : "relay"}, offset=$offset)',
    );
    RandomAccessFile? raf;
    try {
      final hash = _HashState();
      raf = await File(t.savePath!).open();
      if (offset > 0) {
        // 哈希需覆盖整个文件: 先把已发送的部分喂进哈希
        await for (final chunk in File(t.savePath!).openRead(0, offset)) {
          hash.input.add(chunk);
        }
        await raf.setPosition(offset);
      }
      final tidBytes = ascii.encode(tid);
      while (true) {
        while (t.bytesDone - (_sendAcked[tid] ?? 0) >= window) {
          // 窗口满: 等接收端 file_progress 回执
          if (_canceled.contains(tid) ||
              _aborted.contains(tid) ||
              !_transportUp(t.peerId)) {
            throw StateError('aborted');
          }
          final before = _sendAcked[tid] ?? 0;
          final w = Completer<void>();
          _sendWaiters[tid] = w;
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
            _sendWaiters.remove(tid);
          }
          waitMs += DateTime.now().millisecondsSinceEpoch - waitStart;
        }
        if (_canceled.contains(tid) ||
            _aborted.contains(tid) ||
            !_transportUp(t.peerId)) {
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
        hash.input.add(chunk);
        final b = BytesBuilder()
          ..add(tidBytes)
          ..add(chunk);
        _sendBinary(t.peerId, b.toBytes());
        t.bytesDone += chunk.length;
        t.sampleSpeed();
        if (t.bytesDone - _lastNotifyBytes >= 1024 * 1024) {
          _lastNotifyBytes = t.bytesDone;
          notifyListeners();
        }
      }
      hash.input.close();
      t.status = TransferStatus.done; // 发送完成; 校验失败会被 file_result 改判
      _send({
        'type': 'file_done',
        'to': t.peerId,
        'transferId': tid,
        'sha256': hash.hex,
        'size': t.bytesDone,
      });
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
      }
    } finally {
      await raf?.close();
      _aborted.remove(tid);
      _sendAcked.remove(tid);
      final w = _sendWaiters.remove(tid);
      if (w != null && !w.isCompleted) w.complete();
      _sendingPeers.remove(t.peerId);
      _pumpSendQueue(t.peerId); // 本对端队列里的下一个接着发
    }
    ChatDb.upsertTransfer(t);
    notifyListeners();
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

  /// 接受文件; 若已有 .part 临时文件则从其长度偏移处续传
  Future<void> acceptFile(FileTransfer t) async {
    var save = t.savePath;
    if (save == null) {
      final dir = await downloadDir();
      var candidate = '$dir${Platform.pathSeparator}${t.fileName}';
      var i = 1;
      while (await File(candidate).exists() ||
          await File('$candidate.part').exists()) {
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
      offset = await part.length();
      if (offset < 0 || offset > t.fileSize) {
        // 临时文件异常, 重头再来
        try {
          await part.delete();
        } catch (_) {}
        offset = 0;
      }
    }
    final hash = _HashState();
    if (offset > 0) {
      // 续传: 已收部分也要计入哈希, 才能和发送端整文件哈希对齐
      await for (final chunk in part.openRead()) {
        hash.input.add(chunk);
      }
    }
    _canceled.remove(t.transferId);
    _recvHash[t.transferId] = hash;
    _recvAcked[t.transferId] = offset;
    _incoming[t.transferId] = part.openWrite(mode: FileMode.append);
    t.bytesDone = offset;
    _lastNotifyBytes = offset;
    t.status = TransferStatus.accepted;
    ChatDb.upsertTransfer(t);
    _send({
      'type': 'file_accept',
      'to': t.peerId,
      'transferId': t.transferId,
      'offset': offset,
    });
    notifyListeners();
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
    final w = _sendWaiters.remove(t.transferId);
    if (w != null && !w.isCompleted) w.complete();
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
    final w = _sendWaiters.remove(t.transferId);
    if (w != null && !w.isCompleted) w.complete();
    _closeIncoming(t.transferId, deletePart: true);
    t.status = TransferStatus.canceled;
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
    });
    notifyListeners();
    Timer(const Duration(seconds: 60), () {
      if (t.status == TransferStatus.waiting && transfers.contains(t)) {
        t.status = TransferStatus.failed;
        ChatDb.upsertTransfer(t);
        notifyListeners();
      }
    });
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
    final sink = _incoming.remove(tid);
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    _recvHash.remove(tid);
    _recvAcked.remove(tid);
    if (deletePart) {
      final t = _find(tid);
      if (t?.savePath != null) {
        try {
          final part = File('${t!.savePath}.part');
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }

  /// 收到 file_done: 校验字节数和 SHA-256, 通过则 .part 改名为正式文件
  Future<void> _finishIncoming(FileTransfer t, {String? sha256}) async {
    final tid = t.transferId;
    final hash = _recvHash[tid];
    hash?.input.close();
    await _closeIncoming(tid, deletePart: false);
    var ok = t.bytesDone == t.fileSize;
    if (ok && sha256 != null && sha256.isNotEmpty) {
      ok = hash?.hex == sha256;
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
      // 数据不可信: 删掉 .part, 重试时从头再来
      Log.e(
        'transfer',
        'recv verify failed ${t.fileName} '
            '(${t.bytesDone}/${t.fileSize}B, sha match: ${sha256 == null ? "n/a" : (hash?.hex == sha256)})',
      );
      t.bytesDone = 0;
      if (t.savePath != null) {
        try {
          final part = File('${t.savePath}.part');
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
    t.status = ok ? TransferStatus.done : TransferStatus.failed;
    if (ok) {
      Log.i('transfer', 'recv done ${t.fileName} (${t.bytesDone}B)');
    }
    ChatDb.upsertTransfer(t);
    _send({'type': 'file_result', 'to': t.peerId, 'transferId': tid, 'ok': ok});
    notifyListeners();
  }

  String peerName(String id) => peers
      .firstWhere(
        (p) => p.id == id,
        orElse: () => Peer(id: id, name: id.substring(0, 8)),
      )
      .name;

  bool isOnline(String id) => peers.any((p) => p.id == id);

  /// 对端头像 (base64 PNG), 无则 null
  String? peerAvatar(String id) {
    for (final p in peers) {
      if (p.id == id) return p.avatar;
    }
    return null;
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
}

/// 流式 SHA-256: 边传边算, 结束后取 hex
class _HashState {
  Digest? _digest;
  late final ByteConversionSink input = sha256.startChunkedConversion(
    _DigestSink((d) => _digest = d),
  );

  String? get hex => _digest?.toString();
}

class _DigestSink implements Sink<Digest> {
  final void Function(Digest) onDigest;
  _DigestSink(this.onDigest);

  @override
  void add(Digest event) => onDigest(event);

  @override
  void close() {}
}
