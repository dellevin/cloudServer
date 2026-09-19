// 打洞核心链路测试: 两个 LanManager 实例 (不同端口) 模拟两端
// 验证: adoptP2pLink 的 hello 携带 p2p 凭证 -> 对端 validateP2pHello 校验 ->
// 正确 token 收敛成一条可用链路; 错误 token 被拒绝
// 运行: dart tool/p2p_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/lan.dart';

Future<void> main() async {
  final a = LanManager(deviceId: 'dev-A', getName: () => 'A', getAvatarB64: () async => null, tcpServerPort: 45681);
  final b = LanManager(deviceId: 'dev-B', getName: () => 'B', getAvatarB64: () async => null, tcpServerPort: 45682);
  await a.start();
  await b.start();

  // B 侧: 只接受 token=ok1 的 p2p 握手 (模拟 RelayClient._validateP2pHello)
  final bValidated = Completer<String>();
  b.validateP2pHello = (link, hello) {
    if (hello['p2p'] == 'sid-1' && hello['token'] == 'ok1' && hello['id'] == 'dev-A') {
      bValidated.complete('${hello['p2p']}:${hello['token']}');
      return true;
    }
    return false;
  };
  final aFrames = <dynamic>[];
  final bFrames = <dynamic>[];
  a.onFrame = aFrames.add;
  b.onFrame = bFrames.add;

  // 1) 错误 token: 直接被拒, B 不形成链路
  {
    final sock = await Socket.connect(InternetAddress.loopbackIPv4, 45682);
    final bad = LanLink(sock, inbound: false, peerId: 'dev-B');
    a.adoptP2pLink(bad, 'dev-B', 'sid-x', 'wrong');
    await Future.delayed(const Duration(milliseconds: 500));
    assert(b.links['dev-A'] == null, 'bad token must be rejected');
    assert(bad.closed, 'bad-token link must be closed by peer');
    print('[ok] bad token rejected');
  }

  // 2) 正确 token: B 验证通过, 双方收敛成链路并互发消息
  {
    final sock = await Socket.connect(InternetAddress.loopbackIPv4, 45682);
    final good = LanLink(sock, inbound: false, peerId: 'dev-B');
    a.adoptP2pLink(good, 'dev-B', 'sid-1', 'ok1');
    final cred = await bValidated.future.timeout(const Duration(seconds: 3));
    assert(cred == 'sid-1:ok1');
    await Future.delayed(const Duration(milliseconds: 500));
    assert(b.links['dev-A'] != null && !b.links['dev-A']!.closed, 'B should hold link');
    assert(a.links['dev-B'] != null && !a.links['dev-B']!.closed, 'A should hold link');
    assert(b.links['dev-A']!.isP2p, 'link marked p2p');
    // 双向发消息 (与中继协议同构: JSON 文本帧)
    a.links['dev-B']!.sendJson({'type': 'chat', 'to': 'dev-B', 'text': 'hi', 'ts': 1});
    await Future.delayed(const Duration(milliseconds: 400));
    assert(bFrames.any((f) => f is String && f.contains('"text":"hi"')), 'B received chat');
    // from 被直连侧强制覆盖为对端身份 (防伪造)
    final m = jsonDecode(bFrames.last as String) as Map<String, dynamic>;
    assert(m['from'] == 'dev-A', m.toString());
    print('[ok] good token accepted, bidirectional chat over punched link');
  }

  await a.dispose();
  await b.dispose();
  print('P2P_CORE_OK');
  exit(0);
}
