import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'client.dart';
import 'models.dart';
import 'ui/chat_page.dart';
import 'ui/chat_search_page.dart';
import 'ui/devices_page.dart';
import 'ui/file_preview_page.dart';
import 'ui/log_page.dart';
import 'ui/settings_page.dart';
import 'ui/transfers_page.dart';
import 'ui/video_player_page.dart';
import 'ui/zip_preview_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // 视频播放器 (media_kit)
  // Android 前台服务通信端口 (必须在 runApp 前初始化)
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }
  // Windows: 固定宽度窗口 + 自定义标题栏 (仅最小化/关闭, 无最大化)
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(420, 780),
      minimumSize: Size(420, 560),
      maximumSize: Size(420, 2000), // 宽度锁死, 高度可调
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.white,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setMaximizable(false);
      await windowManager.show();
      await windowManager.focus();
    });
  }
  final client = RelayClient();
  await client.init();
  runApp(
    ChangeNotifierProvider.value(value: client, child: const CloudSendApp()),
  );
}

/// 微信风格主题
class AppTheme {
  static const ink = Color(0xFF1A1A1A);
  static const grey = Color(0xFF8A8A8A);
  static const hairline = Color(0xFFE5E5E5);
  static const bg = Color(0xFFFFFFFF);
  static const bgSoft = Color(0xFFF7F7F7);
  static const green = Color(0xFF07C160); // 微信绿
  static const red = Color(0xFFFA5151); // 微信警示红

  // ---- 深色模式辅助 ----
  static bool isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  /// 卡片/容器底色
  static Color cardOf(BuildContext c) =>
      isDark(c) ? const Color(0xFF1E1E1E) : Colors.white;

  /// 描边/分隔线
  static Color lineOf(BuildContext c) =>
      isDark(c) ? const Color(0xFF2C2C2C) : hairline;

  /// 主文字色
  static Color inkOf(BuildContext c) =>
      isDark(c) ? const Color(0xFFE8E8E8) : ink;

  /// 次级灰底色 (输入条/面板)
  static Color softOf(BuildContext c) =>
      isDark(c) ? const Color(0xFF181818) : const Color(0xFFF7F7F7);

  /// 聊天背景
  static Color chatBgOf(BuildContext c) =>
      isDark(c) ? const Color(0xFF0F0F0F) : const Color(0xFFEDEDED);

  /// 收到的气泡/输入框填充
  static Color bubbleOf(BuildContext c) =>
      isDark(c) ? const Color(0xFF2A2A2A) : Colors.white;

  /// 气泡内文字
  static Color bubbleInkOf(BuildContext c) =>
      isDark(c) ? const Color(0xFFE8E8E8) : Colors.black87;

  static ThemeData get theme {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: green,
          brightness: Brightness.light,
        ).copyWith(
          primary: green,
          onPrimary: Colors.white,
          secondary: green,
          surface: bg,
          onSurface: ink,
          surfaceContainerHighest: bgSoft,
          primaryContainer: const Color(0xFFE7F6EC),
          onPrimaryContainer: ink,
          tertiaryContainer: bgSoft,
          onTertiaryContainer: ink,
          outline: hairline,
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      splashFactory: NoSplash.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: bgSoft,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: bg,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: hairline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: hairline,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSoft,
        hintStyle: const TextStyle(color: grey, fontSize: 14),
        labelStyle: const TextStyle(color: grey, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: green, width: 1.2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: hairline),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: green,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: const BorderSide(color: hairline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        // 半透明药丸 toast
        backgroundColor: ink.withValues(alpha: 0.88),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bgSoft,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFFE7F6EC),
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 11,
            letterSpacing: 0.5,
            color: s.contains(WidgetState.selected) ? green : grey,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? green : grey,
            size: 22,
          ),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: green,
        linearTrackColor: hairline,
      ),
    );
  }

  /// 深色主题 (微信深色风)
  static ThemeData get darkTheme {
    const dBg = Color(0xFF101010); // 页面底
    const dCard = Color(0xFF1E1E1E); // 卡片/容器
    const dSoft = Color(0xFF181818); // AppBar/导航底
    const dLine = Color(0xFF2C2C2C); // 描边/分隔
    const dInk = Color(0xFFE8E8E8); // 主文字
    const dGrey = Color(0xFF8A8A8A);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: green,
          brightness: Brightness.dark,
        ).copyWith(
          primary: green,
          onPrimary: Colors.white,
          secondary: green,
          surface: dCard,
          onSurface: dInk,
          surfaceContainerHighest: const Color(0xFF262626),
          primaryContainer: const Color(0xFF0E3B24),
          onPrimaryContainer: dInk,
          tertiaryContainer: const Color(0xFF262626),
          onTertiaryContainer: dInk,
          outline: dLine,
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: dBg,
      splashFactory: NoSplash.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: dSoft,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: dInk,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
        iconTheme: IconThemeData(color: dInk),
      ),
      cardTheme: CardThemeData(
        color: dCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: dLine),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: dLine,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF262626),
        hintStyle: const TextStyle(color: dGrey, fontSize: 14),
        labelStyle: const TextStyle(color: dGrey, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: dLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: green, width: 1.2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: dLine),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: green,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: dInk,
          side: const BorderSide(color: dLine),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2E2E2E).withValues(alpha: 0.95),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dSoft,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFF0E3B24),
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 11,
            letterSpacing: 0.5,
            color: s.contains(WidgetState.selected) ? green : dGrey,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? green : dGrey,
            size: 22,
          ),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: green,
        linearTrackColor: dLine,
      ),
    );
  }
}

