"""cloudSend 中继服务器 (Python)

仅中转流量,不存储任何聊天/文件内容。

协议:
  文本帧(JSON):
    C->S {"type":"register","id":..., "name":..., "avatar":..., "ver":..., "platform":...}
    S->C {"type":"peers","peers":[{"id","name","avatar","platform"}...]}
    转发(附带 from/to): chat / chat_ack / file_offer / file_accept / file_reject
      / file_done / file_progress / file_result / file_cancel
  二进制帧: 前36字节为 transferId(ASCII), 其余为文件数据块, 按 transferId 路由

管理后台 (独立 HTTP 端口, 默认 8788):
  - 登录: 打开首页输入 admin token 登录 (或直接用启动时打印的带 token 链接),
    会话存内存, 重启失效; 未登录访问 /panel 会跳回登录页
  - 模式: 关闭 / 白名单 (仅白名单内的设备id或IP可用) / 黑名单 (黑名单内不可用)
  - 名单: 黑/白各一套独立的 设备id + IP 名单, 互不影响;
    设备id 精确匹配; IP 支持单地址或 CIDR 网段 (如 1.2.3.4, 10.0.0.0/8)
  - 在线设备: 可踢下线 / 拉黑ID / 拉黑IP / 加白ID / 加白IP; 被拦设备会收到
    {"type":"blocked","reason": kick|black_id|black_ip|white} 并被 4403 关闭;
    名单持久化在 server_acl.json (旧版共用名单格式会自动迁移进两套名单)

依赖: pip install websockets
运行: python server.py [端口, 默认8787] [--admin-port 8788] [--admin-token xxx]
      未指定 --admin-token 时每次启动随机生成并打印 (也可设环境变量 ADMIN_TOKEN)
"""

import argparse
import asyncio
import ipaddress
import json
import logging
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import websockets

clients = {}   # deviceId -> {"name": str, "ws": WebSocket, "avatar": str|None, "ip": str|None}
routes = {}    # transferId -> {"from": 发送方id, "to": 接收方id, "ts": 创建时间}

ROUTE_TTL = 3600  # 秒: 超时未完成的传输路由自动清理, 防止泄漏

# ---------- 防护: 帧大小上限 / 单IP连接数 / register 限流 ----------
MAX_TEXT_FRAME = 512 * 1024       # 文本帧上限 (JSON 控制消息, 含 base64 头像)
MAX_BIN_FRAME = 1024 * 1024 + 64  # 二进制帧上限 (文件块 + 36字节 transferId 头)
MAX_CONNS_PER_IP = 16             # 单 IP 并发连接上限
REGISTER_PER_MIN = 30             # 单 IP 每分钟 register 上限 (正常客户端 <5)

ip_conns = {}  # ip -> 当前连接数
reg_hist = {}  # ip -> [最近 register 时间戳...]


# ---------- 访问控制 (黑/白名单, 各自独立) ----------

