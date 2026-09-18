import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models.dart';

class ChatMessage {
  final int? id;
  final String peerId;
  final bool fromMe;
  final String text;
  final int ts;

  /// 仅对 fromMe=true 有意义: 是否已收到对方 ack
  bool delivered;

  /// 仅对 fromMe=true 有意义: 被对方拒收 (对方已拉黑本机)
  bool rejected;

  ChatMessage({
    this.id,
    required this.peerId,
    required this.fromMe,
    required this.text,
    required this.ts,
    this.delivered = true,
    this.rejected = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'peerId': peerId,
    'fromMe': fromMe ? 1 : 0,
    'text': text,
    'ts': ts,
    'delivered': delivered ? 1 : 0,
    'rejected': rejected ? 1 : 0,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
    id: m['id'] as int?,
    peerId: m['peerId'] as String,
    fromMe: (m['fromMe'] as int) == 1,
    text: m['text'] as String,
    ts: m['ts'] as int,
    delivered: (m['delivered'] as int? ?? 1) == 1,
    rejected: (m['rejected'] as int? ?? 0) == 1,
  );
}

class ChatDb {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final base = await getDatabasesPath();
    _db = await openDatabase(
      p.join(base, 'cloudsend_chat.db'),
      version: 4,
      onCreate: (d, v) async {
        await d.execute(
          'CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, peerId TEXT NOT NULL, fromMe INTEGER NOT NULL, text TEXT NOT NULL, ts INTEGER NOT NULL, delivered INTEGER NOT NULL DEFAULT 1, rejected INTEGER NOT NULL DEFAULT 0)',
        );
        await d.execute(
          'CREATE TABLE transfers(transferId TEXT PRIMARY KEY, peerId TEXT NOT NULL, fileName TEXT NOT NULL, fileSize INTEGER NOT NULL, outgoing INTEGER NOT NULL, status TEXT NOT NULL, savePath TEXT, ts INTEGER NOT NULL)',
        );
      },
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) {
          await d.execute(
            'CREATE TABLE transfers(transferId TEXT PRIMARY KEY, peerId TEXT NOT NULL, fileName TEXT NOT NULL, fileSize INTEGER NOT NULL, outgoing INTEGER NOT NULL, status TEXT NOT NULL, savePath TEXT, ts INTEGER NOT NULL)',
          );
        }
        if (oldV < 3) {
          await d.execute(
            'ALTER TABLE messages ADD COLUMN delivered INTEGER NOT NULL DEFAULT 1',
          );
        }
        if (oldV < 4) {
          await d.execute(
            'ALTER TABLE messages ADD COLUMN rejected INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
    );
    return _db!;
  }

  static Future<int> insert(ChatMessage m) async =>
      (await db).insert('messages', m.toMap());

  static Future<int> delete(int id) async =>
      (await db).delete('messages', where: 'id = ?', whereArgs: [id]);

  /// 标记某条消息已送达 (按 peerId + ts 定位, ack 回来时没有本地 id)
  static Future<void> markDelivered(String peerId, int ts) async =>
      (await db).update(
        'messages',
        {'delivered': 1},
        where: 'peerId = ? AND ts = ?',
        whereArgs: [peerId, ts],
      );

  /// 标记某条消息被对方拒收 (对方拉黑了本机, 不再重发)
  static Future<void> markRejected(String peerId, int ts) async =>
      (await db).update(
        'messages',
        {'rejected': 1},
        where: 'peerId = ? AND ts = ?',
        whereArgs: [peerId, ts],
      );

  /// 清除拒收标记回到未送达状态 (点击红色感叹号重发)
  static Future<void> clearRejected(String peerId, int ts) async =>
      (await db).update(
        'messages',
        {'rejected': 0, 'delivered': 0},
        where: 'peerId = ? AND ts = ?',
        whereArgs: [peerId, ts],
      );

  /// 删除与某对端的整个会话
  static Future<int> deleteConversation(String peerId) async =>
      (await db).delete('messages', where: 'peerId = ?', whereArgs: [peerId]);

