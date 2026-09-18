// 局域网模块冒烟测试 (纯 Dart, 不依赖 Flutter):
//   dart run tool/lan_smoke.dart
// 验证: UDP 广播发现 (同机环回, 视系统而定)、TCP 直连握手、帧收发
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloudsend/lan.dart';

void check(bool cond, String what) {
  if (!cond) {
    stderr.writeln('FAIL: $what');
    exit(1);
  }
  stdout.writeln('OK: $what');
}

Future<void> main() async {
  final a = LanManager(
    deviceId: 'device-AAAA',
    getName: () => 'A',
    getAvatarB64: () async => null,
  );
  final b = LanManager(
    deviceId: 'device-BBBB',
    getName: () => 'B',
    getAvatarB64: () async => null,
    tcpServerPort: 45679, // 同机测试, 与 A 错开
  );
  await a.start();
  await b.start();
  check(a.peers.isEmpty && b.peers.isEmpty, 'startup clean');

  // 1) UDP 广播互相发现 (同机环回广播在部分系统上收不到, 只提示不算失败)
  await Future.delayed(const Duration(seconds: 6));
  final discovered =
      a.peers.containsKey('device-BBBB') && b.peers.containsKey('device-AAAA');
  stdout.writeln(
    'UDP discovery (loopback): ${discovered ? "OK" : "SKIP (unsupported)"}',
  );

  // 2) 填上对端信息 (发现成功则已存在), 验证 TCP 直连 + 握手 + 帧收发
  a.peers['device-BBBB'] = LanPeerInfo(
    id: 'device-BBBB',
    name: 'B',
    addr: InternetAddress.loopbackIPv4,
    tcpPort: 45679,
    lastSeen: DateTime.now().millisecondsSinceEpoch,
  );

  // 2.1) 手动添加路径 (connectTo): 用一个新实例 C 模拟「输入 IP 强制直连」
  final c = LanManager(
    deviceId: 'device-CCCC',
    getName: () => 'C',
    getAvatarB64: () async => null,
    tcpServerPort: 45680,
  );
  await c.start();
  final greetedId = await c.connectTo(
    InternetAddress.loopbackIPv4,
    45679,
    manualTarget: '127.0.0.1:45679',
  );
  check(greetedId == 'device-BBBB', 'manual connectTo handshake (got $greetedId)');
  // B 侧通过入站 hello 建立条目 (无 UDP 依赖); 等处理完成
  for (var i = 0; i < 50 && b.peers['device-CCCC'] == null; i++) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  check(
    b.peers['device-CCCC'] != null,
    'B discovered C via inbound hello (no UDP needed)',
  );
  check(
    b.peers['device-CCCC']?.manual == false,
    'inbound side entry is not manual',
  );
  check(
    c.peers['device-BBBB']?.manual == true &&
        c.peers['device-BBBB']?.manualTarget == '127.0.0.1:45679',
    'manual entry tagged on connector side',
  );
  await c.dispose();

  final gotByB = Completer<String>();
  final gotBinByB = Completer<int>();
  b.onFrame = (frame) {
    if (frame is String && !gotByB.isCompleted) gotByB.complete(frame);
    if (frame is List<int> && !gotBinByB.isCompleted) {
      gotBinByB.complete(frame.length);
    }
  };

  final link = await a.ensureLink('device-BBBB');
  check(link != null && !link.closed, 'TCP connect + register');

  // 等 B 侧完成握手注册 (最久 5s)
  for (var i = 0; i < 50 && !b.links.containsKey('device-AAAA'); i++) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  check(b.links.containsKey('device-AAAA'), 'hello handshake');

  link!.sendJson({'type': 'chat', 'to': 'device-BBBB', 'text': 'hi'});
  final msg = await gotByB.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => '',
  );
  // 直连通道应注入发送方 from (中继协议里由服务器注入)
  check(
    msg.contains('"text":"hi"') && msg.contains('"from":"device-AAAA"'),
    'JSON frame + from injection: $msg',
  );

  // 大帧 (模拟文件块, 跨 TCP 分包)
  final big = Uint8List.fromList(
    List<int>.generate(200 * 1024, (i) => i & 0xff),
  );
  link.sendBinary(big);
  final n = await gotBinByB.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => -1,
  );
  check(n == 200 * 1024, 'binary frame 200KB (got $n)');

  // B 侧反向复用同一条连接回发
  final gotByA = Completer<String>();
  a.onFrame = (frame) {
    if (frame is String && !gotByA.isCompleted) gotByA.complete(frame);
  };
  b.links['device-AAAA']!.sendJson({'type': 'chat_ack', 'to': 'device-AAAA'});
  final ack = await gotByA.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => '',
  );
  check(ack.contains('chat_ack'), 'reverse reuse: $ack');

  await a.dispose();
  await b.dispose();
  stdout.writeln('ALL PASS');
  exit(0);
}
