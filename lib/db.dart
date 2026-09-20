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

  /// 已被撤回 (双方都可能; 撤回后 text 不再展示, 只显示占位)
  bool recalled;

  /// 仅对 fromMe=true 有意义: 对方已读 (收到 chat_read 回执)
  bool read;

  ChatMessage({
    this.id,
    required this.peerId,
    required this.fromMe,
    required this.text,
    required this.ts,
    this.delivered = true,
    this.rejected = false,
    this.recalled = false,
    this.read = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'peerId': peerId,
    'fromMe': fromMe ? 1 : 0,
    'text': text,
    'ts': ts,
    'delivered': delivered ? 1 : 0,
    'rejected': rejected ? 1 : 0,
    'recalled': recalled ? 1 : 0,
    'readFlag': read ? 1 : 0,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
    id: m['id'] as int?,
    peerId: m['peerId'] as String,
    fromMe: (m['fromMe'] as int) == 1,
    text: m['text'] as String,
    ts: m['ts'] as int,
    delivered: (m['delivered'] as int? ?? 1) == 1,
    rejected: (m['rejected'] as int? ?? 0) == 1,
    recalled: (m['recalled'] as int? ?? 0) == 1,
    read: (m['readFlag'] as int? ?? 0) == 1,
  );
}

/// 剪贴板同步条目: 文本直接存内容, 文件存路径 (kind = text/file)
class ClipItem {
  final int? id;
  final String kind; // text / file
  final String content; // 文本内容 或 文件路径
  final int ts;
  final bool fromMe; // true=本机剪贴板上传, false=对端同步过来
  final String peerId; // 来源/去向设备

  ClipItem({
    this.id,
    required this.kind,
    required this.content,
    required this.ts,
    required this.fromMe,
    required this.peerId,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind,
    'content': content,
    'ts': ts,
    'fromMe': fromMe ? 1 : 0,
    'peerId': peerId,
  };

  factory ClipItem.fromMap(Map<String, dynamic> m) => ClipItem(
    id: m['id'] as int?,
    kind: m['kind'] as String,
    content: m['content'] as String,
    ts: m['ts'] as int,
    fromMe: (m['fromMe'] as int) == 1,
    peerId: m['peerId'] as String,
  );
}

class ChatDb {
  static Database? _db;
  // 缓存打开中的 Future: 并发调用方共享同一次 openDatabase,
  // 避免竞态打开两个句柄 (前一个泄漏且后续写分裂到两个连接)
  static Future<Database>? _opening;

  static Future<Database> get db {
    if (_db != null) return Future.value(_db!);
    return _opening ??= _open();
  }

