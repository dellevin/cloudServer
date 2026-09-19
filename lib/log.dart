import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n.dart';

/// 轻量文件日志: 单文件滚动 (超过 5MB 时截断保留尾部 512KB)。
/// 关键路径 (连接/传输/协议异常) 都写一份, 设置页可查看/导出/清空。
class Log {
  static File? _file;
  static IOSink? _sink;
  static int _sinceFlush = 0;
  static Timer? _flushTimer;

  static const _maxBytes = 5 * 1024 * 1024;
  static const _keepBytes = 512 * 1024;

  static Future<void> init() async {
    if (_sink != null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}${Platform.pathSeparator}logs');
      await logDir.create(recursive: true);
      _file = File('${logDir.path}${Platform.pathSeparator}cloudsend.log');
      if (await _file!.exists() && await _file!.length() > _maxBytes) {
        await _truncate();
      }
      _sink = _file!.openWrite(mode: FileMode.append);
      // 定期落盘 (IOSink 有缓冲, 崩溃时少丢日志)
      _flushTimer = Timer.periodic(const Duration(seconds: 3), (_) => flush());
      i('log', '--- app start (pid $pid) ---');
    } catch (_) {}
  }

  /// 截断日志: 只保留尾部, 防止越攒越大 (启动时与运行中超限都调用)
  static Future<void> _truncate() async {
    RandomAccessFile? raf;
    try {
      raf = await _file!.open();
      final len = await raf.length();
      await raf.setPosition(len - _keepBytes);
      final tail = await raf.read(_keepBytes);
      await raf.close();
      raf = null;
      await _file!.writeAsBytes(tail, flush: true);
    } finally {
      // 读/seek 抛异常时句柄也得关, 否则泄漏
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 运行中截断检查: 每 200 行估一次文件大小, 超 1MB 重建 sink 并截断
  static int _sinceTrimCheck = 0;

  static Future<void> _trimIfNeeded() async {
    final f = _file;
    if (f == null || _sink == null) return;
    try {
      if (await f.length() <= _maxBytes) return;
      await _sink!.flush();
      await _sink!.close();
      _sink = null;
      await _truncate();
      _sink = f.openWrite(mode: FileMode.append);
      i('log', 'log trimmed to $_keepBytes bytes');
    } catch (_) {
      // 截断中途失败也必须重建 sink, 否则之后文件日志全丢
      _sink ??= f.openWrite(mode: FileMode.append);
    }
  }

  static String get _ts {
    final d = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p2(d.month)}-${p2(d.day)} '
        '${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)}.'
        '${d.millisecond.toString().padLeft(3, '0')}';
  }

  static void i(String tag, String msg) => _write('I', tag, msg);
  static void w(String tag, String msg) => _write('W', tag, msg);
  static void e(String tag, String msg, [Object? err]) =>
      _write('E', tag, err == null ? msg : '$msg ($err)');

  static void _write(String level, String tag, String msg) {
    final line = '$_ts $level/$tag: $msg';
    debugPrint(line);
    try {
      _sink?.writeln(line);
      // 错误立即落盘; 普通日志攒 20 行刷一次 (另有 3s 定时兜底)
      if (level == 'E' || ++_sinceFlush >= 20) flush();
      if (++_sinceTrimCheck >= 200) {
        _sinceTrimCheck = 0;
        unawaited(_trimIfNeeded());
      }
    } catch (_) {}
  }

  static void flush() {
    _sinceFlush = 0;
    try {
      unawaited(_sink?.flush());
    } catch (_) {}
  }

  /// 日志文件路径; 未初始化成功时为 null
  static String? get filePath => _file?.path;

  /// 读取日志尾部 (最多 maxBytes, 从行边界截断), 供查看页展示
  static Future<String> readTail({int maxBytes = 128 * 1024}) async {
    flush();
    final f = _file;
    if (f == null || !await f.exists()) return tr('no_log_yet');
    try {
      final len = await f.length();
      RandomAccessFile? raf;
      Uint8List bytes;
      try {
        raf = await f.open();
        if (len > maxBytes) await raf.setPosition(len - maxBytes);
        bytes = await raf.read(len > maxBytes ? maxBytes : len);
        await raf.close();
        raf = null;
      } finally {
        try {
          await raf?.close();
        } catch (_) {}
      }
      // 日志是 UTF-8 写入的, 必须按 UTF-8 解码;
      // fromCharCodes 会把多字节序列逐字节摊开成乱码 (中文文件名全花)
      var text = utf8.decode(bytes, allowMalformed: true);
      if (len > maxBytes) {
        final nl = text.indexOf('\n');
        if (nl >= 0) text = text.substring(nl + 1);
      }
      return text.isEmpty ? tr('no_log_yet') : text;
    } catch (err) {
      return trf('log_read_fail', {'err': err});
    }
  }

  static Future<void> clear() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    try {
      await _file?.delete();
    } catch (_) {}
    _sink = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    await init();
  }
}
