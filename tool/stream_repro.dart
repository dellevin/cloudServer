/// 用真实视频文件 + ffmpeg (与 mpv 同一个 HTTP 解复用库) 复现流式预览问题
/// 用法: dart run tool/stream_repro.dart "<视频路径>" <seek秒1> <seek秒2> ...
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/stream_server.dart';

void main(List<String> args) async {
  final src = File(args[0]);
  final size = await src.length();
  // 模拟网络: 延迟 + 带宽上限 (默认 5ms/不限速; 用 --lat=ms --kbps=n 调)
  var latencyMs = 5;
  var kbps = 0; // 0 = 不限速
  final seeks = <String>[];
  for (final a in args.skip(1)) {
    if (a.startsWith('--lat=')) {
      latencyMs = int.parse(a.substring(6));
    } else if (a.startsWith('--kbps=')) {
      kbps = int.parse(a.substring(7));
    } else {
      seeks.add(a);
    }
  }
  var reqCount = 0;

  late StreamSession s;
  s = StreamSession(
    tid: 't' * 36,
    peerId: 'peer',
    name: args[0].split(RegExp(r'[\\/]')).last,
    path: args[0],
    size: size,
    file: File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}stream_repro.cache',
    ),
    token: 'tok',
    sendReq: (o, l, pri) {
      final n = ++reqCount;
      print('REQ#$n off=$o len=$l pri=$pri');
      // 模拟宿主: 网络延迟 + 带宽限速投递, 组内倒序 (跨通道乱序)
      unawaited(Future(() async {
        await Future.delayed(Duration(milliseconds: latencyMs));
        final r = await src.open();
        final end = o + l;
        var off = o;
        while (off < end) {
          final n = off + kStreamBlock <= end ? kStreamBlock : end - off;
          await r.setPosition(off);
          final data = await r.read(n);
          if (kbps > 0) {
            await Future.delayed(
              Duration(milliseconds: data.length * 1000 ~/ (kbps * 1024)),
            );
          }
          s.onFrame(off, data);
          off += n;
        }
        await r.close();
      }));
    },
    sendSkip: (b) => print('SKIP before=$b'),
  );

  final http = StreamHttpServer();
  final url = await http.mount(s);
  print('size=$size url=$url');

  Future<void> run(String label, List<String> fargs) async {
    print('\n=== $label ===');
    final sw = Stopwatch()..start();
    final p = await Process.start('ffmpeg', ['-v', 'warning', ...fargs]);
    unawaited(
      p.stderr.listen(stderr.add).asFuture().catchError((_) {}),
    );
    final code = await p.exitCode.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        p.kill();
        return -999;
      },
    );
    print('>>> $label exit=$code 用时 ${sw.elapsedMilliseconds}ms');
  }

  // A: 从头播放 5s (moov 在尾: 测开播即探尾)
  await run('A 开头播放5s', ['-i', url, '-t', '5', '-f', 'null', '-']);
  // B..: 输入 seek (触发任意偏移 Range 请求)
  for (final ss in seeks) {
    await run('seek ${ss}s 抽1帧', [
      '-ss', ss,
      '-i', url,
      '-frames:v', '1',
      '-f', 'null', '-',
    ]);
  }

  await s.close();
  await http.dispose();
  exit(0);
}
