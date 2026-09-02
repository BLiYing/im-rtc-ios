# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：只记当前状态，**就地覆盖、不追加**。历史见 `git log`。
> 工程规范见 [CONVENTIONS.md](CONVENTIONS.md)；方案与分期见 `im-rtc-server` 的
> `docs/design/RTC_CALL_DESIGN.md` §10；界面以草图 `docs/design/sketches/RTC_CALL_UX_SKETCH.html` §02~§05 为准。

## 当前焦点

**仓库刚建（2026-09-03），只有文档与体量门禁，尚无一行代码。**

本仓在分期里是 **P3**（Call 层振铃 + iOS Engine/Kit/Demo），排在
P0 协议契约 → P1 SFU 最小可用 → P2 Web 端到端之后。
**理由**：浏览器双开是最便宜的端到端验证场，SFU 与协议的坑先在 Web 上踩完再上真机。

在 P0 协议契约（`im-rtc-server/docs/RTC_PROTOCOL.md`）落地前，本仓能做的只有工程骨架。

## 下一步

1. **等 P0**：`RTC_PROTOCOL.md` + `docs/conformance/*.json` 测试向量就绪。
2. **工程骨架**（可与 P0 并行）：`Package.swift` 两个 product（IMCallEngine / IMCallKit）、
   目录结构、`scripts/check-file-size.sh` + `install-hooks.sh` + `test.sh`、
   libwebrtc 依赖（`stasel/WebRTC`，锁定版本）。
3. **P3 第一刀**：`Signaling`（WS + 帧编解码 + 重连退避）与 `StateMachine`（纯逻辑），
   **先跑通一致性向量**，这两块不需要媒体也不需要真机。
4. **P3 第二刀**：`Media/WebRTCAdapter` + 1v1 语音 → 视频，真机 ↔ Web 联调。
5. **P3 第三刀**：Kit 的 1v1 四态 + 来电横幅 + 悬浮球（草图 §03/§04）；Demo 四屏（草图 §02）。
6. **P4**：群通话九宫格（草图 §05），依赖服务端 simulcast 层选择就绪。

## 已知坑 / 限制

- **公开 API 必须 ObjC 友好**：首批宿主 IMProgram 是 Objective-C。`@objc public` + NSObject 子类 +
  `@objc enum : Int`，公开面不用泛型/关联值 enum/元组。见 CONVENTIONS §4。
- **MVP 不覆盖锁屏来电**：需要 PushKit + CallKit + VoIP 推送证书，属后续期。
  只覆盖 App 前台且信令在线时的来电——每次交付都要明说，不许含糊。
- **音视频一律真机验收**：模拟器无摄像头、麦克风受限。"编译通过"不等于"功能可用"。
- **libwebrtc 版本要锁死**：预编译包随 Chromium 里程碑更新，季度升级一次，
  API 变化由 `MediaAdapter` 隔离。
- **未签名装机 Keychain 不可用**（姊妹项目 IMProgram 的已知坑）：Demo 存 token 用
  `UserDefaults` 即可，别引 Keychain 依赖。
- **iOS 切后台视频会被系统暂停**（Background Audio 只保音频），对端应退回头像——
  这是平台规则不是 bug，UI 要正确表现。

## 关联工程 / 常用命令

- 四仓（本地同级 `/Users/liying/IOSProject/im-rtc/`）：
  [im-rtc-server](https://github.com/BLiYing/im-rtc-server)（**协议契约在这里，只读引用**）·
  **im-rtc-ios**（本仓）· [im-rtc-web](https://github.com/BLiYing/im-rtc-web) ·
  [im-rtc-desktop](https://github.com/BLiYing/im-rtc-desktop)。
- 首批宿主（下游）：`../../IMProgram`（Objective-C iOS App，架构见其 `ARCHITECTURE.md`）。
- 常用命令（脚本随骨架落地）：
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口：体量 + 编译 + 单测
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  ```