class CloudSendApp extends StatefulWidget {
  const CloudSendApp({super.key});

  @override
  State<CloudSendApp> createState() => _CloudSendAppState();
}

class _CloudSendAppState extends State<CloudSendApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<FileTransfer>? _offerSub;
  final List<FileTransfer> _offerQueue = []; // 多个请求排队弹窗
  bool _offerShowing = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<RelayClient>();
    _offerSub = c.fileOffers.listen((t) {
      _offerQueue.add(t);
      _pumpOfferDialog();
    });
    // 点击系统通知 (Android): 跳转到对应会话
    c.onNotificationOpenChat = (peerId) {
      _navigatorKey.currentState?.pushNamed('/chat', arguments: peerId);
    };
  }

  @override
  void dispose() {
    _offerSub?.cancel();
    super.dispose();
  }

  /// 逐个弹出文件接收确认框
  Future<void> _pumpOfferDialog() async {
    if (_offerShowing) return;
    _offerShowing = true;
    while (_offerQueue.isNotEmpty) {
      final t = _offerQueue.removeAt(0);
      final ctx = _navigatorKey.currentContext;
      // 可能已在聊天页/传输记录里处理过了
      if (ctx == null || t.status != TransferStatus.waiting) continue;
      await showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (dctx) => _FileOfferDialog(t: t),
      );
    }
    _offerShowing = false;
  }

  bool _blockedShowing = false;

  /// 被服务器踢下线/拉黑: 全局弹窗, 可选手动重连
  Future<void> _showBlockedDialog(RelayClient c) async {
    if (_blockedShowing) return;
    _blockedShowing = true;
    final reason = c.blockedReason!;
    try {
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) return;
      final reconnect = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (dctx) => AlertDialog(
          backgroundColor: AppTheme.cardOf(dctx),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: AppTheme.lineOf(dctx)),
          ),
          title: const Text(
            '连接已断开',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: Text(
            RelayClient.blockedText(reason),
            style: const TextStyle(fontSize: 13, color: AppTheme.grey),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('知道了'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('重新连接'),
            ),
          ],
        ),
      );
      if (reconnect == true) {
        c.connect(c.serverAddr); // connect 内部会清除 blockedReason
      } else if (c.blockedReason == reason) {
        c.clearBlocked(); // 保持断开, 仅关闭提示
      }
    } finally {
      _blockedShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    // 被服务器踢下线/拉黑时弹全局提示 (build 里不能直接弹窗, 延后到帧末)
    if (c.blockedReason != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showBlockedDialog(c),
      );
    }
    return MaterialApp(
      title: 'cloudSend',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      darkTheme: AppTheme.darkTheme,
      themeMode: c.darkMode ? ThemeMode.dark : ThemeMode.light,
      navigatorKey: _navigatorKey,
      // Windows: 顶部叠加自定义标题栏
      builder: Platform.isWindows
          ? (ctx, child) => Column(
              children: [
                const _WindowTitleBar(),
                Expanded(child: child ?? const SizedBox.shrink()),
              ],
            )
          : null,
      home: const HomePage(),
      routes: {
        '/chat': (_) => const ChatPage(),
        '/chat_search': (_) => const ChatSearchPage(),
        '/settings': (_) => const SettingsPage(),
        '/file_preview': (_) => const FilePreviewPage(),
        '/transfers': (_) => const TransfersPage(),
        '/log': (_) => const LogPage(),
        '/image_view': (_) => const ImageViewPage(),
        '/video_view': (_) => const VideoPlayerPage(),
        '/zip_view': (_) => const ZipPreviewPage(),
      },
    );
  }
}

/// Windows 自定义标题栏: 可拖动, 仅最小化/关闭按钮 (无最大化)
class _WindowTitleBar extends StatelessWidget {
  const _WindowTitleBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppTheme.softOf(context),
        border: Border(bottom: BorderSide(color: AppTheme.lineOf(context))),
      ),
      child: Row(
        children: [
          // 可拖动区域
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.asset(
                        'assets/icon.png',
                        width: 15,
                        height: 15,
                      ),
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      'cloudSend',
                      style: TextStyle(fontSize: 12, color: AppTheme.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _WinBtn(icon: Icons.remove, onTap: () => windowManager.minimize()),
          _WinBtn(
            icon: Icons.close,
            hoverColor: const Color(0xFFE81123),
            hoverIconColor: Colors.white,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _WinBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color hoverColor;
  final Color hoverIconColor;

  const _WinBtn({
    required this.icon,
    required this.onTap,
    this.hoverColor = const Color(0x11000000),
    this.hoverIconColor = AppTheme.ink,
  });

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 42,
          height: 38,
          color: _hover ? widget.hoverColor : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 15,
            color: _hover
                ? (widget.hoverIconColor == AppTheme.ink
                      ? AppTheme.inkOf(context)
                      : widget.hoverIconColor)
                : AppTheme.grey,
          ),
        ),
      ),
    );
  }
}

