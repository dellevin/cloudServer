import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// 局域网发现 + 直连传输:
///  - UDP 广播 (端口 45677): 每 5s 宣告 {id,name,avatar,tcpPort,ver,platform},
///    超过 15s 未收到宣告则判定下线
///  - TCP 服务 (端口 45678): 需要向对方发消息时按需连接, 首帧为 hello 握手
///  - 帧格式: 1 字节类型 (0=JSON 文本, 1=二进制) + 4 字节大端长度 + 负载
///
/// 中继协议的控制消息 (chat / file_* 等) 和 36 字节 transferId 前缀的
/// 二进制块原样复用在该通道上, 由 RelayClient 统一处理
class LanPeerInfo {
  final String id;
  String name;
  String? avatar;
  String? platform; // windows / android / ... (旧版未上报为 null)
  InternetAddress addr;
  int tcpPort;
  int lastSeen; // 毫秒时间戳
  bool manual; // 手动添加的设备: 不过期
  String? manualTarget; // 手动添加时输入的 "ip:port" (用于删除/重连)
  int ver; // 对端协议版本 (0 = 旧版未上报)

  LanPeerInfo({
    required this.id,
    required this.name,
    this.avatar,
    this.platform,
    required this.addr,
    required this.tcpPort,
    required this.lastSeen,
    this.manual = false,
    this.manualTarget,
    this.ver = 0,
  });
}

/// 一条 TCP 直连通道 (带长度前缀帧)
class LanLink {
  final Socket _socket;
  final bool inbound; // true=对方连入, false=我方发起
  String? peerId;
  bool closed = false;
  int? remotePort; // 我方连出时对方的服务端口
  bool manual = false; // 由「手动添加」发起
  String? manualTarget;
  bool isP2p = false; // 经中继信令打洞建立的跨网段直连
  bool isLane = false; // 大文件并行传输的车道连接 (不进 links, 不参与单链接收敛)
  Completer<String>? greeted; // 握手完成时补上 peerId (手动连接流程用)

  void Function(dynamic frame)? onFrame; // String (JSON) 或 Uint8List (二进制)
  void Function()? onClosed;

  Uint8List _pending = Uint8List(0);

  // 单帧长度上限: 文件块 256KB + 36B 头, JSON 含 base64 头像/目录列表,
  // 16MB 留足余量; 超限即视为恶意/故障对端, 直接断连防 _pending 无限累积 OOM
  static const int maxFrameLen = 16 * 1024 * 1024;