  static Future<Database> _open() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final base = await getDatabasesPath();
    _db = await openDatabase(
      p.join(base, 'cloudsend_chat.db'),
      version: 7,
      onCreate: (d, v) async {
        await d.execute(
          'CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, peerId TEXT NOT NULL, fromMe INTEGER NOT NULL, text TEXT NOT NULL, ts INTEGER NOT NULL, delivered INTEGER NOT NULL DEFAULT 1, rejected INTEGER NOT NULL DEFAULT 0, recalled INTEGER NOT NULL DEFAULT 0, readFlag INTEGER NOT NULL DEFAULT 0)',
        );
        // 历史分页 (peerId = ? AND ts < ? ORDER BY ts DESC) 与
        // 送达/已读回执定位 (peerId = ? AND ts = ?) 的高频查询索引
        await d.execute(
          'CREATE INDEX idx_messages_peer_ts ON messages(peerId, ts)',
        );
        await d.execute(
          'CREATE TABLE transfers(transferId TEXT PRIMARY KEY, peerId TEXT NOT NULL, fileName TEXT NOT NULL, fileSize INTEGER NOT NULL, outgoing INTEGER NOT NULL, status TEXT NOT NULL, savePath TEXT, ts INTEGER NOT NULL)',
        );
        await d.execute(
          'CREATE TABLE clip_items(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, content TEXT NOT NULL, ts INTEGER NOT NULL, fromMe INTEGER NOT NULL, peerId TEXT NOT NULL)',
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
        if (oldV < 5) {
          await d.execute(
            'ALTER TABLE messages ADD COLUMN recalled INTEGER NOT NULL DEFAULT 0',
          );
          await d.execute(
            'ALTER TABLE messages ADD COLUMN readFlag INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldV < 6) {
          await d.execute(
            'CREATE TABLE clip_items(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, content TEXT NOT NULL, ts INTEGER NOT NULL, fromMe INTEGER NOT NULL, peerId TEXT NOT NULL)',
          );
        }
        if (oldV < 7) {
          await d.execute(
            'CREATE INDEX idx_messages_peer_ts ON messages(peerId, ts)',
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

  /// 标记某条消息已撤回 (按 peerId + ts 定位)
  static Future<void> markRecalled(String peerId, int ts) async =>
      (await db).update(
        'messages',
        {'recalled': 1},
        where: 'peerId = ? AND ts = ?',
        whereArgs: [peerId, ts],
      );

  /// 把发给某对端、ts <= readTs 的外发消息全部标记已读
  /// (已读回执按会话最新读位置一次性推进, 不必逐条确认)
  static Future<void> markReadUpTo(String peerId, int readTs) async =>
      (await db).update(
        'messages',
        {'readFlag': 1},
        where: 'peerId = ? AND fromMe = 1 AND ts <= ?',
        whereArgs: [peerId, readTs],
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

  // ---------- 剪贴板同步记录 ----------

  static Future<int> insertClip(ClipItem c) async =>
      (await db).insert('clip_items', c.toMap());

  /// 组装搜索/日期范围的 WHERE 子句
  static (String?, List<Object?>?) _clipWhere(
    String? query,
    int? dayStart,
    int? dayEnd,
  ) {
    final where = StringBuffer();
    final args = <Object?>[];
    if (query != null && query.isNotEmpty) {
      // 转义 LIKE 通配符, 与聊天搜索一致
      final like =
          '%${query.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%';
      where.write("content LIKE ? ESCAPE '\\'");
      args.add(like);
    }
    if (dayStart != null && dayEnd != null) {
      if (where.isNotEmpty) where.write(' AND ');
      where.write('ts >= ? AND ts < ?');
      args.add(dayStart);
      args.add(dayEnd);
    }
    return (
      where.isEmpty ? null : where.toString(),
      args.isEmpty ? null : args,
    );
  }

  /// 时间倒序分页拉取 (可带搜索词/单日范围)
  static Future<List<ClipItem>> clipHistory({
    int limit = 50,
    int offset = 0,
    String? query,
    int? dayStart,
    int? dayEnd,
  }) async {
    final (where, args) = _clipWhere(query, dayStart, dayEnd);
    final rows = await (await db).query(
      'clip_items',
      where: where,
      whereArgs: args,
      orderBy: 'ts DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(ClipItem.fromMap).toList();
  }

  /// 符合条件的总条数 (配合分页)
  static Future<int> clipCount({
    String? query,
    int? dayStart,
    int? dayEnd,
  }) async {
    final (where, args) = _clipWhere(query, dayStart, dayEnd);
    final rows = await (await db).rawQuery(
      'SELECT COUNT(*) FROM clip_items${where == null ? '' : ' WHERE $where'}',
      args,
    );
    return (rows.first.values.first as int?) ?? 0;
  }

  static Future<int> deleteClip(int id) async =>
      (await db).delete('clip_items', where: 'id = ?', whereArgs: [id]);

  static Future<int> clearClips() async =>
      (await db).delete('clip_items');

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
    final list = rows
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
        .toList();
    // 重启后未完成的传输标记为失败, 并回写 DB (否则 DB 行永远是
    // transferring, 与内存状态不一致; bytesDone 由调用方按 .part 长度恢复)
    final d = await db;
    for (final t in list) {
      if (t.status == TransferStatus.waiting ||
          t.status == TransferStatus.accepted ||
          t.status == TransferStatus.transferring ||
          t.status == TransferStatus.verifying) {
        t.status = TransferStatus.failed;
        await d.update(
          'transfers',
          {'status': t.status.name},
          where: 'transferId = ?',
          whereArgs: [t.transferId],
        );
      }
      t.bytesDone = t.status == TransferStatus.done ? t.fileSize : 0;
    }
    return list;
  }
}
