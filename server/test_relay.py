"""端到端协议测试: 两个模拟客户端通过中继互发消息和文件
另验证: 第三方伪造数据块会被拦截; file_done 后路由被清理(伪造/正常块都不再转发)
"""
import asyncio
import json
import sys

import websockets

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
BASE = f"ws://127.0.0.1:{PORT}"

TID = "12345678-1234-1234-1234-123456789012"
A = "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"
B = "BBBB-BBBB-BBBB-BBBB-BBBB-BBBB-BBBB-BBBB"
C = "CCCC-CCCC-CCCC-CCCC-CCCC-CCCC-CCCC-CCCC"


async def main():
    ok = set()
    async with websockets.connect(BASE) as a, \
               websockets.connect(BASE) as b, \
               websockets.connect(BASE) as c:
        await a.send(json.dumps({"type": "register", "id": A, "name": "A"}))
        await b.send(json.dumps({"type": "register", "id": B, "name": "B"}))
        await c.send(json.dumps({"type": "register", "id": C, "name": "C"}))

        async def listen_a():
            async for d in a:
                if isinstance(d, str):
                    m = json.loads(d)
                    if m.get("type") == "file_accept":
                        await a.send(TID.encode() + b"file-content")
                        await a.send(json.dumps({"type": "file_done", "to": m["from"],
                                                 "transferId": TID, "sha256": "x", "size": 12}))
                    elif m.get("type") == "file_progress":
                        ok.add("progress")

        async def listen_b():
            async for d in b:
                if isinstance(d, str):
                    m = json.loads(d)
                    if m.get("type") == "peers" and len(m["peers"]) == 3:
                        ok.add("peers")
                    elif m.get("type") == "chat" and m.get("text") == "hello":
                        ok.add("chat")
                    elif m.get("type") == "file_offer":
                        ok.add("offer")
                        await b.send(json.dumps({"type": "file_accept", "to": m["from"],
                                                 "transferId": m["transferId"], "offset": 0}))
                    elif m.get("type") == "file_done":
                        ok.add("done")
                else:
                    if d[:36].decode() == TID and d[36:] == b"file-content":
                        ok.add("file")
                        # 接收方向发送方回报进度
                        await b.send(json.dumps({"type": "file_progress", "to": A,
                                                 "transferId": TID, "bytes": 12}))
                    elif d[:36].decode() == TID and d[36:] == b"evil-chunk":
                        ok.add("INJECTED")  # 不该收到

        ta = asyncio.create_task(listen_a())
        tb = asyncio.create_task(listen_b())
        await asyncio.sleep(0.5)
        await a.send(json.dumps({"type": "chat", "to": B, "text": "hello", "ts": 1}))
        await a.send(json.dumps({"type": "file_offer", "to": B, "transferId": TID, "name": "t.txt", "size": 12}))
        await asyncio.sleep(1.0)
        # C 伪造该 transferId 的数据块, 服务器应拦截 (不是路由登记的发送方)
        await c.send(TID.encode() + b"evil-chunk")
        # file_done 之后路由已清理, 正常块也不再转发
        await a.send(TID.encode() + b"evil-chunk")
        await asyncio.sleep(1.0)
        ta.cancel(); tb.cancel()

    print(f"RESULT: peers={'peers' in ok} chat={'chat' in ok} offer={'offer' in ok} "
          f"file={'file' in ok} done={'done' in ok} progress={'progress' in ok} "
          f"inject_blocked={'INJECTED' not in ok}")


asyncio.run(main())