class Acl:
    """线程安全的名单存取 + 判定; 持久化为 JSON 文件
    黑名单/白名单各有一套独立的 设备ID + IP 名单, 互不干扰"""

    LISTS = ("black", "white")
    KINDS = ("ids", "ips")

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {
            "mode": "off",
            "black": {"ids": [], "ips": []},
            "white": {"ids": [], "ips": []},
        }
        self.load()

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
            with self.lock:
                self.data["mode"] = d.get("mode", "off")
                if "black" in d or "white" in d:
                    for lst in self.LISTS:
                        for kind in self.KINDS:
                            self.data[lst][kind] = [
                                str(x) for x in d.get(lst, {}).get(kind, [])
                            ]
                else:
                    # 旧格式迁移: 原先黑白共用的 ids/ips 同时进两套名单,
                    # 这样无论当时处于哪种模式, 行为都保持不变
                    old_ids = [str(x) for x in d.get("ids", [])]
                    old_ips = [str(x) for x in d.get("ips", [])]
                    for lst in self.LISTS:
                        self.data[lst] = {"ids": list(old_ids), "ips": list(old_ips)}
        except Exception:
            pass  # 文件不存在/损坏时用默认 (关闭模式)

    def save(self):
        try:
            with self.lock:
                d = json.loads(json.dumps(self.data))
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print(f"[!] acl save failed: {e}")

    def snapshot(self):
        with self.lock:
            return {
                "mode": self.data["mode"],
                "black": {k: list(v) for k, v in self.data["black"].items()},
                "white": {k: list(v) for k, v in self.data["white"].items()},
            }

    def set_mode(self, mode):
        assert mode in ("off", "whitelist", "blacklist")
        with self.lock:
            self.data["mode"] = mode
        self.save()

    def add(self, lst, kind, value):
        assert lst in self.LISTS and kind in self.KINDS
        value = value.strip()
        if not value:
            return False
        with self.lock:
            if value in self.data[lst][kind]:
                return False
            self.data[lst][kind].append(value)
        self.save()
        return True

    def remove(self, lst, kind, value):
        assert lst in self.LISTS and kind in self.KINDS
        with self.lock:
            if value not in self.data[lst][kind]:
                return False
            self.data[lst][kind].remove(value)
        self.save()
        return True

    @staticmethod
    def _ip_hit(entry, ip):
        """单地址精确匹配或 CIDR 网段包含"""
        try:
            return ipaddress.ip_address(ip) in ipaddress.ip_network(entry, strict=False)
        except ValueError:
            return entry == ip  # 非法条目按字符串精确匹配兜底

    def hit(self, lst, device_id=None, ip=None):
        """是否命中指定名单 (black/white)"""
        snap = self.snapshot()[lst]
        id_hit = device_id is not None and device_id in snap["ids"]
        ip_hit = ip is not None and any(self._ip_hit(e, ip) for e in snap["ips"])
        return id_hit or ip_hit

    def id_hit(self, lst, device_id):
        return device_id is not None and device_id in self.snapshot()[lst]["ids"]

    def ip_hit(self, lst, ip):
        return ip is not None and any(
            self._ip_hit(e, ip) for e in self.snapshot()[lst]["ips"]
        )


acl = None  # main() 里按 --acl-file 初始化


class _HandshakeFailFilter(logging.Filter):
    """websockets 对握手失败(非 WS 的 HTTP 请求碰到 WS 端口, 公网扫描很常见)
    会打整段堆栈, 太吵; 压成一行提示"""

    def filter(self, record):
        if record.getMessage().startswith("opening handshake failed"):
            print("[~] rejected non-websocket handshake (port scan or http probe)")
            return False
        return True


def client_ip(ws):
    """反代场景优先取 X-Forwarded-For 首个地址, 否则用对端地址"""
    try:
        headers = getattr(ws, "request_headers", None)
        if headers is None:
            headers = getattr(getattr(ws, "request", None), "headers", None)
        if headers:
            xff = headers.get("X-Forwarded-For")
            if xff:
                return xff.split(",")[0].strip()
    except Exception:
        pass
    try:
        return ws.remote_address[0]
    except Exception:
        return None


# ---------- 中继逻辑 ----------

