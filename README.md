# im-rtc-ios

`im-rtc` 音视频产品的 **iOS 客户端 SDK**，纯 Swift，最低 iOS 15。

| 产物 | 是什么 |
|---|---|
| **IMCallEngine** | **无 UI** 核心：信令 / 状态机 / 媒体 / 设备，能力通过**回调**暴露 |
| **IMCallKit** | **整套通话 UI**：来电页与横幅、1v1 四态、群通话九宫格、悬浮窗 |
| **Demo App** | 登录 / 拨号 / 通话记录 / 设置，两种集成方式各跑一遍 |

媒体用 [libwebrtc 预编译包](https://github.com/webrtc-sdk/Specs)（SPM binaryTarget，与 Android 同一个 fork
同一个版本 `150.7871.01`），UI 用原生 UIKit。

## 两种集成方式

- **只引 Engine**：拿回调，界面自己画。适合已有设计体系的 App。
- **Engine + Kit**：整套 UI 直接用，可换图标/配色/文案，不改流程。

**Kit 不是特权组件**——它只消费公开回调表，没有私有通道。

## 没有后台时联调

后台还没接好、拿不到 `POST /v1/tokens` 时，可以用控制台发的**调试密钥**（`key_id` 以 `dbg-` 开头）在本机签票：

```swift
let token = try IMDebugTokenGenerator.generate(appId: "10000001", keyId: "dbg-1", secret: "<调试密钥>", uid: "alice")
```

- **仅联调**：整个类型包在 `#if DEBUG` 里，Release 构建里不存在；每次调用都会打一条 warn。
- 入参不合法（uid 空 / 含空白 / 超 64 字节、appId 或 secret 为空、keyId 不以 `dbg-` 开头）抛 `IMRTCError(.badParams)`。
- **上线必须换成后端签票**（宿主后台 `POST /v1/tokens`），别把密钥打进正式包。
- 规则见 server `docs/design/DEBUG_KEY_DESIGN.md` §4；一致性向量 `docs/conformance/debug_token.json`。

## 边界

**不做宿主业务界面**（消息气泡、会话列表、群横幅）。Demo 的通话记录页是**示范**，不是要求。

## 文档

| 文档 | 内容 |
|---|---|
| [CLAUDE.md](CLAUDE.md) | 项目说明、结构、工作流程与「完成的定义」 |
| [CONVENTIONS.md](CONVENTIONS.md) | 工程规范（分层 / 体量 / **ObjC 互操作** / 并发 / 测试） |
| [current_task.md](current_task.md) | 当前进度活快照 |
| 协议契约 | 在 [im-rtc-server](https://github.com/BLiYing/im-rtc-server) 的 `docs/RTC_PROTOCOL.md`，本仓只读引用 |

## 开发

```bash
./scripts/install-hooks.sh   # 新 clone 跑一次
./scripts/test.sh            # 体量门禁 + 编译 + 单测（P3 落地后可用）
```

**音视频一律真机验收**：模拟器无摄像头、麦克风受限。

## 状态

**P3，尚未开工**（排在协议 → SFU → Web 之后），当前只有文档与体量门禁。

## 许可证

[MIT](LICENSE)。
