"""冒烟测试: 验证 server.py 三个严重 bug 修复
S1 同 id 并发注册 -> 落败连接必须收到 replaced 踢除 (无幽灵)
S2 file_accept 劫持 -> 覆盖他人路由必须被拒绝; 发送方不在线不建路由
S3 路由 TTL -> 有数据帧流动时 ts 刷新
"""
import asyncio
import importlib.util
import json
import sys
import time

spec = importlib.util.spec_from_file_location("srv", "server/server.py")
srv = spec.loader.load_module()  # 不执行 __main__
# main() 里才初始化的全局: 测试手动补上
srv.acl = srv.Acl("/tmp/nonexistent_acl.json")
srv.stats = srv.Stats("/tmp/nonexistent_stats.json")

import websockets


async def recv_json(ws, timeout=3):
    raw = await asyncio.wait_for(ws.recv(), timeout)
    return json.loads(raw)


async def main():
    port = 18787
    server = await srv.start_server(port) if hasattr(srv, "start_server") else None
    if server is None:
        # 没有暴露启动函数: 直接用 websockets.serve 包 handle
        server = await websockets.serve(srv.handle, "127.0.0.1", port)

    results = []

    # ---- S2a: 发送方不在线时 file_accept 不建路由 ----
    ws_a = await websockets.connect(f"ws://127.0.0.1:{port}")
    await ws_a.send(json.dumps({"type": "register", "id": "A" * 36, "name": "a"}))
    await recv_json(ws_a)  # peers
    tid = "t" * 36
    await ws_a.send(json.dumps({"type": "file_accept", "to": "OFFLINE", "transferId": tid}))
    await asyncio.sleep(0.2)
    results.append(("S2a 离线发送方不建路由", tid not in srv.routes))

    # ---- S2b: 路由劫持被拒绝 ----
    ws_b = await websockets.connect(f"ws://127.0.0.1:{port}")
    await ws_b.send(json.dumps({"type": "register", "id": "B" * 36, "name": "b"}))
    # A 收到 peers 广播 (B 加入), 清掉
    await recv_json(ws_a)
    await recv_json(ws_b)
    # B 合法接受 A 的传输
    await ws_b.send(json.dumps({"type": "file_accept", "to": "A" * 36, "transferId": tid}))
    m = await recv_json(ws_a)
    ok = m.get("type") == "file_accept" and m.get("from") == "B" * 36
    results.append(("S2b1 合法 accept 正常转发", ok and srv.routes.get(tid, {}).get("to") == "B" * 36))
    # A (恶意) 尝试同 tid accept 覆盖路由
    await ws_a.send(json.dumps({"type": "file_accept", "to": "B" * 36, "transferId": tid}))
    await asyncio.sleep(0.2)
    results.append(("S2b2 劫持覆盖被拒绝", srv.routes[tid]["to"] == "B" * 36 and srv.routes[tid]["from"] == "A" * 36))

    # ---- S3: 数据帧刷新路由 ts ----
    srv.routes[tid]["ts"] = time.time() - 7200  # 伪装成 2 小时前
    frame = tid.encode() + b"x" * 100
    await ws_a.send(frame)  # A 是路由 from 方
    await asyncio.sleep(0.2)
    fresh = time.time() - srv.routes[tid]["ts"] < 5
    results.append(("S3 数据帧刷新路由ts", fresh))
    # B 应收到该二进制帧
    got = await asyncio.wait_for(ws_b.recv(), 3)
    results.append(("S3b 二进制帧正常转发", got == frame))

    # ---- S1: 同 id 并发注册, 落败者收 replaced ----
    ws_c1 = await websockets.connect(f"ws://127.0.0.1:{port}")
    ws_c2 = await websockets.connect(f"ws://127.0.0.1:{port}")
    cid = "C" * 36
    reg = json.dumps({"type": "register", "id": cid, "name": "c"})
    await asyncio.gather(ws_c1.send(reg), ws_c2.send(reg))
    kicked = False
    for ws in (ws_c1, ws_c2):
        try:
            while True:
                m = await recv_json(ws, 3)
                if m.get("type") == "blocked" and m.get("reason") == "replaced":
                    kicked = True
                    break
        except (asyncio.TimeoutError, Exception):
            pass
    alive = cid in srv.clients  # 在任者存活 (服务器端 ws 对象与客户端不通用)
    results.append(("S1 并发注册落败者被踢", kicked and alive))

    for name, ok in results:
        print(("PASS " if ok else "FAIL ") + name)
    server.close()
    await server.wait_closed()
    for ws in (ws_a, ws_b, ws_c1, ws_c2):
        try:
            await ws.close()
        except Exception:
            pass
    return all(ok for _, ok in results)


ok = asyncio.run(main())
sys.exit(0 if ok else 1)