async def broadcast_peers():
    msg = json.dumps({
        "type": "peers",
        "peers": [{"id": i, "name": c["name"], "avatar": c.get("avatar"), "platform": c.get("platform")} for i, c in clients.items()],
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


async def kick(ws, reason="kick"):
    """踢下线: 通知后关闭 (4403=应用层自定义'无权限')
    reason: kick=手动踢下线 / black_id=拉黑设备ID / black_ip=拉黑IP / white=不在白名单"""
    try:
        await ws.send(json.dumps({"type": "blocked", "reason": reason}))
    except Exception:
        pass
    try:
        await ws.close(code=4403, reason=reason)
    except Exception:
        pass


def block_reason(device_id=None, ip=None):
    """返回该设备应被拒绝的原因字符串; None 表示允许接入"""
    mode = acl.snapshot()["mode"]
    if mode == "off":
        return None
    if mode == "whitelist":
        return None if acl.hit("white", device_id, ip) else "white"
    # blacklist: 优先报设备 id 命中
    if acl.id_hit("black", device_id):
        return "black_id"
    if acl.ip_hit("black", ip):
        return "black_ip"
    return None


def enforce_acl(loop):
    """管理线程调用: 把当前已连接但已不被允许的设备踢下线"""
    async def _run():
        for i, c in list(clients.items()):
            r = block_reason(i, c.get("ip"))
            if r:
                print(f"[x] kick {i} ({c.get('ip')}): {r}")
                await kick(c["ws"], r)
    asyncio.run_coroutine_threadsafe(_run(), loop)


# 直接转发的消息类型 (服务器注入 from 后按 to 转发)
FORWARD_TYPES = (
    "chat", "chat_ack", "chat_reject", "file_offer", "file_reject",
    "file_done", "file_progress", "file_result", "file_cancel",
    "fs_list", "fs_list_result", "fs_get",
)


async def handle(ws):
    my_id = None
    ip = client_ip(ws)
    # 连接级拦截: 仅黑名单模式在此拒绝 (IP 命中黑名单即踢)。
    # 白名单模式不能在此拒绝: 设备 id 白名单要等 register 才知道, 届时再校验
    if acl.snapshot()["mode"] == "blacklist" and acl.ip_hit("black", ip):
        print(f"[x] connection from {ip} refused (blacklist)")
        await kick(ws, "black_ip")
        return
    # 单 IP 并发连接上限 (反代场景所有客户端共享出口 IP, 阈值别定太低)
    if ip is not None:
        n = ip_conns.get(ip, 0)
        if n >= MAX_CONNS_PER_IP:
            print(f"[x] connection from {ip} refused (too many connections)")
            await kick(ws, "rate")
            return
        ip_conns[ip] = n + 1
    try:
        async for data in ws:
            try:
                if isinstance(data, str):
                    if len(data) > MAX_TEXT_FRAME:
                        print(f"[!] oversize text frame from {my_id or ip} ({len(data)}B), dropped")
                        continue
                    try:
                        m = json.loads(data)
                    except Exception:
                        continue
                    if not isinstance(m, dict):
                        continue  # 非对象 JSON (null/数组/数字) 无法路由
                    t = m.get("type")
                    if t == "register":
                        rid = m.get("id")
                        if not isinstance(rid, str) or not rid:
                            continue
                        my_id = rid
                        # register 限流: 正常客户端只在连接/手动刷新时注册
                        now = time.time()
                        hist = [x for x in reg_hist.get(ip, []) if now - x < 60]
                        if len(hist) >= REGISTER_PER_MIN:
                            print(f"[x] register rate limit hit from {ip}")
                            await kick(ws, "rate")
                            return
                        hist.append(now)
                        reg_hist[ip] = hist
                        # 注册级拦截: 设备 id 不被允许 (或此时 IP 名单也变了)
                        r = block_reason(my_id, ip)
                        if r:
                            print(f"[x] register {my_id} from {ip} refused ({r})")
                            await kick(ws, r)
                            return
                        # 同一连接换 id 重新注册: 清掉旧 id 的映射, 防幽灵条目
                        for k, v in list(clients.items()):
                            if v["ws"] is ws and k != my_id:
                                del clients[k]
                        # 同 id 已有旧连接: 踢掉旧的, 新连接接管身份 (防并行劫持)
                        old = clients.get(my_id)
                        if old is not None and old["ws"] is not ws:
                            print(f"[~] {my_id} re-registered, kicking old connection")
                            await kick(old["ws"], "replaced")
                        clients[my_id] = {
                            "name": m.get("name", "Unknown"),
                            "ws": ws,
                            "avatar": m.get("avatar"),
                            "platform": m.get("platform"),
                            "ip": ip,
                        }
                        print(f"[+] {m.get('name')} ({my_id}) v{m.get('ver', 0)} joined from {ip}, total={len(clients)}")
                        await broadcast_peers()
                    elif t == "file_accept":
                        tid = m.get("transferId")
                        to = m.get("to")
                        # 未注册不可建路由; 缺字段直接忽略, 不抛异常杀连接
                        if my_id is None or not isinstance(tid, str) or not tid \
                                or not isinstance(to, str) or not to:
                            continue
                        m["from"] = my_id
                        # 数据块流向: 文件发送方(m["to"]) -> 文件接收方(my_id)
                        routes[tid] = {"from": to, "to": my_id, "ts": time.time()}
                        await forward(to, json.dumps(m))
                    elif t in FORWARD_TYPES:
                        if my_id is None:
                            continue  # 未注册不可中继
                        m["from"] = my_id
                        if t in ("file_done", "file_cancel"):
                            routes.pop(m.get("transferId"), None)  # 传输结束, 释放路由
                        to = m.get("to")
                        if isinstance(to, str) and to:
                            await forward(to, json.dumps(m))
                else:
                    # 二进制: 前36字节为 transferId
                    if len(data) > MAX_BIN_FRAME:
                        print(f"[!] oversize binary frame from {my_id or ip} ({len(data)}B), dropped")
                        continue
                    if len(data) > 36 and my_id is not None:
                        tid = data[:36].decode("ascii", errors="ignore")
                        r = routes.get(tid)
                        # 只转发路由登记的发送方发来的数据块, 防止伪造注入
                        if r and r["from"] == my_id:
                            await forward(r["to"], data)
            except websockets.ConnectionClosed:
                raise  # 断连交给外层统一处理
            except Exception as e:
                # 单条畸形帧不应杀死整条连接
                print(f"[!] bad frame from {my_id or ip}: {e!r}")
    except websockets.ConnectionClosed:
        pass  # 客户端异常断开,走 finally 清理
    finally:
        if ip is not None and ip_conns.get(ip, 0) > 0:
            ip_conns[ip] -= 1
            if ip_conns[ip] == 0:
                del ip_conns[ip]
        if my_id and clients.get(my_id, {}).get("ws") is ws:
            del clients[my_id]
            # 无论作为发送方还是接收方, 相关传输路由都清理掉
            for tid in [k for k, v in routes.items() if v["from"] == my_id or v["to"] == my_id]:
                del routes[tid]
            print(f"[-] {my_id} left, total={len(clients)}")
            await broadcast_peers()


# ---------- 管理后台 (HTTP) ----------

LOGIN_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录 · cloudSend 中继管理</title>
<style>
  * { box-sizing: border-box; margin: 0; }
  body { font: 14px/1.6 -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
         background: linear-gradient(135deg, #0b3d24, #07c160 140%);
         min-height: 100vh; display: flex; align-items: center; justify-content: center; }
  .box { background: #fff; border-radius: 14px; padding: 34px 32px 26px; width: 340px;
         box-shadow: 0 12px 40px rgba(0,0,0,.25); text-align: center; }
  .logo { width: 54px; height: 54px; border-radius: 14px; background: #07c160;
          color: #fff; font-size: 24px; line-height: 54px; margin: 0 auto 12px;
          font-weight: 700; }
  h1 { font-size: 17px; margin-bottom: 4px; }
  .sub { color: #999; font-size: 12px; margin-bottom: 20px; }
  input { width: 100%; padding: 10px 12px; border: 1px solid #ddd; border-radius: 8px;
          font-size: 14px; outline: none; }
  input:focus { border-color: #07c160; }
  button { width: 100%; margin-top: 14px; padding: 10px 0; border: 0; border-radius: 8px;
           background: #07c160; color: #fff; font-size: 14px; cursor: pointer; }
  button:disabled { opacity: .6; }
  .err { color: #fa5151; font-size: 12px; height: 18px; margin-top: 8px; }
</style>
</head>
<body>
<div class="box">
  <div class="logo">云</div>
  <h1>cloudSend 中继管理</h1>
  <div class="sub">请输入管理令牌登录</div>
  <form id="f">
    <input type="password" id="token" placeholder="Admin Token"
           autocomplete="current-password" autofocus>
    <button id="btn" type="submit">登 录</button>
  </form>
  <div class="err" id="err"></div>
</div>
<script>
document.getElementById('f').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = document.getElementById('btn');
  const err = document.getElementById('err');
  err.textContent = ''; btn.disabled = true;
  try {
    const r = await fetch('/api/login', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({token: document.getElementById('token').value.trim()}),
    });
    if (r.ok) { location.href = '/panel/devices'; return; }
    err.textContent = r.status === 401 ? '令牌错误, 请重试' : '登录失败 (' + r.status + ')';
  } catch (_) { err.textContent = '网络错误'; }
  btn.disabled = false;
});
</script>
</body>
</html>
"""

PANEL_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>cloudSend 中继管理</title>
<style>
  * { box-sizing: border-box; margin: 0; }
  body { font: 14px/1.6 -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
         background: #f3f4f6; color: #1a1a1a; display: flex; min-height: 100vh; }
  aside { width: 190px; background: #1f2d3d; flex-shrink: 0; position: sticky;
          top: 0; height: 100vh; }
  .brand { color: #fff; font-weight: 700; font-size: 15px; padding: 18px;
           border-bottom: 1px solid #ffffff14; }
  .brand span { color: #07c160; margin-right: 7px; }
  nav { padding: 10px 0; }
  nav a { display: block; padding: 11px 18px; color: #aeb9c5; text-decoration: none;
          font-size: 13.5px; border-left: 3px solid transparent; cursor: pointer; }
  nav a:hover { color: #fff; }
  nav a.active { background: #ffffff10; color: #fff; border-left-color: #07c160; }
  main { flex: 1; min-width: 0; }
  .topbar { background: #fff; border-bottom: 1px solid #e5e7eb; padding: 0 20px;
            height: 56px; display: flex; align-items: center; gap: 12px;
            position: sticky; top: 0; z-index: 5; }
  .topbar h1 { font-size: 15px; flex: 1; }
  .seg { display: flex; border: 1px solid #ddd; border-radius: 7px; overflow: hidden; }
  .seg button { border: 0; background: #fff; color: #555; padding: 5px 13px;
                font-size: 12.5px; cursor: pointer; }
  .seg button.on { background: #07c160; color: #fff; }
  .topbar .logout { background: transparent; border: 1px solid #ddd; color: #777;
                    padding: 5px 13px; border-radius: 7px; font-size: 12.5px;
                    cursor: pointer; }
  .topbar .logout:hover { border-color: #fa5151; color: #fa5151; }
  .content { padding: 18px 20px 30px; }
  .card { background: #fff; border-radius: 10px; padding: 14px 16px;
          box-shadow: 0 1px 3px rgba(0,0,0,.08); margin-bottom: 14px; }
  .card h2 { font-size: 14px; color: #555; margin-bottom: 10px; }
  input[type=text] { padding: 6px 10px; border: 1px solid #ddd; border-radius: 6px;
                     font-size: 13px; flex: 1; min-width: 0; }
  button { padding: 6px 14px; border: 0; border-radius: 6px; background: #07c160;
           color: #fff; font-size: 13px; cursor: pointer; }
  button.grey { background: #8a8a8a; }
  button.red { background: #fa5151; }
  button.small { padding: 3px 10px; font-size: 12px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  td, th { text-align: left; padding: 7px 8px; border-bottom: 1px solid #eee; }
  th { color: #888; font-weight: 500; }
  td .ops { display: flex; gap: 6px; flex-wrap: wrap; }
  /* 黑/白名单: 两个 card 横向双列 (窄屏堆叠) */
  .cols { display: flex; gap: 14px; align-items: flex-start; }
  .cols .card { flex: 1; min-width: 0; }
  /* 名单条目: 一行一条 */
  .entry { display: flex; align-items: center; gap: 8px; padding: 6px 2px;
           border-bottom: 1px solid #f0f0f0; font-family: monospace;
           font-size: 12.5px; word-break: break-all; }
  .entry span { flex: 1; min-width: 0; }
  .row { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
  .hint { color: #999; font-size: 12px; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
         background: #07c160; margin-right: 6px; }
  #toast { position: fixed; top: 14px; left: 50%; transform: translateX(-50%);
           background: #323232; color: #fff; padding: 8px 18px; border-radius: 6px;
           display: none; z-index: 9; }
  @media (max-width: 720px) {
    body { flex-direction: column; }
    aside { width: 100%; height: auto; position: static; display: flex;
            align-items: center; }
    .brand { border-bottom: 0; padding: 12px 14px; }
    nav { display: flex; padding: 0; }
    nav a { border-left: 0; border-bottom: 3px solid transparent; padding: 11px 12px; }
    nav a.active { border-bottom-color: #07c160; background: transparent; }
    .cols { flex-direction: column; align-items: stretch; }
  }
</style>
</head>
<body>
<aside>
  <div class="brand"><span>&#9679;</span>cloudSend</div>
  <nav id="nav">
    <a data-v="devices" href="/panel/devices">在线设备</a>
    <a data-v="black" href="/panel/black">黑名单</a>
    <a data-v="white" href="/panel/white">白名单</a>
  </nav>
</aside>
<main>
  <div class="topbar">
    <h1 id="pageTitle">在线设备</h1>
    <span class="hint">访问控制</span>
    <div class="seg" id="modeSeg">
      <button data-m="off" onclick="setMode('off')">关闭</button>
      <button data-m="whitelist" onclick="setMode('whitelist')">白名单</button>
      <button data-m="blacklist" onclick="setMode('blacklist')">黑名单</button>
    </div>
    <button class="logout" onclick="logout()">退出登录</button>
  </div>
  <div class="content">
    <section id="view-devices">
      <div class="card">
        <h2>在线设备 <span id="cnt" class="hint"></span>
          <button class="grey small" style="float:right" onclick="loadState()">刷新</button></h2>
        <table>
          <thead><tr><th></th><th>名称</th><th>设备 ID</th><th>IP</th><th>操作</th></tr></thead>
          <tbody id="clients"></tbody>
        </table>
      </div>
    </section>

    <section id="view-black" hidden>
      <div class="cols">
        <div class="card">
          <h2>设备 ID 黑名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="black-idInput" placeholder="设备唯一 id, 如 3f9a...-....">
            <button onclick="addEntry('black','ids')">添加</button>
          </div>
          <div id="black-ids"></div>
        </div>
        <div class="card">
          <h2>IP 黑名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="black-ipInput" placeholder="IP 或网段, 如 1.2.3.4 / 10.0.0.0/8">
            <button onclick="addEntry('black','ips')">添加</button>
          </div>
          <div id="black-ips"></div>
        </div>
      </div>
      <div class="hint">黑名单模式开启后, 名单内的设备/IP 将被拒绝接入; 已连接的会立即被踢下线。</div>
    </section>

    <section id="view-white" hidden>
      <div class="cols">
        <div class="card">
          <h2>设备 ID 白名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="white-idInput" placeholder="设备唯一 id, 如 3f9a...-....">
            <button onclick="addEntry('white','ids')">添加</button>
          </div>
          <div id="white-ids"></div>
        </div>
        <div class="card">
          <h2>IP 白名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="white-ipInput" placeholder="IP 或网段, 如 1.2.3.4 / 10.0.0.0/8">
            <button onclick="addEntry('white','ips')">添加</button>
          </div>
          <div id="white-ips"></div>
        </div>
      </div>
      <div class="hint">白名单模式开启后, 仅名单内的设备/IP 可以接入, 其余一律拒绝。</div>
    </section>
  </div>
</main>
<div id="toast"></div>

<script>
// ---------- 三个界面 (独立 URL, 可刷新/可后退) ----------
const TITLES = {devices: '在线设备', black: '黑名单', white: '白名单'};
function currentView() {
  const v = location.pathname.split('/').pop();
  return TITLES[v] ? v : 'devices';
}
function switchView(v, push = true) {
  for (const key of Object.keys(TITLES))
    document.getElementById('view-' + key).hidden = key !== v;
  for (const a of document.querySelectorAll('#nav a'))
    a.classList.toggle('active', a.dataset.v === v);
  document.getElementById('pageTitle').textContent = TITLES[v];
  document.title = TITLES[v] + ' · cloudSend 中继管理';
  if (push) history.pushState(null, '', '/panel/' + v);
}
document.querySelectorAll('#nav a').forEach(a =>
  a.addEventListener('click', (e) => { e.preventDefault(); switchView(a.dataset.v); }));
window.addEventListener('popstate', () => switchView(currentView(), false));

// 展示文本转义防注入; 事件参数一律 encodeURIComponent 传递 (防引号逃逸)
const esc = (s) => String(s ?? '').replace(/[&<>"']/g,
  (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
const u = encodeURIComponent;
const toast = (msg) => {
  const t = document.getElementById('toast');
  t.textContent = msg; t.style.display = 'block';
  setTimeout(() => t.style.display = 'none', 2000);
};

async function api(path, body) {
  const r = await fetch(path, {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body || {}),
  });
  if (r.status === 401) { location.href = '/'; throw new Error('unauthorized'); }
  return r.json();
}

function render(s) {
  for (const b of document.querySelectorAll('#modeSeg button'))
    b.classList.toggle('on', b.dataset.m === s.mode);
  const entry = (lst, kind) => (v) =>
    `<div class="entry"><span>${esc(v)}</span><button class="red small"
       onclick="removeEntry('${lst}','${kind}',decodeURIComponent('${u(v)}'))">移除</button></div>`;
  for (const lst of ['black', 'white'])
    for (const kind of ['ids', 'ips'])
      document.getElementById(`${lst}-${kind}`).innerHTML =
        s[lst][kind].map(entry(lst, kind)).join('') || '<div class="hint">空</div>';
  document.getElementById('cnt').textContent =
    s.clients.length ? `(${s.clients.length})` : '';
  document.getElementById('clients').innerHTML = s.clients.map(c =>
    `<tr><td><span class="dot"></span></td><td>${esc(c.name)}</td>
     <td style="font-family:monospace">${esc(c.id)}</td><td>${esc(c.ip || '-')}</td>
     <td><div class="ops">
       <button class="grey small"
         onclick="kickOne(decodeURIComponent('${u(c.id)}'))">踢下线</button>
       <button class="red small"
         onclick="addTo('black','ids',decodeURIComponent('${u(c.id)}'))">拉黑ID</button>
       ${c.ip ? `<button class="red small"
         onclick="addTo('black','ips',decodeURIComponent('${u(c.ip)}'))">拉黑IP</button>` : ''}
       <button class="small"
         onclick="addTo('white','ids',decodeURIComponent('${u(c.id)}'))">加白ID</button>
       ${c.ip ? `<button class="small"
         onclick="addTo('white','ips',decodeURIComponent('${u(c.ip)}'))">加白IP</button>` : ''}
     </div></td></tr>`
  ).join('') || '<tr><td colspan="5" class="hint">暂无在线设备</td></tr>';
}

async function loadState() {
  try {
    const r = await fetch('/api/state');
    if (r.status === 401) { location.href = '/'; return; }
    render(await r.json());
  } catch (e) { /* 网络抖动忽略, 下轮刷新重试 */ }
}
async function setMode(mode) { render(await api('/api/mode', {mode})); toast('模式已更新'); }
async function addEntry(lst, kind) {
  const el = document.getElementById(`${lst}-${kind === 'ids' ? 'idInput' : 'ipInput'}`);
  if (!el.value.trim()) return;
  render(await api('/api/add', {list: lst, kind, value: el.value.trim()}));
  el.value = ''; toast('已添加');
}
async function removeEntry(lst, kind, value) {
  render(await api('/api/remove', {list: lst, kind, value}));
}
async function kickOne(id) { render(await api('/api/kick', {id})); toast('已踢下线'); }
async function addTo(lst, kind, value) {
  render(await api('/api/add', {list: lst, kind, value, kick: lst === 'black'}));
  toast(lst === 'black' ? '已拉黑并踢下线' : '已加入白名单');
}
async function logout() {
  await fetch('/api/logout', {method: 'POST'});
  location.href = '/';
}
switchView(currentView(), false);
loadState();
setInterval(loadState, 5000);
</script>
</body>
</html>
"""

SESSION_TTL = 86400  # 管理会话有效期 (秒); 服务端重启会话全部失效, 需重新登录
sessions = {}  # sid -> 过期时间戳


def _new_session():
    sid = secrets.token_hex(16)
    sessions[sid] = time.time() + SESSION_TTL
    return sid


def make_admin_handler(token, loop):
    class AdminHandler(BaseHTTPRequestHandler):
        def _sid(self):
            for part in self.headers.get("Cookie", "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == "sid":
                    return v
            return None

        def _session_ok(self):
            exp = sessions.get(self._sid() or "", 0)
            if exp < time.time():
                sessions.pop(self._sid() or "", None)
                return False
            return True

        def _auth_ok(self):
            # 管理页面会话 cookie; Bearer 令牌留给脚本调用
            supplied = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            return self._session_ok() or supplied == token

        def _send_json(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_html(self, code, html):
            body = html.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _redirect(self, location, set_sid=None, clear_sid=False):
            self.send_response(302)
            self.send_header("Location", location)
            if set_sid is not None:
                self.send_header(
                    "Set-Cookie",
                    f"sid={set_sid}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_TTL}",
                )
            if clear_sid:
                self.send_header("Set-Cookie", "sid=; HttpOnly; Path=/; Max-Age=0")
            self.end_headers()

        def _state(self):
            s = acl.snapshot()
            s["clients"] = [
                {"id": i, "name": c["name"], "ip": c.get("ip")}
                for i, c in list(clients.items())
            ]
            return s

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/":
                # 启动时打印的免输链接: ?token= 验证通过直接建立会话进面板
                q = parse_qs(u.query)
                if token and q.get("token", [""])[0] == token:
                    return self._redirect("/panel/devices", set_sid=_new_session())
                if self._session_ok():
                    return self._redirect("/panel/devices")
                self._send_html(200, LOGIN_HTML)
            elif u.path == "/panel":
                if not self._session_ok():
                    return self._redirect("/")
                self._redirect("/panel/devices")
            elif u.path in ("/panel/devices", "/panel/black", "/panel/white"):
                if not self._session_ok():
                    return self._redirect("/")
                self._send_html(200, PANEL_HTML)
            elif u.path == "/api/state":
                if not self._auth_ok():
                    return self._send_json(401, {"error": "unauthorized"})
                self._send_json(200, self._state())
            else:
                self._send_json(404, {"error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            try:
                length = int(self.headers.get("Content-Length", 0))
                m = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                return self._send_json(400, {"error": "bad request"})
            if u.path == "/api/login":
                if not token or str(m.get("token", "")) != token:
                    return self._send_json(401, {"error": "bad token"})
                self._redirect("/panel/devices", set_sid=_new_session())
                return
            if u.path == "/api/logout":
                sessions.pop(self._sid() or "", None)
                self._redirect("/", clear_sid=True)
                return
            if not self._auth_ok():
                return self._send_json(401, {"error": "unauthorized"})
            if u.path == "/api/mode":
                mode = m.get("mode")
                if mode not in ("off", "whitelist", "blacklist"):
                    return self._send_json(400, {"error": "bad mode"})
                acl.set_mode(mode)
                print(f"[admin] mode -> {mode}")
                enforce_acl(loop)  # 模式收紧时立即踢掉不再允许的设备
            elif u.path in ("/api/add", "/api/remove"):
                lst, kind = m.get("list"), m.get("kind")
                value = str(m.get("value", ""))
                if lst not in ("black", "white") or kind not in ("ids", "ips") \
                        or not value.strip():
                    return self._send_json(400, {"error": "bad entry"})
                if u.path == "/api/add":
                    acl.add(lst, kind, value)
                    print(f"[admin] add {lst}/{kind}: {value}")
                    # 黑名单模式下加黑即踢 (或显式要求 kick)
                    if m.get("kick") or (
                        lst == "black" and acl.snapshot()["mode"] == "blacklist"
                    ):
                        enforce_acl(loop)
                else:
                    acl.remove(lst, kind, value)
                    print(f"[admin] remove {lst}/{kind}: {value}")
            elif u.path == "/api/kick":
                did = str(m.get("id", ""))
                c = clients.get(did)
                if not c:
                    return self._send_json(404, {"error": "not online"})
                print(f"[admin] kick {did} ({c.get('ip')})")

                async def _k():
                    await kick(c["ws"], "kick")

                asyncio.run_coroutine_threadsafe(_k(), loop)
            else:
                return self._send_json(404, {"error": "not found"})
            self._send_json(200, self._state())

        def log_message(self, *args):
            pass  # 静默 HTTP 访问日志

    return AdminHandler


async def main():
    global acl
    p = argparse.ArgumentParser(description="cloudSend relay server")
    p.add_argument("port", nargs="?", type=int, default=8787)
    p.add_argument("--admin-port", type=int, default=8788)
    p.add_argument("--admin-token", default=None)
    p.add_argument("--acl-file", default="server_acl.json")
    args = p.parse_args()

    acl = Acl(args.acl_file)
    token = args.admin_token or os.environ.get("ADMIN_TOKEN") or secrets.token_hex(8)

    logging.getLogger("websockets.server").addFilter(_HandshakeFailFilter())

    loop = asyncio.get_running_loop()
    httpd = ThreadingHTTPServer(("0.0.0.0", args.admin_port), make_admin_handler(token, loop))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"[admin] 管理后台 (打开即登录, 远程访问把 127.0.0.1 换成服务器IP):")
    print(f"[admin]   http://127.0.0.1:{args.admin_port}/?token={token}")

    asyncio.create_task(sweep_routes())
    async with websockets.serve(handle, "0.0.0.0", args.port, max_size=None):
        print(f"cloudSend relay listening on ws://0.0.0.0:{args.port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