/// 全局文件接收确认弹窗: 显示来源设备、文件名、大小, 可接受/拒绝
class _FileOfferDialog extends StatelessWidget {
  final FileTransfer t;
  const _FileOfferDialog({required this.t});

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  void _act(BuildContext context, RelayClient c, bool accept) {
    // 只处理仍在等待的请求 (可能已在别处响应过)
    if (t.status == TransferStatus.waiting) {
      if (accept) {
        c.acceptFile(t);
      } else {
        c.rejectFile(t);
      }
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<RelayClient>();
    final name = c.peerName(t.peerId);
    final avatarBytes = c.peerAvatarBytes(t.peerId);
    return AlertDialog(
      backgroundColor: AppTheme.cardOf(context),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 来源设备
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF576B95),
              borderRadius: BorderRadius.circular(10),
              image: avatarBytes != null
                  ? DecorationImage(
                      image: MemoryImage(avatarBytes),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: avatarBytes != null
                ? null
                : Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 20,
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Text(
            '$name 向您发送文件',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          // 文件信息卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.softOf(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.isDark(context)
                        ? const Color(0xFF0E3B24)
                        : const Color(0xFFE7F6EC),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 19,
                    color: AppTheme.green,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _fmt(t.fileSize),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _act(context, c, false),
                child: const Text('拒绝'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => _act(context, c, true),
                child: const Text('接受'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0; // 0=设备 1=聊天
  int _chatSub = 0; // 聊天 tab 内: 0=消息 1=传输记录

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RelayClient>();
    final unreadTotal = c.unread.values.fold(0, (a, b) => a + b);
    return Scaffold(
      appBar: AppBar(
        title: _tab == 0
            ? Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Image.asset(
                      'assets/icon.png',
                      width: 22,
                      height: 22,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('cloudSend'),
                  const SizedBox(width: 6),
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'v1.0.0',
                      style: TextStyle(fontSize: 10.5, color: AppTheme.grey),
                    ),
                  ),
                ],
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 188,
                  height: 31,
                  decoration: BoxDecoration(
                    color: AppTheme.cardOf(context),
                    borderRadius: BorderRadius.circular(15.5),
                    border: Border.all(color: AppTheme.lineOf(context)),
                  ),
                  child: Row(children: [_seg('消息', 0), _seg('传输记录', 1)]),
                ),
              ),
        actions: [
          _RefreshAction(),
          if (_tab == 1)
            _CircleAction(
              tooltip: '搜索',
              icon: Icons.search,
              onTap: () => Navigator.pushNamed(context, '/chat_search'),
            ),
          _CircleAction(
            tooltip: '设置',
            icon: Icons.settings_outlined,
            onTap: () => Navigator.pushNamed(context, '/settings'),
          ),
          const SizedBox(width: 10),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: IndexedStack(
        index: _tab == 0 ? 0 : _chatSub + 1,
        children: const [
          DevicesPage(),
          ChatsTabPage(),
          TransfersPage(embedded: true),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            label: '设备',
          ),
          NavigationDestination(
            icon: Badge.count(
              count: unreadTotal,
              isLabelVisible: unreadTotal > 0,
              child: const Icon(Icons.chat_bubble_outline),
            ),
            label: '聊天',
          ),
        ],
      ),
    );
  }

  /// 顶部 消息/传输记录 分段切换
  Widget _seg(String label, int idx) {
    final selected = _chatSub == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _chatSub = idx),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.all(2.5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppTheme.green : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppTheme.grey,
            ),
          ),
        ),
      ),
    );
  }
}

/// AppBar 右上角圆形白底按钮 (搜索 / 设置)
class _CircleAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// 自定义内容 (如旋转动画), 缺省用 icon
  final Widget? child;

  const _CircleAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.cardOf(context),
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.lineOf(context)),
            ),
            child:
                child ?? Icon(icon, size: 17, color: AppTheme.inkOf(context)),
          ),
        ),
      ),
    );
  }
}

/// 顶栏刷新按钮: 点击触发 refreshPeers, 刷新期间图标转圈 (防连点)
class _RefreshAction extends StatefulWidget {
  @override
  State<_RefreshAction> createState() => _RefreshActionState();
}

class _RefreshActionState extends State<_RefreshAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  Future<void> _refresh() async {
    if (_spin.isAnimating) return; // 刷新中忽略连点
    _spin.repeat();
    try {
      await context.read<RelayClient>().refreshPeers();
    } finally {
      _spin.stop();
      _spin.reset();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _CircleAction(
      tooltip: '刷新',
      icon: Icons.refresh,
      onTap: _refresh,
      child: RotationTransition(
        turns: _spin,
        child: Icon(Icons.refresh, size: 17, color: AppTheme.inkOf(context)),
      ),
    );
  }
}

/// 页面标题 (极简博客风格)
class PageTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const PageTitle(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppTheme.inkOf(context),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.grey,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
