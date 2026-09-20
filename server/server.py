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
  - 名单条目可设有效期 (TTL), 过期自动移除; 白名单模式下条目到期会立即踢掉不再允许的设备
  - 登录限速: 同一 IP 10 分钟内失败 5 次锁定 15 分钟
  - 统计页: 累计流量/连接/传输数, 分设备流量排行, 实时速率 (SSE 推送)
  - 带宽上限: 单设备 / 单传输 令牌桶限速, 统计页可在线调整 (0=不限)

接入密码 (server 级密钥):
  启动指定 --access-key (或环境变量 ACCESS_KEY) 后, 客户端 register 必须携带
  相同的 "key" 字段, 否则被踢 (reason=auth); 同一 IP 10 分钟内错 5 次封禁
  10 分钟 (reason=auth_ban)

P2P 打洞辅助:
  转发 p2p_request / p2p_accept / p2p_decline / p2p_abort 信令, 并注入发送方
  的公网 IP ("fromIp") 供对端尝试 TCP 直连; 打洞失败客户端自行回落中继

依赖: pip install websockets
运行: python server.py [端口, 默认8787] [--admin-port 8788] [--admin-token xxx]
      [--access-key xxx] [--acl-file server_acl.json] [--stats-file server_stats.json]
      未指定 --admin-token 时每次启动随机生成并打印 (也可设环境变量 ADMIN_TOKEN)
