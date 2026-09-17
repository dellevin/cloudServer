# cloudSend

类似 LocalSend 的在线版本:通过公网中继服务器(类似 syncthing 的 relay)中转流量,实现跨网络设备发现、文件传输与聊天。聊天内容仅存本地数据库,文件保存到 `Download/cloudSend`,服务器不做任何存储。

## 结构

- `lib/` — Flutter 客户端(Windows / Android)
- `server/` — Python 中继服务器(WebSocket,纯流量中转)

## 中继服务器

部署到公网服务器(Python 3.10+):

```bash
cd server
pip install -r requirements.txt
python server.py 8787   # 默认端口 8787
```

## 客户端

```bash
flutter pub get
flutter run -d windows     # Windows
flutter devices
flutter run -d <android>   # Android
flutter build windows --release
flutter build apk --release
```

打开应用 → 设置 → 填中继服务器地址(如 `1.2.3.4:8787`)→ 连接。填入相同服务器地址的设备会互相发现,可聊天、互发文件。

## 协议(WebSocket)

- 文本帧 JSON:`register` / `peers` / `chat` / `chat_ack` / `file_offer` / `file_accept` / `file_reject` / `file_done` / `file_progress` / `file_result` / `file_cancel`
- 二进制帧:前 36 字节为 transferId,其余为文件数据块,服务器按 transferId 路由(校验发送方身份)

## 传输可靠性

- **断点续传**:接收端先写 `<文件名>.part` 临时文件;`file_accept` 携带 `offset`,发送端从偏移处续传,中断后点"续传/重发"即可接着传
- **完整性校验**:发送端边发边算 SHA-256,`file_done` 携带哈希;接收端校验通过才把 `.part` 改名为正式文件,并回 `file_result`
- **取消**:任意一方可随时取消(`file_cancel`),半成品自动清理
- **背压**:接收端每收 2MB 回执 `file_progress`,发送端未确认字节超过 8MB 即暂停等待,防止缓冲爆炸
- **服务端**:传输路由记录 (发送方, 接收方, 时间),任一端掉线即清理,超时路由每 5 分钟自动清扫

## 数据位置

- 聊天记录:本地 SQLite(`cloudsend_chat.db`)
- 收到的文件:`Download/cloudSend/`
- 设备 ID:首次启动生成,持久保存不变
