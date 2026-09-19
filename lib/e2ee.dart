import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'log.dart';

/// 端到端加密 (E2EE): 接入密码作为预共享密钥, PBKDF2 派生 AES-256-GCM 密钥。
/// 对端消息整体加密成 {type:'enc', to, data} 信封, 中继/窃听者只见密文;
/// GCM 自带认证, 任何篡改都会导致解密失败被丢弃。
class E2ee {
  static final _aes = AesGcm.with256bits();
  static SecretKey? _key;
  static final _rng = Random.secure();

  /// 是否已启用 (接入密码非空)
  static bool get enabled => _key != null;

  /// 用接入密码派生密钥; 空密码 = 关闭加密 (与未设密码的服务器配套)
  static Future<void> setPassword(String pwd) async {
    if (pwd.isEmpty) {
      _key = null;
      Log.i('e2ee', 'disabled (empty access key)');
      return;
    }
    // 固定盐: 同一接入密码在所有设备上派生出同一密钥 (PSK 模型);
    // 5 万次迭代拉高弱密码的离线爆破成本
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 50000,
      bits: 256,
    );
    _key = await pbkdf2.deriveKeyFromPassword(
      password: pwd,
      nonce: utf8.encode('cloudsend-e2ee-v1'),
    );
    Log.i('e2ee', 'enabled (key derived from access key)');
  }

  /// 加密单条对端消息: msg 须含 to/from, 返回 enc 信封。
  /// data = base64(nonce ‖ 密文 ‖ GCM tag)
  static Future<Map<String, dynamic>> wrap(Map<String, dynamic> msg) async {
    final nonce = List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(msg)),
      secretKey: _key!,
      nonce: nonce,
    );
    return {
      'type': 'enc',
      'to': msg['to'],
      'data': base64Encode(box.concatenation()),
    };
  }

  /// 解密 enc 信封, 返回原始消息; 校验失败/无法解密返回 null
  static Future<Map<String, dynamic>?> unwrap(Map<String, dynamic> m) async {
    final key = _key;
    if (key == null) return null;
    try {
      final data = base64Decode(m['data'] as String);
      final box = SecretBox.fromConcatenation(
        data,
        nonceLength: 12,
        macLength: 16,
      );
      final plain = await _aes.decrypt(box, secretKey: key);
      final inner = jsonDecode(utf8.decode(plain));
      return inner is Map<String, dynamic> ? inner : null;
    } catch (_) {
      return null; // 篡改/密钥不一致/畸形: 统一按丢弃处理
    }
  }
}
