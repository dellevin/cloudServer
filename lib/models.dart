/// 协议版本号: register / 局域网宣告 / hello 均携带, 便于将来协议升级时识别对端
/// v2: register 支持接入密码 key; 支持 P2P 打洞信令 (p2p_*)
/// v3: 支持 E2EE 信封消息 (enc; 仅当双方都 v3+ 且设置了接入密码时启用)
/// v4: 大文件增强 (file_offer/file_accept 带 v2 标志协商): 分片哈希续传
/// (file_seg_hash)、秒传 (file_instant)、局域网并行车道 (file_parallel)
/// v5: 远程视频流式预览 (fs_stream_open/req/skip/close): 播放器按需拉取
/// 字节区间 (Range), 稀疏缓存 + 本地 HTTP 映射, 任意拖动/moov 后置可播
const int kProtocolVersion = 5;

class Peer {
  final String id;
  final String name;
  final String? avatar; // base64 JPEG (96x96; 旧版本为 PNG, 解码端自适应)
  final String? platform; // windows / android / linux / macos / ios (旧版未上报为 null)
  final bool viaLan; // 局域网发现 (或已建立 P2P 直连)
  final bool viaRelay; // 中继服务器在线
  final int ver; // 对端协议版本 (0 = 旧版未上报)
  Peer({
    required this.id,
    required this.name,
    this.avatar,
    this.platform,
    this.viaLan = false,
    this.viaRelay = false,
    this.ver = 0,
  });

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Unknown',
    avatar: j['avatar'] as String?,
    platform: j['platform'] as String?,
    viaRelay: true,
    ver: j['ver'] as int? ?? 0,
  );
}

enum TransferStatus {
  waiting,
  accepted,
  transferring,

  /// 收齐后合并+校验中 (大文件可达数分钟): 无分块到达但绝非停滞,
  /// 停滞看门狗/断线清理都不得动它 (状态按 name 持久化, 新增安全)
  verifying,
  done,
  rejected,
  failed,
  canceled,
}

class FileTransfer {
  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
  final bool outgoing;
  final int ts;
  TransferStatus status;
  int bytesDone;
  String? savePath;

  /// 瞬态: 远程浏览页「预览」拉取的临时传输 — 存缓存目录、不入库、
  /// 不出现在聊天/传输记录 UI, 重启即弃
  bool ephemeral = false;

  /// 瞬态: 剪贴板同步的传输 — 接收侧存「下载目录/cloudSend/clipboard」,
  /// 完成后写入 clip_items 记录 (剪贴板页展示, 不进传输记录)
  bool clipboard = false;

  FileTransfer({
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
    required this.outgoing,
    int? ts,
    this.status = TransferStatus.waiting,
    this.bytesDone = 0,
    this.savePath,
  }) : ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  double get progress => fileSize == 0 ? 0 : bytesDone / fileSize;

  // ---- 瞬态: 实时速度采样 (不持久化) ----

  /// 平滑后的传输速度 (字节/秒), 0 = 未知
  double speedBps = 0;
  int _spLastBytes = 0;
  int _spLastTs = 0;

  /// 进度推进时采样一次, 用 EMA 平滑瞬时速率 (采样间隔 <300ms 忽略)
  void sampleSpeed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_spLastTs == 0) {
      _spLastTs = now;
      _spLastBytes = bytesDone;
      return;
    }
    final dt = now - _spLastTs;
    if (dt < 300) return;
    final inst = (bytesDone - _spLastBytes) * 1000.0 / dt;
    if (inst >= 0) {
      speedBps = speedBps == 0 ? inst : speedBps * 0.6 + inst * 0.4;
    }
    _spLastTs = now;
    _spLastBytes = bytesDone;
  }

  /// 预计剩余秒数 (速度未知或已传完时为 null)
  double? get etaSeconds => speedBps > 0 && bytesDone < fileSize
      ? (fileSize - bytesDone) / speedBps
      : null;
}
