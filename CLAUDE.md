# im-rtc-ios — 项目说明（供 Claude 读取）

## 项目简介
`im-rtc` 音视频产品的 **iOS 客户端 SDK**，纯 **Swift**。交付三样东西：

| 产物 | 是什么 | 谁用 |
|---|---|---|
| **IMCallEngine** | **无 UI** 核心：信令、通话状态机、媒体、设备控制，全部能力通过**回调**暴露 | 想自己画 UI 的宿主 |
| **IMCallKit** | **整套通话 UI**：来电页/横幅、1v1 四态、群通话九宫格、悬浮窗。依赖 Engine | 想一天内上线通话的宿主 |
| **Demo App** | 登录 / 拨号 / 通话记录 / 设置，两种集成方式各跑一遍 | 验证「只用公开回调就能做出完整体验」 |

**边界（重要）**：本仓**不做宿主业务界面**——消息气泡、会话列表、"群里谁在通话"的横幅，
都由宿主拿 Engine 回调自己实现。Demo 里的「通话记录页」是**示范**，不是要求宿主照抄。
详见 `im-rtc-server` 的 `docs/design/RTC_CALL_DESIGN.md` §9。

**Kit 不是特权组件**：它只消费公开回调表，没有任何私有通道。一旦某个界面需要 Engine 开私有口子，
说明回调表少了一项 —— **补表，不开后门**。这是「自画 UI 与 Kit 能力对等」的唯一保证。

## 技术栈
- 语言：**Swift 5**，最低 **iOS 15**
- 媒体：**libwebrtc 预编译包**（`stasel/WebRTC`，SPM）。`RTCPeerConnection` / `RTCMTLVideoView` /
  `AVAudioSession` 音频路由
- 信令：`URLSessionWebSocketTask`，JSON
- 分发：**Swift Package Manager**（libwebrtc 预编译包本身 SPM 优先；宿主可 pods + SPM 混用）
- UI：原生 UIKit，**不引第三方 UI 库**

## 工程结构（规划，落地时按此展开）
```
im-rtc-ios/
├── Package.swift                      # 两个 product：IMCallEngine / IMCallKit
├── Sources/
│   ├── IMCallEngine/
│   │   ├── CallEngine.swift           # 门面：login/call/accept/hangup/joinRoom…
│   │   ├── CallEngineDelegate.swift   # 回调协议（对应设计文档 §7.5 回调总表）
│   │   ├── Signaling/                 # WS 客户端 + 帧编解码 + 重连退避
│   │   ├── StateMachine/              # 通话与房间状态机（纯逻辑、可单测、跑一致性向量）
│   │   ├── Media/                     # MediaAdapter 协议 + WebRTCAdapter（libwebrtc）
│   │   └── Devices/                   # 麦克风/摄像头/扬声器/蓝牙路由、权限
│   └── IMCallKit/
│       ├── KitEntry.swift             # Kit.start() / 配置项
│       ├── Incoming/                  # 来电全屏页 + 顶部横幅
│       ├── Call/                      # 1v1 语音/视频页、控制栏、本地小窗
│       ├── Group/                     # 九宫格、格子(Tile)、选人
│       └── Floating/                  # 悬浮球 / 悬浮小画面
├── Tests/                             # XCTest：状态机、信令编解码、一致性向量
├── Demo/                              # Demo App（独立 Xcode 工程，依赖本地 package）
└── scripts/                           # 门禁与测试入口
```

## 工作约定
- **每次开始主要回复前，先读 `current_task.md` 恢复上下文**，改动后更新它。
- **`current_task.md` 是「活快照」不是流水账**：固定四节，**就地覆盖、禁止追加 Status 块**。
- **工程规范见 [CONVENTIONS.md](CONVENTIONS.md)**（分层 / 体量 / `@objc` 门面 / 并发 / 日志 / 测试）。
- **协议契约在 `im-rtc-server/docs/RTC_PROTOCOL.md`，本仓只读引用**，不得单方面加字段。
  改协议 = 改四个仓 + 同步一致性向量。
- **单文件体量红线**：非测试 `.swift` **> 600 行**要按职责拆分。
  硬闸：`scripts/check-file-size.sh`（pre-commit + `test.sh` 第 1 步）。新 clone 跑 `./scripts/install-hooks.sh`。
- 文档引用代码**不写行号**，写文件路径 + 符号名：`Sources/IMCallEngine/Media/WebRTCAdapter.swift` 的 `attachView(_:to:)`。

## 工作流程与「完成的定义」
动手前（Read，不靠记忆）：
- 改代码前先 Read [CONVENTIONS.md](CONVENTIONS.md)；涉及协议字段再 Read `../im-rtc-server/docs/RTC_PROTOCOL.md`。
- 加/改**公开 API** 前，先 Read 设计文档 §7.5 回调总表——**回调表是契约，三端同名**。

声明「完成」前必须全部满足，并在回复中**贴出 `./scripts/test.sh` 的输出**：
1. 新功能配套单测（`Tests/`），由 `swift test` / `xcodebuild test` 自动纳入。
2. `./scripts/test.sh` 全绿（体量门禁 + 编译 + 单测）。
3. 更新 `current_task.md`；里程碑完成同步更新 server 仓设计文档 §10 的状态与日期（YYYY-MM-DD）。
4. 明确说清楚「没做什么 / 已知限制 / TODO」，不假装完成。
5. **音视频功能一律真机验收**：模拟器无摄像头、麦克风受限，"模拟器上能跑"不算数。
   编译通过 ≠ 功能可用，说清楚当前到哪一步。

主动建议（不必用户开口）：
- 完成较大功能后建议跑 `/code-review` 自审。
- 触及 token / 权限 / 媒体密钥时建议跑 `/security-review`。

## 构建 / 测试
```bash
./scripts/install-hooks.sh   # 新 clone 跑一次
./scripts/test.sh            # 唯一测试入口：体量门禁 + 编译 + 单测
BUILD_ONLY=1 ./scripts/test.sh   # 只编译
```
> 脚本随 P3 落地补齐；当前仓库只有文档与体量门禁。

## 关联仓库
| 仓库 | 内容 |
|---|---|
| [im-rtc-server](https://github.com/BLiYing/im-rtc-server) | 控制面 + SFU + **协议契约**（本仓只读引用） |
| **im-rtc-ios**（本仓） | Engine + Kit + Demo（Swift） |
| [im-rtc-web](https://github.com/BLiYing/im-rtc-web) | Engine + Kit + Demo（TS/React） |
| [im-rtc-desktop](https://github.com/BLiYing/im-rtc-desktop) | C++17 Engine + Qt Demo |

**首批宿主（下游）**：`../../IMProgram`（Objective-C iOS App）。因此**公开 API 必须 ObjC 友好**（见 CONVENTIONS §4）。