  LanLink(this._socket, {required this.inbound, this.peerId}) {
    _socket.listen(
      _onData,
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
  }

  InternetAddress get remoteAddr => _socket.remoteAddress;

  void _onData(Uint8List data) {
    _pending = Uint8List.fromList([..._pending, ...data]);
    while (_pending.length >= 5) {
      final kind = _pending[0];
      final len = ByteData.sublistView(_pending, 1, 5).getUint32(0);
      if (len > maxFrameLen) {
        close();
        return;
      }
      if (_pending.length < 5 + len) break;
      final payload = Uint8List.sublistView(_pending, 5, 5 + len);
      _pending = Uint8List.sublistView(_pending, 5 + len);
      if (closed) return;
      // 畸形帧 (非 UTF-8 文本/处理异常) 不应抛进 zone 使宿主崩溃:
      // 关闭这条不可信的连接, 发送方自然回退到中继通道
      try {
        onFrame?.call(kind == 0 ? utf8.decode(payload) : payload);
      } catch (_) {
        close();
        return;
      }
    }
  }

  void sendJson(Map<String, dynamic> msg) =>
      _send(0, utf8.encode(jsonEncode(msg)));

  void sendBinary(Uint8List bytes) => _send(1, bytes);

  void _send(int kind, List<int> payload) {
    if (closed) return;
    final header = ByteData(5)
      ..setUint8(0, kind)
      ..setUint32(1, payload.length);
    final b = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(payload);
    try {
      _socket.add(b.toBytes());
    } catch (_) {
      close();
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    try {
      _socket.destroy();
    } catch (_) {}
    onClosed?.call();
  }
}

/// 局域网设备发现与直连管理
class LanManager {
  static const int udpPort = 45677;
  static const int tcpPort = 45678;
  static const Duration announceInterval = Duration(seconds: 5);
  static const Duration expireAfter = Duration(seconds: 15);
  // 单个 UDP 数据报不宜过大, 头像 base64 超长时宣告里不带头像
  static const int maxAvatarLen = 16000;

  final String deviceId;
  final String Function() getName;
  final Future<String?> Function() getAvatarB64;

  /// TCP 服务监听端口 (默认 45678; 测试同机多实例时可覆盖)
  final int tcpServerPort;

  /// 发现的局域网设备增删或资料变化时回调
  void Function()? onPeersChanged;

  /// 已握手连接的非 hello 帧回调 (交 RelayClient._onData 处理)
  void Function(dynamic frame)? onFrame;

  /// 某对端的直连断开时回调
  void Function(String peerId)? onLinkClosed;

  /// 车道连接的非 hello 帧回调 (大文件并行传输的数据通道)
  void Function(LanLink link, dynamic frame)? onLaneFrame;

  /// 车道连接断开时回调
  void Function(LanLink link)? onLaneClosed;

  /// 拉黑拦截 (由 RelayClient 注入): 返回 true 时
  /// 拒绝该 IP 的 TCP 接入与 UDP 宣告
  bool Function(String ip)? shouldBlockIp;

  /// P2P 打洞握手校验 (由 RelayClient 注入): hello 带 p2p/token 字段时
  /// 回调校验是否为进行中的打洞会话, 返回 false 则连接被拒绝
  bool Function(LanLink link, Map<String, dynamic> hello)? validateP2pHello;

  final Map<String, LanPeerInfo> peers = {};
  final Map<String, LanLink> links = {};

  /// 本机接口地址 (用于识别 NAT 泄漏回来的宣告包, 定期刷新)
  Set<String> _ownAddrs = {'127.0.0.1'};

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _timer;
  int _actualTcpPort = 0;
  String? _lastAvatar; // 最近一次宣告用的头像 (hello 同步发送, 用缓存保证首帧顺序)
  final Map<String, Future<LanLink?>> _connecting = {};

  /// UDP 发现是否绑定成功 (false 时无法广播/收听宣告)
  bool get udpBound => _udp != null;

  /// TCP 服务实际监听端口 (0 = 绑定失败, 只能发起连接)
  int get boundTcpPort => _actualTcpPort;

  LanManager({
    required this.deviceId,
    required this.getName,
    required this.getAvatarB64,
    this.tcpServerPort = tcpPort,
  });

  Future<void> start() async {
    try {
      // 不用 shared: 避免多实例同时监听同端口时连接被错误分发
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpServerPort);
      _actualTcpPort = _server!.port;
      _server!.listen(_onAccept);
    } catch (_) {}
    try {
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: true,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdpEvent);
    } catch (_) {}
    unawaited(_announce());
    unawaited(_refreshOwnAddrs());
    _timer = Timer.periodic(announceInterval, (_) => _tick());
  }