"""

import argparse
import asyncio
import collections
import ipaddress
import json
import logging
import os
import queue
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import websockets

clients = {}   # deviceId -> {"name": str, "ws": WebSocket, "avatar": str|None, "ip": str|None, "ver": int}
routes = {}    # transferId -> {"from": 发送方id, "to": 接收方id, "ts": 创建时间}

ROUTE_TTL = 3600  # 秒: 超时未完成的传输路由自动清理, 防止泄漏

# ---------- 防护: 帧大小上限 / 单IP连接数 / register 限流 ----------
MAX_TEXT_FRAME = 512 * 1024       # 文本帧上限 (JSON 控制消息, 含 base64 头像)
MAX_BIN_FRAME = 1024 * 1024 + 64  # 二进制帧上限 (文件块 + 36字节 transferId 头)
MAX_CONNS_PER_IP = 16             # 单 IP 并发连接上限
REGISTER_PER_MIN = 30             # 单 IP 每分钟 register 上限 (正常客户端 <5)

# ---------- 接入密码 (server 级密钥) ----------
ACCESS_KEY = None  # main() 里按 --access-key / ACCESS_KEY 初始化; None = 不启用

# 仅在显式声明位于受信反向代理之后时才采信 X-Forwarded-For,
# 否则直连客户端可伪造该头绕过 IP 黑白名单/限流/登录锁定
TRUST_PROXY = False
AUTH_FAIL_LIMIT = 5     # 窗口内失败次数上限
AUTH_FAIL_WINDOW = 600  # 失败计数窗口 (秒)
AUTH_BAN_SEC = 600      # 触发上限后的封禁时长 (秒)

auth_fails = {}  # ip -> [最近失败时间戳...]
auth_bans = {}   # ip -> 封禁截止时间戳

# ---------- 管理后台登录限速 ----------
LOGIN_FAIL_LIMIT = 5
LOGIN_FAIL_WINDOW = 600
LOGIN_LOCK_SEC = 900  # 锁定时长 (秒)

login_fails = {}  # ip -> [最近失败时间戳...]
login_locks = {}  # ip -> 锁定截止时间戳

ip_conns = {}  # ip -> 当前连接数
reg_hist = {}  # ip -> [最近 register 时间戳...]


# ---------- 访问控制 (黑/白名单, 各自独立) ----------

class Acl:
    """线程安全的名单存取 + 判定; 持久化为 JSON 文件
    黑名单/白名单各有一套独立的 设备ID + IP 名单, 互不干扰

    条目格式 (文件内): 永久条目为纯字符串, 带有效期的为 {"v": 值, "exp": 到期的epoch秒};
    内存中统一为 {"v": str, "exp": float|None}; 过期条目在访问时惰性跳过,
    由 sweep_expired() 定期物理清除。
    另存带宽上限 limits: {"device_bps": 单设备字节/秒, "transfer_bps": 单传输字节/秒,
    "global_bps": 服务器总体字节/秒}, 0=不限"""

    LISTS = ("black", "white")
    KINDS = ("ids", "ips")

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {
            "mode": "off",
            "black": {"ids": [], "ips": []},
            "white": {"ids": [], "ips": []},
            "limits": {"device_bps": 0, "transfer_bps": 0, "global_bps": 0},
        }
        self.load()

    @staticmethod
    def _norm_entry(x):
        """文件条目 -> 内存条目; 无法识别的返回 None"""
        if isinstance(x, dict):
            v = str(x.get("v", ""))
            if not v:
                return None
            exp = x.get("exp")
            return {"v": v, "exp": float(exp) if isinstance(exp, (int, float)) else None}
        return {"v": str(x), "exp": None}

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
            with self.lock:
                self.data["mode"] = d.get("mode", "off")
                lim = d.get("limits")
                if isinstance(lim, dict):
                    for k in ("device_bps", "transfer_bps", "global_bps"):
                        v = lim.get(k)
                        if isinstance(v, (int, float)) and v >= 0:
                            self.data["limits"][k] = int(v)
                if "black" in d or "white" in d:
                    for lst in self.LISTS:
                        for kind in self.KINDS:
                            entries = []
                            for x in d.get(lst, {}).get(kind, []):
                                e = self._norm_entry(x)
                                if e is not None:
                                    entries.append(e)
                            self.data[lst][kind] = entries
                else:
                    # 旧格式迁移: 原先黑白共用的 ids/ips 同时进两套名单,
                    # 这样无论当时处于哪种模式, 行为都保持不变
                    old_ids = [str(x) for x in d.get("ids", [])]
                    old_ips = [str(x) for x in d.get("ips", [])]
                    for lst in self.LISTS:
                        self.data[lst] = {
                            "ids": [{"v": v, "exp": None} for v in old_ids],
                            "ips": [{"v": v, "exp": None} for v in old_ips],
                        }
        except FileNotFoundError:
            pass  # 首次运行用默认 (关闭模式)
        except Exception as e:
            # 文件存在但损坏: 大声告警而不是静默回默认, 避免管理员以为黑名单还在生效
            print(f"[!] acl file {self.path} failed to load, using defaults (mode=off): {e}")

    def save(self):
        try:
            with self.lock:
                d = json.loads(json.dumps(self.data))
            # 写盘时永久条目退化为纯字符串 (保持文件可读/旧版可回退)
            for lst in self.LISTS:
                for kind in self.KINDS:
                    d[lst][kind] = [
                        e["v"] if e["exp"] is None else {"v": e["v"], "exp": e["exp"]}
                        for e in d[lst][kind]
                    ]
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=2)
            # 原子替换: 避免崩溃/磁盘写满留下半截 JSON, 重启后 ACL 静默失效
            os.replace(tmp, self.path)
        except Exception as e:
            print(f"[!] acl save failed: {e}")

    def snapshot(self, now=None):
        """面板/API 用: 条目带过期时间; 已过期的条目不出现"""
        now = now if now is not None else time.time()
        with self.lock:
            return {
                "mode": self.data["mode"],
                "limits": dict(self.data["limits"]),
                "black": {
                    k: [
                        {"value": e["v"], "expires": e["exp"]}
                        for e in v
                        if e["exp"] is None or e["exp"] > now
                    ]
                    for k, v in self.data["black"].items()
                },
                "white": {
                    k: [
                        {"value": e["v"], "expires": e["exp"]}
                        for e in v
                        if e["exp"] is None or e["exp"] > now
                    ]
                    for k, v in self.data["white"].items()
                },
            }

    def _values(self, lst, kind, now=None):
        """指定名单的有效值列表 (跳过过期条目)"""
        now = now if now is not None else time.time()
        with self.lock:
            return [
                e["v"]
                for e in self.data[lst][kind]
                if e["exp"] is None or e["exp"] > now
            ]

    def set_mode(self, mode):
        assert mode in ("off", "whitelist", "blacklist")
        with self.lock:
            self.data["mode"] = mode
        self.save()

    def get_limits(self):
        with self.lock:
            return dict(self.data["limits"])

    def set_limit(self, key, bps):
        assert key in ("device_bps", "transfer_bps", "global_bps")
        with self.lock:
            self.data["limits"][key] = max(0, int(bps))
        self.save()

    def add(self, lst, kind, value, ttl_sec=None):
        """ttl_sec: 有效期秒数; None/<=0 为永久"""
        assert lst in self.LISTS and kind in self.KINDS
        value = value.strip()
        if not value:
            return False
        exp = time.time() + ttl_sec if ttl_sec and ttl_sec > 0 else None
        with self.lock:
            entries = self.data[lst][kind]
            for e in entries:
                if e["v"] == value:
                    return False  # 已存在 (更新有效期请删了再加)
            entries.append({"v": value, "exp": exp})
        self.save()
        return True

    def remove(self, lst, kind, value):
        assert lst in self.LISTS and kind in self.KINDS
        with self.lock:
            entries = self.data[lst][kind]
            for i, e in enumerate(entries):
                if e["v"] == value:
                    del entries[i]
                    break
            else:
                return False
        self.save()  # 锁外调用: save() 内部会再次取锁 (非可重入)
        return True

    def sweep_expired(self):
        """物理清除过期条目; 返回清除数量 (有变化时持久化一次)"""
        now = time.time()
        removed = 0
        with self.lock:
            for lst in self.LISTS:
                for kind in self.KINDS:
                    entries = self.data[lst][kind]
                    keep = [e for e in entries if e["exp"] is None or e["exp"] > now]
                    removed += len(entries) - len(keep)
                    self.data[lst][kind] = keep
        if removed:
            self.save()
        return removed

    @staticmethod
    def _ip_hit(entry, ip):
        """单地址精确匹配或 CIDR 网段包含"""
        try:
            return ipaddress.ip_address(ip) in ipaddress.ip_network(entry, strict=False)
        except ValueError:
            return entry == ip  # 非法条目按字符串精确匹配兜底

    def hit(self, lst, device_id=None, ip=None):
        """是否命中指定名单 (black/white)"""
        id_hit = device_id is not None and device_id in self._values(lst, "ids")
        ip_hit = ip is not None and any(
            self._ip_hit(e, ip) for e in self._values(lst, "ips")
        )
        return id_hit or ip_hit

    def id_hit(self, lst, device_id):
        return device_id is not None and device_id in self._values(lst, "ids")

    def ip_hit(self, lst, ip):
        return ip is not None and any(
            self._ip_hit(e, ip) for e in self._values(lst, "ips")
        )


acl = None  # main() 里按 --acl-file 初始化


# ---------- 流量统计 (累计计数 + 分设备流量; 定期持久化) ----------

class Stats:
    """中继流量计数器; 线程安全; 每分钟落盘一次, 重启不清零"""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.started = time.time()
        self.d = {
            "total_bytes": 0,   # 中继转发的总字节数 (文本 + 二进制)
            "text_bytes": 0,    # 控制消息字节
            "bin_bytes": 0,     # 文件数据块字节
            "messages": 0,      # 转发的控制消息条数
            "bin_frames": 0,    # 转发的二进制帧数
            "connections": 0,   # 累计接入连接数
            "transfers": 0,     # 累计建立的传输路由数
            "kicks": 0,         # 累计踢下线次数
            "auth_fails": 0,    # 累计接入密码失败次数
        }
        self.per_device = {}  # deviceId -> 累计中继字节数 (发送侧统计)
        # 流量历史环形缓冲: [分钟起始ts, 该分钟二进制字节数], 保留 24h, 随盘持久化
        self.traffic = collections.deque(maxlen=24 * 60)
        self._last_bin = 0
        self.load()
        self._last_bin = self.d["bin_bytes"]

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
            with self.lock:
                for k in self.d:
                    v = d.get(k)
                    if isinstance(v, (int, float)) and v >= 0:
                        self.d[k] = int(v)
                pd = d.get("per_device")
                if isinstance(pd, dict):
                    self.per_device = {
                        str(k): int(v)
                        for k, v in pd.items()
                        if isinstance(v, (int, float)) and v > 0
                    }
                th = d.get("traffic")
                if isinstance(th, list):
                    cutoff = time.time() - 24 * 3600
                    for x in th:
                        if (
                            isinstance(x, (list, tuple))
                            and len(x) == 2
                            and x[0] > cutoff
                            and isinstance(x[1], (int, float))
                            and x[1] >= 0
                        ):
                            self.traffic.append([int(x[0]), int(x[1])])
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"[!] stats file {self.path} failed to load, using defaults: {e}")

    def save(self):
        try:
            with self.lock:
                d = dict(self.d)
                # 分设备只保留流量前 200 名, 防长期使用后文件膨胀
                top = sorted(
                    self.per_device.items(), key=lambda kv: kv[1], reverse=True
                )[:200]
                d["per_device"] = dict(top)
                d["traffic"] = [list(x) for x in self.traffic]
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False, indent=2)
            # 原子替换, 防半截文件 (同 acl.save)
            os.replace(tmp, self.path)
        except Exception as e:
            print(f"[!] stats save failed: {e}")

    def add(self, key, n=1):
        with self.lock:
            self.d[key] = self.d.get(key, 0) + n

    def sample_traffic(self):
        """每分钟一次: 把这一分钟的二进制字节增量记入环形缓冲"""
        with self.lock:
            total = self.d["bin_bytes"]
            delta = max(0, total - self._last_bin)
            self._last_bin = total
            minute = int(time.time() // 60 * 60)
            if self.traffic and self.traffic[-1][0] == minute:
                self.traffic[-1][1] += delta
            else:
                self.traffic.append([minute, delta])

    def traffic_buckets(self, span_sec=300, hours=24):
        """按 span 聚合最近 hours 小时: [[桶起始ts, 字节]...] (面板曲线用)"""
        start = time.time() - hours * 3600
        agg = {}
        with self.lock:
            for ts, b in self.traffic:
                if ts >= start:
                    k = ts // span_sec * span_sec
                    agg[k] = agg.get(k, 0) + b
        return [[k, agg[k]] for k in sorted(agg)]

    def add_device_bytes(self, device_id, n):
        with self.lock:
            self.per_device[device_id] = self.per_device.get(device_id, 0) + n
            # 内存里也别无限涨: 超过 500 个设备时裁掉流量最小的一批
            if len(self.per_device) > 500:
                keep = sorted(
                    self.per_device.items(), key=lambda kv: kv[1], reverse=True
                )[:300]
                self.per_device = dict(keep)

    def summary(self):
        with self.lock:
            s = dict(self.d)
            s["total_bytes"] = s["text_bytes"] + s["bin_bytes"]
            s["uptime"] = int(time.time() - self.started)
            s["per_device"] = dict(
                sorted(self.per_device.items(), key=lambda kv: kv[1], reverse=True)[:50]
            )
            return s


stats = None  # main() 里按 --stats-file 初始化


# ---------- 带宽上限 (令牌桶; 总体 + 单设备 + 单传输三档) ----------

class Bucket:
    """asyncio 令牌桶: rate 字节/秒 (0=不限), 突发上限 max(rate/2, 256KB);
    并发取用通过令牌透支 (允许为负) 自然排队"""

    def __init__(self, rate):
        self.rate = rate
        # 满桶启动: 新设备/新传输带初始突发能力, 小文件不受限速影响
        self.tokens = float(max(rate / 2, 256 * 1024)) if rate > 0 else 0.0
        self.ts = time.monotonic()
        self.lock = asyncio.Lock()

    def set_rate(self, rate):
        self.rate = rate

    async def take(self, n):
        if self.rate <= 0 or n <= 0:
            return
        async with self.lock:
            now = time.monotonic()
            cap = max(self.rate / 2, 256 * 1024)
            self.tokens = min(cap, self.tokens + (now - self.ts) * self.rate)
            self.ts = now
            self.tokens -= n
            if self.tokens >= 0:
                return
            wait = -self.tokens / self.rate
        await asyncio.sleep(min(wait, 5.0))


device_buckets = {}     # deviceId -> Bucket (发送侧: 该设备经服务器转发的总速率)
transfer_buckets = {}   # transferId -> Bucket (随路由创建/销毁)
global_bucket = Bucket(0)  # 服务器总体速率 (所有转发的二进制流量共用)


def _device_bucket(device_id):
    b = device_buckets.get(device_id)
    if b is None:
        b = Bucket(acl.get_limits()["device_bps"])
        device_buckets[device_id] = b
    return b


async def throttle(sender_id, tid, n):
    """二进制数据块转发前的限速: 同时受总体桶、发送方设备桶与传输桶约束"""
    await global_bucket.take(n)
    await _device_bucket(sender_id).take(n)
    b = transfer_buckets.get(tid)
    if b is not None:
        await b.take(n)


def apply_limits():
    """limits 变更后同步到所有活跃的桶"""
    lim = acl.get_limits()
    global_bucket.set_rate(lim["global_bps"])
    # 本函数在管理 HTTP 线程执行, 而事件循环线程会并发增删 buckets,
    # 先拍快照再迭代, 避免 RuntimeError: dictionary changed size during iteration
    for b in list(device_buckets.values()):
        b.set_rate(lim["device_bps"])
    for b in list(transfer_buckets.values()):
        b.set_rate(lim["transfer_bps"])


class _HandshakeFailFilter(logging.Filter):
    """websockets 对握手失败(非 WS 的 HTTP 请求碰到 WS 端口, 公网扫描很常见)
    会打整段堆栈, 太吵; 压成一行提示"""

    def filter(self, record):
        if record.getMessage().startswith("opening handshake failed"):
            print("[~] rejected non-websocket handshake (port scan or http probe)")
            return False
        return True


def client_ip(ws):
    """反代场景 (--trust-proxy) 优先取 X-Forwarded-For 首个地址, 否则用对端地址"""
    if TRUST_PROXY:
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


# ---------- 面板实时推送 (SSE) ----------

_sse_lock = threading.Lock()
_sse_subs = set()  # queue.Queue 集合, 每个订阅的 SSE 连接一个


def publish_state():
    """把最新状态推给所有面板 SSE 订阅者 (任意线程可调用)"""
    try:
        payload = json.dumps(build_state(), ensure_ascii=False)
    except Exception:
        return
    with _sse_lock:
        subs = list(_sse_subs)
    for q in subs:
        try:
            q.put_nowait(payload)
        except queue.Full:
            pass  # 订阅者消费不过来时丢帧, 下一帧状态自然覆盖


def build_state():
    """面板完整状态: ACL + 在线设备 + 统计"""
    s = acl.snapshot()
    s["clients"] = [
        {"id": i, "name": c["name"], "ip": c.get("ip"), "ver": c.get("ver", 0)}
        for i, c in list(clients.items())
    ]
    s["stats"] = stats.summary()
    s["traffic"] = stats.traffic_buckets()  # 24h, 5分钟一桶
    s["access_key_on"] = ACCESS_KEY is not None
    return s


# ---------- 中继逻辑 ----------

async def broadcast_peers():
    msg = json.dumps({
        "type": "peers",
        "peers": [
            {
                "id": i,
                "name": c["name"],
                "avatar": c.get("avatar"),
                "platform": c.get("platform"),
                "ver": c.get("ver", 0),
            }
            for i, c in clients.items()
        ],
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
            transfer_buckets.pop(tid, None)
        if stale:
            print(f"[~] swept {len(stale)} stale transfer routes")


async def periodic_maintenance(loop):
    """每分钟: 清除过期 ACL 条目 (白名单模式下收紧后踢人) + 统计落盘
    + 流量采样 + 限流/封禁/会话字典的死条目清理 (防长期运行内存缓涨)"""
    while True:
        await asyncio.sleep(60)
        try:
            removed = acl.sweep_expired()
            if removed:
                print(f"[~] swept {removed} expired acl entries")
                if acl.snapshot()["mode"] == "whitelist":
                    enforce_acl(loop)  # 白名单条目到期 = 收紧, 立即踢掉不再允许的设备
                publish_state()
            stats.sample_traffic()
            stats.save()
            now = time.time()
            # 计数窗口型: 最后一条记录超出窗口即整项删除
            for d, win in (
                (reg_hist, 60),
                (auth_fails, AUTH_FAIL_WINDOW),
                (login_fails, LOGIN_FAIL_WINDOW),
            ):
                for ip in [k for k, v in d.items() if not v or now - v[-1] > win]:
                    d.pop(ip, None)
            # 截止时刻型: 已过期的封禁/锁定/会话
            for d in (auth_bans, login_locks, sessions):
                for k in [k for k, v in d.items() if v < now]:
                    d.pop(k, None)
        except Exception as e:
            print(f"[!] maintenance failed: {e}")


async def sse_tick():
    """每 5 秒推一次状态 (统计页实时速率/计数)"""
    while True:
        await asyncio.sleep(5)
        with _sse_lock:
            has_subs = bool(_sse_subs)
        if has_subs:
            publish_state()


async def kick(ws, reason="kick"):
    """踢下线: 通知后关闭 (4403=应用层自定义'无权限')
    reason: kick=手动踢下线 / black_id=拉黑设备ID / black_ip=拉黑IP / white=不在白名单
            / auth=接入密码错误 / auth_ban=密码错误过多被封禁 / rate=限流 / replaced=被顶替"""
    stats.add("kicks")
    try:
        await ws.send(json.dumps({"type": "blocked", "reason": reason}))
    except Exception:
        pass
    try:
        await ws.close(code=4403, reason=reason)
    except Exception:
        pass


def auth_ban_remaining(ip):
    """接入密码封禁剩余秒数 (0=未封禁); 顺手清理过期记录"""
    until = auth_bans.get(ip, 0)
    left = int(until - time.time())
    if left <= 0:
        auth_bans.pop(ip, None)
        return 0
    return left


def check_access_key(ip, key):
    """校验接入密码; 返回拒绝原因 (None=通过): auth=密码错误 / auth_ban=已被封禁"""
    if ACCESS_KEY is None:
        return None
    if auth_ban_remaining(ip) > 0:
        return "auth_ban"
    if key == ACCESS_KEY:
        return None
    # 记录失败; 窗口内超限则封禁
    stats.add("auth_fails")
    now = time.time()
    hist = [x for x in auth_fails.get(ip, []) if now - x < AUTH_FAIL_WINDOW]
    hist.append(now)
    auth_fails[ip] = hist
    if len(hist) >= AUTH_FAIL_LIMIT:
        auth_bans[ip] = now + AUTH_BAN_SEC
        auth_fails.pop(ip, None)
        print(f"[x] {ip} banned for {AUTH_BAN_SEC}s (too many auth failures)")
        return "auth_ban"
    return "auth"


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
# enc: E2EE 加密信封 (客户端 v3+, 内容服务器不可读, 仅按 to 路由)
FORWARD_TYPES = (
    "chat", "chat_ack", "chat_reject", "chat_recall", "chat_read",
    "clip_text",
    "file_offer", "file_reject",
    "file_done", "file_progress", "file_result", "file_cancel",
    # 并行车道控制消息 (正常只在 LAN 直连用, 兜底走中继时也得能转发)
    "file_parallel", "file_seg_hash", "file_seg_reset",
    "file_accept_pending", "file_instant", "file_instant_nack",
    "fs_list", "fs_list_result", "fs_get",
    "fs_thumb", "fs_thumb_result",
    "enc",
)

# P2P 打洞信令: 除注入 from 外再注入 fromIp (发送方公网 IP), 供对端尝试直连
P2P_TYPES = ("p2p_request", "p2p_accept", "p2p_decline", "p2p_abort")


async def handle(ws):
    my_id = None
    ip = client_ip(ws)
    stats.add("connections")
    # 连接级拦截: 仅黑名单模式在此拒绝 (IP 命中黑名单即踢)。
    # 白名单模式不能在此拒绝: 设备 id 白名单要等 register 才知道, 届时再校验
    if acl.snapshot()["mode"] == "blacklist" and acl.ip_hit("black", ip):
        print(f"[x] connection from {ip} refused (blacklist)")
        await kick(ws, "black_ip")
        return
    # 接入密码封禁中的 IP 直接拒 (密码本身的校验在 register 时做)
    if ACCESS_KEY is not None and auth_ban_remaining(ip) > 0:
        print(f"[x] connection from {ip} refused (auth ban)")
        await kick(ws, "auth_ban")
        return
    # 单 IP 并发连接上限 (反代场景所有客户端共享出口 IP, 阈值别定太低)
    if ip is not None:
        n = ip_conns.get(ip, 0)
        if n >= MAX_CONNS_PER_IP:
            print(f"[x] connection from {ip} refused (too many connections)")
            await kick(ws, "rate")
            return
        ip_conns[ip] = n + 1
    # 注册看门狗: 连上 30s 内不发 register 的僵尸连接踢掉, 否则永久占坑且面板不可见
    async def _reg_watchdog():
        await asyncio.sleep(30)
        if my_id is None:
            print(f"[x] {ip} never registered in 30s, kicked")
            await kick(ws, "register_timeout")
    reg_watchdog = asyncio.ensure_future(_reg_watchdog())
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
                        # 接入密码校验 (在限流计数之前, 免得输错密码也消耗 register 配额)
                        ar = check_access_key(ip, m.get("key"))
                        if ar:
                            print(f"[x] register {rid} from {ip} refused ({ar})")
                            await kick(ws, ar)
                            return
                        my_id = rid
                        # 同一连接换 id 重新注册: 先清掉旧 id 的映射。
                        # 必须在限流/拦截踢人之前做, 否则 finally 按新 id 清理,
                        # 旧 id 的映射残留成永久幽灵在线条目
                        for k, v in list(clients.items()):
                            if v["ws"] is ws and k != my_id:
                                del clients[k]
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
                        # 同 id 已有旧连接: 先原子占位再踢旧连接 (防并行劫持)。
                        # 顺序不能反: kick 是 await, 两个并发注册会都在 kick 处
                        # 让出再先后覆盖 clients[id], 先到位的连接成为从未被踢的
                        # 幽灵 (二进制帧只校验 my_id, 可向在任者的传输注入伪造块)。
                        # 先占位后每个注册者恰好踢掉自己的前任, 只有最后写者存活
                        old = clients.get(my_id)
                        is_new = old is None
                        clients[my_id] = {
                            "name": m.get("name", "Unknown"),
                            "ws": ws,
                            "avatar": m.get("avatar"),
                            "platform": m.get("platform"),
                            "ip": ip,
                            "ver": m.get("ver") if isinstance(m.get("ver"), int) else 0,
                        }
                        if old is not None and old["ws"] is not ws:
                            print(f"[~] {my_id} re-registered, kicking old connection")
                            await kick(old["ws"], "replaced")
                        print(f"[+] {m.get('name')} ({my_id}) v{m.get('ver', 0)} joined from {ip}, total={len(clients)}")
                        await broadcast_peers()
                        if is_new:
                            publish_state()
                    elif t == "file_accept":
                        tid = m.get("transferId")
                        to = m.get("to")
                        # 未注册不可建路由; 缺字段直接忽略, 不抛异常杀连接
                        if my_id is None or not isinstance(tid, str) or not tid \
                                or not isinstance(to, str) or not to:
                            continue
                        # 发送方必须在线: 否则路由+带宽桶空转到 TTL 才被清扫
                        if to not in clients:
                            continue
                        r = routes.get(tid)
                        if r is not None and r["to"] != my_id:
                            # 路由已属于其他接收方: 拒绝覆盖。任意设备凭 transferId
                            # 发 file_accept 即可把发送方的文件流重定向给自己的漏洞
                            print(f"[!] {my_id} route hijack refused (tid owned by {r['to']})")
                            continue
                        m["from"] = my_id
                        if r is None:
                            # 数据块流向: 文件发送方(m["to"]) -> 文件接收方(my_id)
                            routes[tid] = {"from": to, "to": my_id, "ts": time.time()}
                            # 单传输带宽桶随路由创建 (file_done/cancel/路由清理时释放)
                            transfer_buckets[tid] = Bucket(acl.get_limits()["transfer_bps"])
                            stats.add("transfers")
                        else:
                            # 同一接收方重复接受 (断点续传): 刷新路由, 不重建桶
                            r["ts"] = time.time()
                        stats.add("text_bytes", len(data))
                        stats.add("messages")
                        await forward(to, json.dumps(m))
                    elif t in FORWARD_TYPES or t in P2P_TYPES:
                        if my_id is None:
                            continue  # 未注册不可中继
                        m["from"] = my_id
                        if t in P2P_TYPES:
                            # 打洞信令注入发送方公网 IP, 对端据此尝试 TCP 直连
                            m["fromIp"] = ip
                        if t in ("file_done", "file_cancel"):
                            routes.pop(m.get("transferId"), None)  # 传输结束, 释放路由
                            transfer_buckets.pop(m.get("transferId"), None)
                        to = m.get("to")
                        if isinstance(to, str) and to:
                            stats.add("text_bytes", len(data))
                            stats.add("messages")
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
                            # 数据在流即活跃: 刷新路由时间戳, 防超过 TTL 的
                            # 大文件/慢速传输中途被清扫, 后续帧全丢传输挂死
                            r["ts"] = time.time()
                            stats.add("bin_bytes", len(data))
                            stats.add("bin_frames")
                            stats.add_device_bytes(my_id, len(data))
                            await throttle(my_id, tid, len(data))  # 带宽上限
                            await forward(r["to"], data)
            except websockets.ConnectionClosed:
                raise  # 断连交给外层统一处理
            except Exception as e:
                # 单条畸形帧不应杀死整条连接
                print(f"[!] bad frame from {my_id or ip}: {e!r}")
    except websockets.ConnectionClosed:
        pass  # 客户端异常断开,走 finally 清理
    finally:
        reg_watchdog.cancel()
        if ip is not None and ip_conns.get(ip, 0) > 0:
            ip_conns[ip] -= 1
            if ip_conns[ip] == 0:
                del ip_conns[ip]
        if my_id and clients.get(my_id, {}).get("ws") is ws:
            del clients[my_id]
            device_buckets.pop(my_id, None)
            # 无论作为发送方还是接收方, 相关传输路由都清理掉
            for tid in [k for k, v in routes.items() if v["from"] == my_id or v["to"] == my_id]:
                del routes[tid]
                transfer_buckets.pop(tid, None)
            print(f"[-] {my_id} left, total={len(clients)}")
            await broadcast_peers()
            publish_state()


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
    if (r.status === 429) {
      const d = await r.json().catch(() => ({}));
      const s = d.retry_after || 0;
      err.textContent = `失败次数过多, 已锁定, 请 ${Math.ceil(s / 60)} 分钟后再试`;
    } else {
      err.textContent = r.status === 401 ? '令牌错误, 请重试' : '登录失败 (' + r.status + ')';
    }
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
  /* 有效期小输入框 + 统计卡片 */
  input.ttl { flex: 0 0 62px; min-width: 0; }
  .statgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
              gap: 12px; margin-bottom: 14px; }
  .stat { background: #fff; border-radius: 10px; padding: 12px 14px;
          box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .stat .k { color: #888; font-size: 12px; }
  .stat .v { font-size: 19px; font-weight: 600; margin-top: 3px;
             font-variant-numeric: tabular-nums; }
  .stat .v small { font-size: 12px; color: #07c160; font-weight: 500; }
  .exp { color: #b26a00; font-size: 11px; font-family: inherit; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
         background: #07c160; margin-right: 6px; }
  #toast { position: fixed; top: 14px; left: 50%; transform: translateX(-50%);
           background: #323232; color: #fff; padding: 8px 18px; border-radius: 6px;
           display: none; z-index: 9; }
  /* 操作选择弹窗 (拉黑/加白) */
  #modal { position: fixed; inset: 0; background: rgba(0,0,0,.35); z-index: 10;
           display: flex; align-items: center; justify-content: center; }
  #modal[hidden] { display: none; }
  .mbox { background: #fff; border-radius: 10px; padding: 18px 20px; width: 340px;
          max-width: 90vw; box-shadow: 0 6px 24px rgba(0,0,0,.2); }
  .mbox h3 { font-size: 14.5px; margin-bottom: 10px; }
  .mbox .mbody { margin-bottom: 14px; word-break: break-all; }
  .mbox .mbtns { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
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
    <a data-v="stats" href="/panel/stats">统计面板</a>
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
            <input type="text" id="black-idTtl" class="ttl" placeholder="分钟">
            <button onclick="addEntry('black','ids')">添加</button>
          </div>
          <div id="black-ids"></div>
        </div>
        <div class="card">
          <h2>IP 黑名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="black-ipInput" placeholder="IP 或网段, 如 1.2.3.4 / 10.0.0.0/8">
            <input type="text" id="black-ipTtl" class="ttl" placeholder="分钟">
            <button onclick="addEntry('black','ips')">添加</button>
          </div>
          <div id="black-ips"></div>
        </div>
      </div>
      <div class="hint">黑名单模式开启后, 名单内的设备/IP 将被拒绝接入; 已连接的会立即被踢下线。
        「分钟」留空为永久条目, 填写则到期自动移除。</div>
    </section>

    <section id="view-white" hidden>
      <div class="cols">
        <div class="card">
          <h2>设备 ID 白名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="white-idInput" placeholder="设备唯一 id, 如 3f9a...-....">
            <input type="text" id="white-idTtl" class="ttl" placeholder="分钟">
            <button onclick="addEntry('white','ids')">添加</button>
          </div>
          <div id="white-ids"></div>
        </div>
        <div class="card">
          <h2>IP 白名单</h2>
          <div class="row" style="margin:0 0 10px">
            <input type="text" id="white-ipInput" placeholder="IP 或网段, 如 1.2.3.4 / 10.0.0.0/8">
            <input type="text" id="white-ipTtl" class="ttl" placeholder="分钟">
            <button onclick="addEntry('white','ips')">添加</button>
          </div>
          <div id="white-ips"></div>
        </div>
      </div>
      <div class="hint">白名单模式开启后, 仅名单内的设备/IP 可以接入, 其余一律拒绝。
        「分钟」留空为永久条目, 填写则到期自动移除 (到期的在线设备会被立即踢下线)。</div>
    </section>

    <section id="view-stats" hidden>
      <div class="statgrid" id="statCards"></div>
      <div class="card">
        <h2>24 小时流量 <span class="hint">(中继二进制数据, 5 分钟粒度)</span></h2>
        <canvas id="tChart" style="width:100%;height:160px;display:block"></canvas>
      </div>
      <div class="card">
        <h2>分设备流量 <span class="hint">(累计中继字节, 发送侧统计, Top 50)</span></h2>
        <table>
          <thead><tr><th>设备 ID</th><th>名称</th><th>累计流量</th></tr></thead>
          <tbody id="devBytes"></tbody>
        </table>
      </div>
    </section>
  </div>
</main>
<div id="toast"></div>
<div id="modal" hidden>
  <div class="mbox">
    <h3 id="mTitle"></h3>
    <div class="mbody" id="mBody"></div>
    <div class="mbtns" id="mBtns"></div>
  </div>
</div>

<script>
// ---------- 四个界面 (独立 URL, 可刷新/可后退) ----------
const TITLES = {stats: '统计', devices: '在线设备', black: '黑名单', white: '白名单'};
function currentView() {
  const v = location.pathname.split('/').pop();
  return TITLES[v] ? v : 'stats';
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

function fmtBytes(n) {
  if (n < 1024) return n + ' B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
  return n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2) + ' ' + units[i];
}
function fmtMB(n) {
  const mb = n / 1048576;
  return (mb >= 100 ? mb.toFixed(0) : mb >= 10 ? mb.toFixed(1) : mb.toFixed(2)) + ' MB';
}
function fmtUptime(sec) {
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600),
        m = Math.floor(sec % 3600 / 60);
  return (d ? d + '天' : '') + (h ? h + '时' : '') + m + '分';
}
function leftText(expires) {
  const left = Math.max(0, Math.round(expires - Date.now() / 1000));
  if (left >= 3600) return '剩 ' + Math.round(left / 3600) + ' 小时';
  if (left >= 60) return '剩 ' + Math.round(left / 60) + ' 分钟';
  return '剩 ' + left + ' 秒';
}

async function api(path, body) {
  const r = await fetch(path, {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body || {}),
  });
  if (r.status === 401) { location.href = '/'; throw new Error('unauthorized'); }
  return r.json();
}

// 实时速率: 由连续两份状态的总流量差算出
let lastTotal = null, lastTs = 0, curRate = 0;

function render(s) {
  for (const b of document.querySelectorAll('#modeSeg button'))
    b.classList.toggle('on', b.dataset.m === s.mode);
  // 名单条目: {value, expires} (expires=null 为永久)
  const entry = (lst, kind) => (e) =>
    `<div class="entry"><span>${esc(e.value)}${e.expires ? ` <span class="exp">${leftText(e.expires)}</span>` : ''}</span><button class="red small"
       onclick="removeEntry('${lst}','${kind}',decodeURIComponent('${u(e.value)}'))">移除</button></div>`;
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
         onclick="listChoose('black',decodeURIComponent('${u(c.id)}'),decodeURIComponent('${u(c.ip || '')}'))">拉黑</button>
       <button class="small"
         onclick="listChoose('white',decodeURIComponent('${u(c.id)}'),decodeURIComponent('${u(c.ip || '')}'))">加白</button>
     </div></td></tr>`
  ).join('') || '<tr><td colspan="5" class="hint">暂无在线设备</td></tr>';

  // ---- 统计页 ----
  const st = s.stats || {};
  const now = Date.now();
  if (lastTotal !== null && now > lastTs)
    curRate = (st.total_bytes - lastTotal) * 1000 / (now - lastTs);
  lastTotal = st.total_bytes ?? 0; lastTs = now;
  const cards = [
    ['运行时长', fmtUptime(st.uptime || 0)],
    ['在线设备', s.clients.length],
    ['累计连接', st.connections ?? 0],
    ['累计流量', fmtMB(st.total_bytes ?? 0)],
    ['实时流量', fmtMB(Math.max(0, curRate)) + '/s'],
    ['控制消息', st.messages ?? 0],
    ['文件数据', fmtBytes(st.bin_bytes ?? 0)],
    ['传输次数', st.transfers ?? 0],
    ['踢下线', st.kicks ?? 0],
    ['密码失败', st.auth_fails ?? 0],
    ['接入密码', s.access_key_on ? '已启用' : '未启用'],
  ];
  document.getElementById('statCards').innerHTML = cards.map(([k, v, sub]) =>
    `<div class="stat"><div class="k">${k}</div>
     <div class="v">${v}${sub ? ' <small>' + sub + '</small>' : ''}</div></div>`
  ).join('');
  const names = Object.fromEntries(s.clients.map(c => [c.id, c.name]));
  document.getElementById('devBytes').innerHTML =
    Object.entries(st.per_device || {}).map(([id, b]) =>
      `<tr><td style="font-family:monospace">${esc(id)}</td>
       <td>${esc(names[id] || '-')}</td><td>${fmtBytes(b)}</td></tr>`
    ).join('') || '<tr><td colspan="3" class="hint">暂无中继流量</td></tr>';
  drawTraffic(s.traffic || []);
}

// 24h 流量曲线: 纯 canvas, 面积图 + 稀疏坐标
function drawTraffic(buckets) {
  const cv = document.getElementById('tChart');
  const dpr = window.devicePixelRatio || 1;
  const W = cv.clientWidth, H = cv.clientHeight;
  if (!W) return; // 视图隐藏时跳过 (切回时会重绘)
  cv.width = W * dpr; cv.height = H * dpr;
  const ctx = cv.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, W, H);
  const now = Math.floor(Date.now() / 1000), t0 = now - 86400;
  const padL = 8, padR = 8, padT = 12, padB = 20;
  const plotW = W - padL - padR, plotH = H - padT - padB;
  const map = new Map(buckets);
  const maxV = Math.max(1, ...buckets.map(b => b[1]));
  const X = (ts) => padL + (ts - t0) / 86400 * plotW;
  const Y = (v) => padT + plotH - (v / maxV) * plotH;
  // 网格 + 坐标标签 (每 6 小时一条)
  ctx.strokeStyle = '#eee'; ctx.fillStyle = '#aaa'; ctx.font = '10px sans-serif';
  ctx.lineWidth = 1;
  const hour0 = Math.ceil(t0 / 21600) * 21600;
  for (let ts = hour0; ts <= now; ts += 21600) {
    const x = X(ts);
    ctx.beginPath(); ctx.moveTo(x, padT); ctx.lineTo(x, padT + plotH); ctx.stroke();
    const d = new Date(ts * 1000);
    ctx.fillText(String(d.getHours()).padStart(2, '0') + ':00', x - 12, H - 6);
  }
  // 面积 + 折线
  const pts = [];
  for (let ts = t0 - t0 % 300; ts <= now; ts += 300)
    pts.push([ts, map.get(ts) || 0]);
  if (pts.length < 2) {
    ctx.fillText('暂无数据', W / 2 - 20, H / 2);
    return;
  }
  ctx.beginPath();
  pts.forEach(([ts, v], i) => i ? ctx.lineTo(X(ts), Y(v)) : ctx.moveTo(X(ts), Y(v)));
  ctx.strokeStyle = '#07c160'; ctx.lineWidth = 1.5; ctx.stroke();
  ctx.lineTo(X(pts[pts.length-1][0]), padT + plotH);
  ctx.lineTo(X(pts[0][0]), padT + plotH);
  ctx.closePath();
  ctx.fillStyle = '#07c16022'; ctx.fill();
  // 峰值标注
  ctx.fillStyle = '#888'; ctx.font = '11px sans-serif';
  ctx.fillText('峰值 ' + fmtBytes(maxV) + '/5分钟', padL + 2, padT - 2 + 0 + 8);
}

async function loadState() {
  try {
    const r = await fetch('/api/state');
    if (r.status === 401) { location.href = '/'; return; }
    render(await r.json());
  } catch (e) { /* 网络抖动忽略, SSE/下轮刷新会补上 */ }
}
async function setMode(mode) { render(await api('/api/mode', {mode})); toast('模式已更新'); }
async function addEntry(lst, kind) {
  const el = document.getElementById(`${lst}-${kind === 'ids' ? 'idInput' : 'ipInput'}`);
  const ttlEl = document.getElementById(`${lst}-${kind === 'ids' ? 'idTtl' : 'ipTtl'}`);
  if (!el.value.trim()) return;
  const mins = parseFloat(ttlEl.value);
  const body = {list: lst, kind, value: el.value.trim()};
  if (mins > 0) body.ttl = Math.round(mins * 60);
  render(await api('/api/add', body));
  el.value = ''; ttlEl.value = '';
  toast(mins > 0 ? `已添加 (${mins} 分钟后过期)` : '已添加');
}
async function removeEntry(lst, kind, value) {
  render(await api('/api/remove', {list: lst, kind, value}));
}
async function kickOne(id) { render(await api('/api/kick', {id})); toast('已踢下线'); }

// ---------- 操作弹窗 (拉黑/加白选择 ID 或 IP, 单设备限速) ----------
function showModal(title, bodyHtml, btns) {
  document.getElementById('mTitle').textContent = title;
  document.getElementById('mBody').innerHTML = bodyHtml;
  const bb = document.getElementById('mBtns');
  bb.innerHTML = '';
  for (const b of btns) {
    const el = document.createElement('button');
    el.textContent = b.t;
    if (b.cls) el.className = b.cls;
    el.onclick = b.fn;
    bb.appendChild(el);
  }
  document.getElementById('modal').hidden = false;
}
function closeModal() { document.getElementById('modal').hidden = true; }

function listChoose(lst, id, ip) {
  const isBlack = lst === 'black';
  const act = isBlack ? '拉黑' : '加白';
  const body = `<div class="hint">ID: ${esc(id)}${ip ? '<br>IP: ' + esc(ip) : ''}</div>`;
  const btns = [{
    t: act + ' ID', cls: isBlack ? 'red' : '',
    fn: async () => {
      closeModal();
      render(await api('/api/add', {list: lst, kind: 'ids', value: id, kick: isBlack}));
      toast(isBlack ? '已拉黑 ID 并踢下线' : 'ID 已加入白名单');
    },
  }];
  if (ip) btns.push({
    t: act + ' IP', cls: isBlack ? 'red' : '',
    fn: async () => {
      closeModal();
      render(await api('/api/add', {list: lst, kind: 'ips', value: ip, kick: isBlack}));
      toast(isBlack ? '已拉黑 IP 并踢下线' : 'IP 已加入白名单');
    },
  });
  btns.push({t: '取消', cls: 'grey', fn: closeModal});
  showModal(act + '设备', body, btns);
}

async function logout() {
  await fetch('/api/logout', {method: 'POST'});
  location.href = '/';
}
switchView(currentView(), false);
loadState();
// 实时推送 (SSE): 状态变化即时到达, 统计页每 5s 一帧; 断线浏览器自动重连,
// 长时间连不上 (约 1 分钟, 多半是会话失效) 回登录页
let esFails = 0;
function startLive() {
  const es = new EventSource('/api/events');
  es.onmessage = (ev) => {
    esFails = 0;
    try { render(JSON.parse(ev.data)); } catch (_) {}
  };
  es.onerror = () => {
    if (++esFails > 12) { es.close(); location.href = '/'; }
  };
}
startLive();
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
        def _client_ip(self):
            """与 WS 侧一致: 仅 --trust-proxy 时采信 X-Forwarded-For"""
            if TRUST_PROXY:
                xff = self.headers.get("X-Forwarded-For")
                if xff:
                    return xff.split(",")[0].strip()
            return self.client_address[0]

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

        def _login_locked(self, ip):
            """登录锁定剩余秒数 (0=未锁定); 顺手清理过期记录"""
            until = login_locks.get(ip, 0)
            left = int(until - time.time())
            if left <= 0:
                login_locks.pop(ip, None)
                return 0
            return left

        def _record_login_fail(self, ip):
            now = time.time()
            hist = [x for x in login_fails.get(ip, []) if now - x < LOGIN_FAIL_WINDOW]
            hist.append(now)
            login_fails[ip] = hist
            if len(hist) >= LOGIN_FAIL_LIMIT:
                login_locks[ip] = now + LOGIN_LOCK_SEC
                login_fails.pop(ip, None)
                print(f"[admin] {ip} locked for {LOGIN_LOCK_SEC}s (too many login failures)")

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

        def _serve_events(self):
            """SSE: 持续推送 build_state() JSON; 每 15s 一个 keepalive 注释帧"""
            q = queue.Queue(maxsize=200)
            with _sse_lock:
                _sse_subs.add(q)
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                self.wfile.write(
                    f"data: {json.dumps(build_state(), ensure_ascii=False)}\n\n".encode()
                )
                self.wfile.flush()
                while True:
                    try:
                        payload = q.get(timeout=15)
                        frame = f"data: {payload}\n\n".encode()
                    except queue.Empty:
                        frame = b": keepalive\n\n"
                    self.wfile.write(frame)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                pass  # 浏览器关闭/刷新页面即断开
            finally:
                with _sse_lock:
                    _sse_subs.discard(q)

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/":
                # 启动时打印的免输链接: ?token= 验证通过直接建立会话进面板
                q = parse_qs(u.query)
                if token and q.get("token", [""])[0] == token:
                    return self._redirect("/panel/stats", set_sid=_new_session())
                if self._session_ok():
                    return self._redirect("/panel/stats")
                self._send_html(200, LOGIN_HTML)
            elif u.path == "/panel":
                if not self._session_ok():
                    return self._redirect("/")
                self._redirect("/panel/stats")
            elif u.path in ("/panel/devices", "/panel/black", "/panel/white", "/panel/stats"):
                if not self._session_ok():
                    return self._redirect("/")
                self._send_html(200, PANEL_HTML)
            elif u.path == "/api/state":
                if not self._auth_ok():
                    return self._send_json(401, {"error": "unauthorized"})
                self._send_json(200, build_state())
            elif u.path == "/api/events":
                if not self._auth_ok():
                    return self._send_json(401, {"error": "unauthorized"})
                self._serve_events()  # 长连接, 直到客户端断开
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
                ip = self._client_ip()
                locked = self._login_locked(ip)
                if locked:
                    return self._send_json(429, {"error": "locked", "retry_after": locked})
                if not token or str(m.get("token", "")) != token:
                    self._record_login_fail(ip)
                    locked = self._login_locked(ip)
                    if locked:
                        return self._send_json(429, {"error": "locked", "retry_after": locked})
                    return self._send_json(401, {"error": "bad token"})
                login_fails.pop(ip, None)  # 成功登录清零失败计数
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
                publish_state()
            elif u.path in ("/api/add", "/api/remove"):
                lst, kind = m.get("list"), m.get("kind")
                value = str(m.get("value", ""))
                if lst not in ("black", "white") or kind not in ("ids", "ips") \
                        or not value.strip():
                    return self._send_json(400, {"error": "bad entry"})
                if u.path == "/api/add":
                    ttl = m.get("ttl")  # 有效期秒数, 缺省/0 = 永久
                    ttl = int(ttl) if isinstance(ttl, (int, float)) and ttl > 0 else None
                    acl.add(lst, kind, value, ttl_sec=ttl)
                    print(f"[admin] add {lst}/{kind}: {value} (ttl={ttl or '永久'})")
                    # 黑名单模式下加黑即踢 (或显式要求 kick)
                    if m.get("kick") or (
                        lst == "black" and acl.snapshot()["mode"] == "blacklist"
                    ):
                        enforce_acl(loop)
                else:
                    acl.remove(lst, kind, value)
                    print(f"[admin] remove {lst}/{kind}: {value}")
                publish_state()
            elif u.path == "/api/limit":
                scope, bps = m.get("scope"), m.get("bps")
                if scope not in ("device", "transfer", "global") \
                        or not isinstance(bps, (int, float)) or bps < 0:
                    return self._send_json(400, {"error": "bad limit"})
                acl.set_limit(f"{scope}_bps", bps)
                apply_limits()
                print(f"[admin] limit {scope} -> {int(bps)} B/s")
                publish_state()
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
            self._send_json(200, build_state())

        def log_message(self, *args):
            pass  # 静默 HTTP 访问日志

    return AdminHandler


async def main():
    global acl, stats, ACCESS_KEY, TRUST_PROXY
    p = argparse.ArgumentParser(description="cloudSend relay server")
    p.add_argument("port", nargs="?", type=int, default=8787)
    p.add_argument("--admin-port", type=int, default=8788)
    p.add_argument("--admin-token", default=None)
    p.add_argument("--acl-file", default="server_acl.json")
    p.add_argument("--stats-file", default="server_stats.json")
    p.add_argument("--access-key", default=None,
                   help="接入密码: 设置后客户端 register 必须携带相同 key")
    p.add_argument("--trust-proxy", action="store_true",
                   help="位于受信反向代理之后时开启, 采信 X-Forwarded-For (也可用 TRUST_PROXY=1)")
    args = p.parse_args()

    acl = Acl(args.acl_file)
    stats = Stats(args.stats_file)
    ACCESS_KEY = args.access_key or os.environ.get("ACCESS_KEY") or None
    TRUST_PROXY = args.trust_proxy or os.environ.get("TRUST_PROXY") == "1"
    token = args.admin_token or os.environ.get("ADMIN_TOKEN") or secrets.token_hex(8)

    logging.getLogger("websockets.server").addFilter(_HandshakeFailFilter())

    loop = asyncio.get_running_loop()

    class QuietHTTPServer(ThreadingHTTPServer):
        # 浏览器/EventSource 中途断开 (WinError 10053 等) 属正常, 不打印堆栈
        def handle_error(self, request, client_address):
            import sys
            if isinstance(sys.exc_info()[1], ConnectionError):
                return
            super().handle_error(request, client_address)

    httpd = QuietHTTPServer(("0.0.0.0", args.admin_port), make_admin_handler(token, loop))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"[admin] 管理后台 (打开即登录, 远程访问把 127.0.0.1 换成服务器IP):")
    print(f"[admin]   http://127.0.0.1:{args.admin_port}/?token={token}")
    if ACCESS_KEY:
        print("[auth] 接入密码已启用 (客户端需在设置中填写相同密码)")
    if TRUST_PROXY:
        print("[proxy] 已开启 X-Forwarded-For 采信 (仅当位于受信反代之后时保持开启)")
    apply_limits()  # 持久化的带宽上限 (主要是 global_bps) 同步进桶

    asyncio.create_task(sweep_routes())
    asyncio.create_task(periodic_maintenance(loop))
    asyncio.create_task(sse_tick())
    # max_size 交给库在帧组装过程中拒收, 防攻击者用数 GB 帧头耗尽内存;
    # MAX_BIN_FRAME (1MB+64) > MAX_TEXT_FRAME (512KB), 不影响任何合法帧
    async with websockets.serve(handle, "0.0.0.0", args.port, max_size=MAX_BIN_FRAME):
        print(f"cloudSend relay listening on ws://0.0.0.0:{args.port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
