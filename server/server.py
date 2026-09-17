"""cloudSend 中继服务器 (Python)

仅中转流量,不存储任何聊天/文件内容。

协议:
  文本帧(JSON):
    C->S {"type":"register","id":..., "name":...}
    S->C {"type":"peers","peers":[{"id","name"}...]}
    转发(附带 from/to): chat / chat_ack / file_offer / file_accept / file_reject
      / file_done / file_progress / file_result / file_cancel
  二进制帧: 前36字节为 transferId(ASCII), 其余为文件数据块, 按 transferId 路由

依赖: pip install websockets
运行: python server.py [端口, 默认8787]
"""

import asyncio
import json
import sys
import time

import websockets

clients = {}   # deviceId -> {"name": str, "ws": WebSocket, "avatar": str|None}
routes = {}    # transferId -> {"from": 发送方id, "to": 接收方id, "ts": 创建时间}

ROUTE_TTL = 3600  # 秒: 超时未完成的传输路由自动清理, 防止泄漏


async def broadcast_peers():
    msg = json.dumps({
        "type": "peers",
        "peers": [{"id": i, "name": c["name"], "avatar": c.get("avatar")} for i, c in clients.items()],
    })
    for c in list(clients.values()):
        try:
            await c["ws"].send(msg)
        except Exception:
            pass


async def forward(to, data):
    c = clients.get(to)
    if c:
        try:
            await c["ws"].send(data)
        except Exception:
            pass


async def sweep_routes():
    """定期清理超时未完成的传输路由"""
    while True:
        await asyncio.sleep(300)
        now = time.time()
        stale = [k for k, v in routes.items() if now - v["ts"] > ROUTE_TTL]
        for tid in stale:
            del routes[tid]
        if stale:
            print(f"[~] swept {len(stale)} stale transfer routes")


# 直接转发的消息类型 (服务器注入 from 后按 to 转发)
FORWARD_TYPES = (
    "chat", "chat_ack", "file_offer", "file_reject",
    "file_done", "file_progress", "file_result", "file_cancel",
)


async def handle(ws):
    my_id = None
    try:
        async for data in ws:
            if isinstance(data, str):
                try:
                    m = json.loads(data)
                except Exception:
                    continue
                t = m.get("type")
                if t == "register":
                    my_id = m["id"]
                    clients[my_id] = {"name": m.get("name", "Unknown"), "ws": ws, "avatar": m.get("avatar")}
                    print(f"[+] {m.get('name')} ({my_id}) joined, total={len(clients)}")
                    await broadcast_peers()
                elif t == "file_accept":
                    m["from"] = my_id
                    # 数据块流向: 文件发送方(m["to"]) -> 文件接收方(my_id)
                    routes[m["transferId"]] = {"from": m.get("to"), "to": my_id, "ts": time.time()}
                    to = m.get("to")
                    if to:
                        await forward(to, json.dumps(m))
                elif t in FORWARD_TYPES:
                    m["from"] = my_id
                    if t in ("file_done", "file_cancel"):
                        routes.pop(m.get("transferId"), None)  # 传输结束, 释放路由
                    to = m.get("to")
                    if to:
                        await forward(to, json.dumps(m))
            else:
                # 二进制: 前36字节为 transferId
                if len(data) > 36:
                    tid = data[:36].decode("ascii", errors="ignore")
                    r = routes.get(tid)
                    # 只转发路由登记的发送方发来的数据块, 防止伪造注入
                    if r and r["from"] == my_id:
                        await forward(r["to"], data)
    except websockets.ConnectionClosed:
        pass  # 客户端异常断开,走 finally 清理
    finally:
        if my_id and clients.get(my_id, {}).get("ws") is ws:
            del clients[my_id]
            # 无论作为发送方还是接收方, 相关传输路由都清理掉
            for tid in [k for k, v in routes.items() if v["from"] == my_id or v["to"] == my_id]:
                del routes[tid]
            print(f"[-] {my_id} left, total={len(clients)}")
            await broadcast_peers()


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    asyncio.create_task(sweep_routes())
    async with websockets.serve(handle, "0.0.0.0", port, max_size=None):
        print(f"cloudSend relay listening on ws://0.0.0.0:{port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
