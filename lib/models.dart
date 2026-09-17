class Peer {
  final String id;
  final String name;
  final String? avatar; // base64 PNG (96x96)
  Peer({required this.id, required this.name, this.avatar});

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Unknown',
    avatar: j['avatar'] as String?,
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
}