  /// 刷新本机接口地址集合
  Future<void> _refreshOwnAddrs() async {
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
      _ownAddrs = {
        '127.0.0.1',
        for (final i in ifs) ...i.addresses.map((a) => a.address),
      };
    } catch (_) {}
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _udp?.close();
    await _server?.close();
    for (final l in links.values.toList()) {
      l.close();
    }
  }

  // ---------- 发现 (UDP 广播) ----------

  /// 立即广播一次自身 (下拉刷新用, 不等下个 5s 周期)
  Future<void> announceNow() => _announce();

  Future<void> _announce() async {
    var avatar = await getAvatarB64();
    if (avatar != null && avatar.length > maxAvatarLen) avatar = null;
    _lastAvatar = avatar;
    final udp = _udp;
    if (udp == null) return;
    final payload = utf8.encode(
      jsonEncode({
        'id': deviceId,
        'name': getName(),
        'avatar': avatar,
        'tcpPort': _actualTcpPort,
        'ver': kProtocolVersion,
        'platform': Platform.operatingSystem,
      }),
    );
    try {
      udp.send(payload, InternetAddress('255.255.255.255'), udpPort);
    } catch (_) {}
  }

  void _tick() {
    unawaited(_announce());
    unawaited(_refreshOwnAddrs());
    final now = DateTime.now().millisecondsSinceEpoch;
    // 手动添加的设备不过期; 有活跃连接的设备以连接为准不过期
    final expired = peers.entries
        .where(
          (e) =>
              !e.value.manual &&
              !links.containsKey(e.key) &&
              now - e.value.lastSeen > expireAfter.inMilliseconds,
        )
        .map((e) => e.key)
        .toList();
    if (expired.isEmpty) return;
    for (final id in expired) {
      peers.remove(id);
    }
    onPeersChanged?.call();
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udp?.receive();
    if (dg == null) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = m['id'];
    if (id is! String || id.isEmpty || id == deviceId) return;
    // 拉黑的 IP: 宣告直接忽略 (对端不会出现在设备列表)
    if (shouldBlockIp?.call(dg.address.address) == true) return;
    // NAT 泄漏回来的宣告 (如 Android 模拟器): 源地址被 NAT 改写成宿主机
    // 自己的地址, 按此地址反连只会连到自己/不可达, 必须忽略
    if (_ownAddrs.contains(dg.address.address)) return;
    try {
      _upsertPeer(
        id,
        name: m['name'] as String? ?? 'Unknown',
        avatar: m['avatar'] as String?,
        addr: dg.address,
        tcpPort: m['tcpPort'] as int? ?? 0,
        ver: m['ver'] as int? ?? 0,
        platform: m['platform'] as String?,
      );
    } catch (_) {
      // 字段类型不符的畸形宣告直接忽略
    }
  }

  void _upsertPeer(
    String id, {
    required String name,
    String? avatar,
    String? platform,
    required InternetAddress addr,
    required int tcpPort,
    bool manual = false,
    String? manualTarget,
    int ver = 0,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (peers[id] == null) {
      peers[id] = LanPeerInfo(
        id: id,
        name: name,
        avatar: avatar,
        platform: platform,
        addr: addr,
        tcpPort: tcpPort,
        lastSeen: now,
        manual: manual,
        manualTarget: manualTarget,
        ver: ver,
      );
      onPeersChanged?.call();
      return;
    }
    final old = peers[id]!;
    final changed =
        old.name != name ||
        old.avatar != avatar ||
        old.tcpPort != tcpPort ||
        (platform != null && old.platform != platform) ||
        (manual && !old.manual);
    old.name = name;
    if (avatar != null) old.avatar = avatar;
    if (platform != null) old.platform = platform;
    old.addr = addr;
    if (tcpPort != 0) old.tcpPort = tcpPort;
    if (ver != 0) old.ver = ver;
    old.lastSeen = now;
    if (manual) {
      old.manual = true;
      old.manualTarget = manualTarget ?? old.manualTarget;
    }
    if (changed) onPeersChanged?.call();
  }

  // ---------- 直连 (TCP) ----------

  void _onAccept(Socket socket) {
    // 拉黑的 IP: 连接直接断开, 不回复握手
    if (shouldBlockIp?.call(socket.remoteAddress.address) == true) {
      socket.destroy();
      return;
    }
    final link = LanLink(socket, inbound: true);
    _wireLink(link);
    _sendHello(link);
  }

  void _wireLink(LanLink link) {
    link.onFrame = (frame) => _handleFrame(link, frame);
    link.onClosed = () => _onLinkClosed(link);
    // 10s 内未完成握手 (对方不是 cloudSend) 的连接关闭
    Timer(const Duration(seconds: 10), () {
      if (link.peerId == null && !link.closed) link.close();
    });
  }

  void _sendHello(LanLink link, {Map<String, dynamic>? extra}) {
    link.sendJson({
      'type': 'hello',
      'id': deviceId,
      'name': getName(),
      'avatar': _lastAvatar,
      'ver': kProtocolVersion,
      'platform': Platform.operatingSystem,
      ...?extra,
    });
  }

  /// 收养一条打洞成功的 socket (由 RelayClient 的打洞流程调用):
  /// 接线、登记并发送带 p2p 凭证的 hello (对端据此校验放行)
  void adoptP2pLink(LanLink link, String peerId, String sid, String token) {
    link.isP2p = true;
    link.peerId = peerId;
    _wireLink(link);
    _register(link, peerId);
    _sendHello(link, extra: {'p2p': sid, 'token': token});
  }

  void _handleFrame(LanLink link, dynamic frame) {
    if (frame is String) {
      Map<String, dynamic>? m;
      try {
        m = jsonDecode(frame) as Map<String, dynamic>;
      } catch (_) {}
      if (m == null) return;
      if (m['type'] == 'hello') {
        _onHello(link, m);
        return;
      }
      if (link.peerId == null) {
        link.close(); // 未握手先说话, 协议违规
        return;
      }
      // 车道帧原样上交 (控制消息只走主链路, 车道上正常只有二进制块)
      if (link.isLane) {
        onLaneFrame?.call(link, jsonEncode(m));
        return;
      }
      // 直连没有服务器注入 from, 用连接对端身份补上 (强制覆盖, 防伪造)
      m['from'] = link.peerId;
      onFrame?.call(jsonEncode(m));
    } else {
      if (link.peerId == null) return;
      if (link.isLane) {
        onLaneFrame?.call(link, frame);
        return;
      }
      onFrame?.call(frame);
    }
  }

  void _onHello(LanLink link, Map<String, dynamic> m) {
    final id = m['id'] as String?;
    if (id == null || id.isEmpty || id == deviceId) {
      link.close();
      return;
    }
    // P2P 打洞握手: 必须由 RelayClient 校验会话凭证, 不是打洞方一律拒绝
    if (m['p2p'] is String) {
      link.isP2p = true;
      if (validateP2pHello?.call(link, m) != true) {
        link.close();
        return;
      }
    }
    // 车道连接: 对方 hello 声明 lane, 或我方 dialLane 拨出时已标记;
    // 只补 peerId 完成握手, 不更新 peers、不进 links、不参与单链接收敛
    if (m['lane'] == true) link.isLane = true;
    if (link.isLane) {
      link.peerId = id;
      if (link.greeted?.isCompleted == false) link.greeted!.complete(id);
      return;
    }
    // 拉黑的设备不断开链路: 其消息在 RelayClient._onData 按类型拦截并回拒收,
    // 链路保留拒收回执 (chat_reject/file_reject) 才能送达对方
    if (link.inbound) {
      // 对方连入: 借握手更新资料 (UDP 被拦时也能发现彼此)
      _upsertPeer(
        id,
        name: m['name'] as String? ?? 'Unknown',
        avatar: m['avatar'] as String?,
        addr: link.remoteAddr,
        tcpPort: 0, // 反连端口未知, 保留宣告里的值
        ver: m['ver'] as int? ?? 0,
        platform: m['platform'] as String?,
      );
    } else {
      // 我方连出: 用已知的对端地址/端口 (手动连接时即输入的地址)
      _upsertPeer(
        id,
        name: m['name'] as String? ?? 'Unknown',
        avatar: m['avatar'] as String?,
        addr: peers[id]?.addr ?? link.remoteAddr,
        tcpPort: link.remotePort ?? peers[id]?.tcpPort ?? 0,
        manual: link.manual,
        manualTarget: link.manualTarget,
        ver: m['ver'] as int? ?? 0,
        platform: m['platform'] as String?,
      );
    }
    _register(link, id);
    if (link.greeted?.isCompleted == false) link.greeted!.complete(id);
  }

  /// 注册连接; 双方同时发起连接时只保留一条:
  /// 保留发起方 id 较大的那条 (两端按同一规则收敛)
  void _register(LanLink link, String peerId) {
    bool connectorIsLarger(LanLink l) => l.inbound
        ? peerId.compareTo(deviceId) > 0
        : deviceId.compareTo(peerId) > 0;
    final old = links[peerId];
    if (old != null && old != link && !old.closed) {
      if (connectorIsLarger(old) && !connectorIsLarger(link)) {
        link.close();
        return;
      }
      old.close();
    }
    link.peerId = peerId;
    links[peerId] = link;
  }

  void _onLinkClosed(LanLink link) {
    if (link.isLane) {
      onLaneClosed?.call(link); // 车道不进 links, 单独通知
      return;
    }
    final pid = link.peerId;
    if (pid != null && identical(links[pid], link)) {
      links.remove(pid);
      onLinkClosed?.call(pid);
    }
  }

  /// 取已有连接, 没有则按发现到的地址发起连接; 失败返回 null
  Future<LanLink?> ensureLink(String peerId) {
    final existing = links[peerId];
    if (existing != null && !existing.closed) return Future.value(existing);
    return _connecting.putIfAbsent(peerId, () => _connect(peerId));
  }

  /// 手动连接指定地址 (「手动添加设备」入口); 返回握手得到的对端 id,
  /// 连接失败或对方不是 cloudSend 返回 null
  Future<String?> connectTo(
    InternetAddress addr,
    int port, {
    String? manualTarget,
  }) async {
    // 拉黑的 IP 不主动发起连接 (手动目标里躺着被拉黑地址时也不再重试)
    if (shouldBlockIp?.call(addr.address) == true) return null;
    try {
      final socket = await Socket.connect(
        addr,
        port,
        timeout: const Duration(seconds: 3),
      );
      final link = LanLink(socket, inbound: false)
        ..remotePort = port
        ..manual = manualTarget != null
        ..manualTarget = manualTarget
        ..greeted = Completer<String>();
      _wireLink(link);
      _sendHello(link);
      try {
        final id = await link.greeted!.future.timeout(
          const Duration(seconds: 4),
        );
        return id.isEmpty ? null : id; // 空串 = 被对方/黑名单拒绝
      } on TimeoutException {
        link.close(); // 对方不是 cloudSend
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// 为并行传输拨一条车道连接: 复用发现的地址直连, hello 带 lane 标记,
  /// 不进 links 不参与收敛; 对端不是 v2 / 失败返回 null (调用方退化为单链接)
  Future<LanLink?> dialLane(String peerId) async {
    final info = peers[peerId];
    if (info == null || info.tcpPort == 0) return null;
    if (shouldBlockIp?.call(info.addr.address) == true) return null;
    try {
      final socket = await Socket.connect(
        info.addr,
        info.tcpPort,
        timeout: const Duration(seconds: 3),
      );
      final link = LanLink(socket, inbound: false)
        ..isLane = true
        ..remotePort = info.tcpPort
        ..greeted = Completer<String>();
      _wireLink(link);
      _sendHello(link, extra: {'lane': true});
      try {
        final id = await link.greeted!.future.timeout(
          const Duration(seconds: 4),
        );
        if (id != peerId) {
          link.close(); // 握出的不是目标对端, 不可用于该传输
          return null;
        }
        return link;
      } on TimeoutException {
        link.close();
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  Future<LanLink?> _connect(String peerId) async {
    try {
      final info = peers[peerId];
      if (info == null || info.tcpPort == 0) return null;
      if (shouldBlockIp?.call(info.addr.address) == true) return null;
      final socket = await Socket.connect(
        info.addr,
        info.tcpPort,
        timeout: const Duration(seconds: 3),
      );
      final link = LanLink(socket, inbound: false, peerId: peerId)
        ..remotePort = info.tcpPort
        ..manual = info.manual
        ..manualTarget = info.manualTarget;
      _wireLink(link);
      _register(link, peerId);
      _sendHello(link);
      return link.closed ? null : link;
    } catch (_) {
      return null;
    } finally {
      _connecting.remove(peerId);
    }
  }
}