  /// 拉取会话消息: 取最近 limit 条 (beforeTs+beforeId 用于向上翻页),
  /// 返回按时间正序; 游标为 (ts,id) 双条件, 同毫秒的消息不会在页边界丢失
  static Future<List<ChatMessage>> history(
    String peerId, {
    int limit = 50,
    int? beforeTs,
    int? beforeId,
  }) async {
    final String where;
    final List<Object> args;
    if (beforeTs != null && beforeId != null) {
      where = 'peerId = ? AND (ts < ? OR (ts = ? AND id < ?))';
      args = [peerId, beforeTs, beforeTs, beforeId];
    } else if (beforeTs != null) {
      where = 'peerId = ? AND ts < ?';
      args = [peerId, beforeTs];
    } else {
      where = 'peerId = ?';
      args = [peerId];
    }
    final rows = await (await db).query(
      'messages',
      where: where,
      whereArgs: args,
      orderBy: 'ts DESC, id DESC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromMap).toList().reversed.toList();
  }

  /// 是否已存在该对端同 ts 的消息 (入库前兜底去重:
  /// 会话被隐藏或分页未加载时, 对端重发的消息不能二次入库)
  static Future<bool> exists(String peerId, int ts) async {
    final rows = await (await db).query(
      'messages',
      where: 'peerId = ? AND ts = ?',
      whereArgs: [peerId, ts],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 搜索消息内容 (peerId=null 搜全部会话), 按时间倒序, 限 200 条
  static Future<List<ChatMessage>> search(String q, {String? peerId}) async {
    // 转义 LIKE 通配符, 防止输入 % / _ 时匹配异常
    final like =
        '%${q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%';
    final where = StringBuffer("text LIKE ? ESCAPE '\\'");
    final args = <Object>[like];
    if (peerId != null) {
      where.write(' AND peerId = ?');
      args.add(peerId);
    }
    final rows = await (await db).query(
      'messages',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'ts DESC',
      limit: 200,
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// 某对端所有未送达的外发消息 (重连后补发用, 不受分页加载影响);
  /// 被对方拒收的消息不再补发
  static Future<List<ChatMessage>> undelivered(String peerId) async {
    final rows = await (await db).query(
      'messages',
      where: 'peerId = ? AND fromMe = 1 AND delivered = 0 AND rejected = 0',
      whereArgs: [peerId],
      orderBy: 'ts ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// 所有有过会话的对端 ID (用于启动时恢复聊天列表)
  static Future<List<String>> conversationPeerIds() async {
    final rows = await (await db).rawQuery(
      'SELECT DISTINCT peerId FROM messages',
    );
    return rows.map((r) => r['peerId'] as String).toList();
  }

  // ---------- 传输记录持久化 ----------

  static Future<void> upsertTransfer(FileTransfer t) async {
    if (t.ephemeral) return; // 预览临时传输不入库
    await (await db).insert('transfers', {
      'transferId': t.transferId,
      'peerId': t.peerId,
      'fileName': t.fileName,
      'fileSize': t.fileSize,
      'outgoing': t.outgoing ? 1 : 0,
      'status': t.status.name,
      'savePath': t.savePath,
      'ts': t.ts,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<int> deleteTransfer(String transferId) async => (await db)
      .delete('transfers', where: 'transferId = ?', whereArgs: [transferId]);

  static Future<List<FileTransfer>> loadTransfers() async {
    final rows = await (await db).query('transfers', orderBy: 'ts ASC');
    return rows
        .map(
          (m) => FileTransfer(
            transferId: m['transferId'] as String,
            peerId: m['peerId'] as String,
            fileName: m['fileName'] as String,
            fileSize: m['fileSize'] as int,
            outgoing: (m['outgoing'] as int) == 1,
            ts: m['ts'] as int,
            savePath: m['savePath'] as String?,
            status:
                TransferStatus.values.asNameMap()[m['status'] as String] ??
                TransferStatus.failed,
          ),
        )
        // 重启后,未完成的传输标记为失败
        .map((t) {
          if (t.status == TransferStatus.waiting ||
              t.status == TransferStatus.accepted ||
              t.status == TransferStatus.transferring) {
            t.status = TransferStatus.failed;
          }
          t.bytesDone = t.status == TransferStatus.done ? t.fileSize : 0;
          return t;
        })
        .toList();
  }
}
