# cloudSend

类似 LocalSend 的在线版本:通过公网中继服务器(类似 syncthing 的 relay)中转流量,实现跨网络设备发现、文件传输、聊天与剪贴板同步。聊天内容仅存本地数据库,文件保存到 `Download/cloudSend`,服务器不做任何存储。支持端到端加密(消息内容对中继服务器不可读)。

## 功能

- **文件互传**:多文件/文件夹批量传输,断点续传,SHA-256 完整性校验
- **即时消息**:设备间文字聊天,已读回执,消息漫游(本地 SQLite)
- **剪贴板同步**:文本/图片/文件在互相信任的设备间自动同步(可按类型开关)
- **远程浏览**:像文件管理器一样浏览对端设备,图片/视频/zip/Word/Excel/txt 在线预览
- **端到端加密**:接入密码经 PBKDF2 派生 AES-256-GCM 密钥,消息加密传输(协议 v3+)
- **多链路自动选择**:局域网直连 → P2P 打洞 → 公网中继,自动选最优通道
- **设备管理**:在线/历史设备列表,信任(自动收文件)/拉黑,扫码配对

## 结构

- `lib/` — Flutter 客户端(Windows / Android)
- `server/` — Python 中继服务器(WebSocket,纯流量中转)

## 中继服务器

部署到公网服务器(Python 3.10+):

```bash
cd server
pip install -r requirements.txt
python server.py 8787            # 默认端口 8787
python server.py 8787 --access-key <密码>   # 启用接入密码(同时用于 E2EE 派生密钥)
```

## 客户端

```bash
flutter pub get
flutter run -d windows     # Windows
flutter run -d <android>   # Android
flutter build windows --release
flutter build apk --release
```

打开应用 → 设置 → 填中继服务器地址(如 `1.2.3.4:8787`)→ 连接。填入相同服务器地址的设备会互相发现,可聊天、互发文件。同一局域网内的设备无需服务器也能直连互传。

> Windows 构建说明:首次构建时 media_kit 会从 GitHub releases 下载 libmpv/ANGLE 预编译包,需能访问 GitHub;若下载被截断导致构建失败(MSB3073),手动下载 `mpv-dev-x86_64-20230924-git-652a1dd.7z` 放到 `build/windows/x64/` 后重新构建即可。

## 端到端加密 (E2EE)

- 服务器启用 `--access-key` 后,客户端在设置中填入相同接入密码即自动开启
- PBKDF2-HMAC-SHA256 (50000 轮) 从接入密码派生 AES-256-GCM 密钥
- 聊天、剪贴板、文件传输信令等控制消息整体加密为 `enc` 信封,中继仅按 `to` 路由,内容不可读
- 仅当双方都运行协议 v3+ 客户端时启用;文件二进制流暂为明文(后续版本加密)

## 协议 (WebSocket)

- 文本帧 JSON:`register` / `peers` / `chat` / `chat_ack` / `chat_reject` / `chat_recall` / `chat_read` / `clip_text` / `file_offer` / `file_accept` / `file_reject` / `file_done` / `file_progress` / `file_result` / `file_cancel` / `fs_list` / `fs_get` / `fs_thumb` / `enc` (E2EE 信封) / `p2p_*` (打洞信令)
- 二进制帧:前 36 字节为 transferId,其余为文件数据块,服务器按 transferId 路由(校验发送方身份)

## 传输可靠性

- **断点续传**:接收端先写 `<文件名>.part` 临时文件;`file_accept` 携带 `offset`,发送端从偏移处续传,中断后点"续传/重发"即可接着传
- **完整性校验**:发送端边发边算 SHA-256,`file_done` 携带哈希;接收端校验通过才把 `.part` 改名为正式文件,并回 `file_result`
- **取消**:任意一方可随时取消(`file_cancel`),半成品自动清理
- **掉线中止**:传输中对端掉线即判失败——发送侧中断发送循环(可重发),接收侧保留 `.part`(可续传);已发完但未收到校验结果的(小文件)在 30 秒窗口期内对端掉线同样改判失败,防止误判完成
- **背压**:接收端每收 2MB 回执 `file_progress`,发送端未确认字节超过 8MB 即暂停等待,防止缓冲爆炸
- **服务端**:传输路由记录 (发送方, 接收方, 时间),任一端掉线即清理,超时路由每 5 分钟自动清扫

## 文件预览

点击传输记录或远程浏览打开文件:

- **文本 / 图片 / 视频 / zip / Word(docx) / Excel(xlsx)** 走应用内预览
  - 视频播放基于 media_kit(Windows / Android),支持播放/暂停、进度拖拽
  - zip 可查看内容列表,支持解压单个文件或全部解压到下载目录(重名自动追加 `(1)` `(2)`…)
  - docx/xlsx 为纯 Dart 解析(只读),旧版 .doc/.xls 不支持
- 其他类型(音频 / 旧版文档等)调系统默认程序打开

## 数据位置

- 聊天记录:本地 SQLite(`cloudsend_chat.db`)
- 收到的文件:`Download/cloudSend/`
- 设备 ID:首次启动生成,持久保存不变
- 历史设备(名字/头像/平台/最后在线):SharedPreferences,清理缓存不影响

## 赞助作者

如果 cloudSend 帮到了你,欢迎请作者喝杯咖啡 ☕ 赞助纯属自愿,所有功能永久免费。

| 微信支付 | 支付宝 |
| :---: | :---: |
| <img src="assets/wx.jpg" width="220"> | <img src="assets/zfb.jpg" width="220"> |
