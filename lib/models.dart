/// 协议版本号: register / 局域网宣告 / hello 均携带, 便于将来协议升级时识别对端
const int kProtocolVersion = 1;

class Peer {
  final String id;
  final String name;
  final String? avatar; // base64 PNG (96x96)
  final bool viaLan; // 局域网发现
  final bool viaRelay; // 中继服务器在线
  Peer({
    required this.id,
    required this.name,
    this.avatar,
    this.viaLan = false,
    this.viaRelay = false,
  });

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Unknown',
    avatar: j['avatar'] as String?,
    viaRelay: true,
  );
}

enum TransferStatus {
  waiting,
  accepted,
  transferring,
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
