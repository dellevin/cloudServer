import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'l10n.dart';
import 'models.dart';

/// 通知栏「全部取消」按钮 id
const _kBtnCancel = 'cancel_all';

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_TransferTaskHandler());
}

/// 任务 isolate: 只负责保活和转发通知按钮事件, 传输逻辑都在主 isolate
class _TransferTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _kBtnCancel) {
      FlutterForegroundTask.sendDataToMain({'cancelAll': true});
    }
  }
}

/// Android 前台服务: 传输期间保持进程存活, 持久通知显示总进度, 可一键取消
class TransferForegroundService {
  static bool _initialized = false;
  static bool _running = false;
  static int _lastUpdate = 0;

  /// 主 isolate 收到通知栏「全部取消」时的回调 (由 RelayClient 注册)
  static void Function()? onCancelAll;

  static void init() {
    if (!Platform.isAndroid || _initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'transfer_service',
        channelName: tr('notif_channel'),
        channelDescription: tr('notif_channel_desc'),
        onlyAlertOnce: true,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback((data) {
      if (data is Map && data['cancelAll'] == true) onCancelAll?.call();
    });
  }

  static String _fmtSpeed(double bps) {
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  /// 根据进行中的传输同步服务状态 (启动 / 更新进度 / 停止)
  static Future<void> sync(List<FileTransfer> active) async {
    if (!Platform.isAndroid || !_initialized) return;
    try {
      if (active.isEmpty) {
        if (_running) {
          _running = false;
          await FlutterForegroundTask.stopService();
        }
        return;
      }
      final total = active.fold<int>(0, (a, t) => a + t.fileSize);
      final done = active.fold<int>(0, (a, t) => a + t.bytesDone);
      final pct = total > 0 ? done * 100 ~/ total : 0;
      final speed = active.fold<double>(0, (a, t) => a + t.speedBps);
      final base = active.length == 1
          ? '${active.first.fileName} $pct%'
          : '${trf('n_files', {'n': active.length})} $pct%';
      final text = speed > 0 ? '$base · ${_fmtSpeed(speed)}' : base;
      if (!_running) {
        _lastUpdate = DateTime.now().millisecondsSinceEpoch;
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: tr('notif_title'),
          notificationText: text,
          notificationButtons: [
            NotificationButton(id: _kBtnCancel, text: tr('cancel_all')),
          ],
          callback: _startCallback,
        );
        // 启动成功才置位: 先置位又抛异常会永久卡在 update 分支, 保活再也起不来
        _running = true;
      } else {
        // 节流: 500ms 最多更新一次通知
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastUpdate < 500) return;
        _lastUpdate = now;
        await FlutterForegroundTask.updateService(
          notificationTitle: tr('notif_title'),
          notificationText: text,
          notificationButtons: [
            NotificationButton(id: _kBtnCancel, text: tr('cancel_all')),
          ],
        );
      }
    } catch (_) {}
  }
}
