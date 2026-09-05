# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：只记当前状态，**就地覆盖、不追加**。历史见 `git log`。
> 工程规范见 [CONVENTIONS.md](CONVENTIONS.md)；方案与分期见 `im-rtc-server` 的
> `docs/design/RTC_CALL_DESIGN.md` §10；界面以草图 `docs/design/sketches/RTC_CALL_UX_SKETCH.html` §02~§05 为准。

## 当前焦点

**P3 前四刀已落地（2026-09-05）：协议层 + 三个状态机 + 信令连接 + **门面与回调表**。
向量全过，且已经真连上服务端跑通进房离房。**「自画 UI 的宿主」现在就能接了。**

服务端 P0~P4 与 Web P2 都已完成，本仓是四仓里最后开工的一个。

| 目录 | 内容 | 怎么验的 |
|---|---|---|
| `Protocol/` | 严格 JSON 值模型、编码硬规则、信封、45 个错误码、reason、40 个帧的字段声明与注册表 | envelope 26+9 条向量、错误码全表、reason 全表 |
| `StateMachine/` | 通话机（§5.1）、房间机（§5.3）、Engine 总状态 | `call_fsm` 16 条 + `room_fsm` 7 条向量 |
| `Signaling/` | WS 客户端、握手、心跳、按 req_id 配对、退避重连、4401 三次上限 | 13 条假连接时序用例 + **一条真服务端联调** |
| `Facade/` | `IMCallEngine` 门面、24 条回调的 delegate 表、block 接法、核心循环 | 13 条假连接 + 假媒体的接线用例 |
| `Media/` | `IMMediaAdapter` 协议（**只有接缝，没有实现**） | 由门面用例的假媒体驱动 |
| `Observability/` | `IMRTCLog` 与脱敏 | 日志纪律门禁（含自检） |

`Sources/IMCallKit/` 目前是**空壳**：只有 `KitEntry`。立它是为了让「两个 product」
从第一天就在 `Package.swift` 里——跨 module 的边界每次编译都在检查
「Kit 只能看见 Engine 的 public 面」，等界面写完再拆就是大手术。

**`./scripts/test.sh` 十步全绿**，47 个用例，**全程不需要模拟器**。
第十步是新加的「Demo 为 iOS 编译」：`generic/platform=iOS Simulator` 只编译不跑，
它验的是上面 `swift test`（跑在 macOS 上）验不到的两件事——Demo 还编不编得过、
以及**公开面对 ObjC 到底可不可用**。

真服务端联调（默认 XCTSkip，手动跑）：
```bash
cd ../im-rtc-server && ./scripts/dev.sh
RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests
```
它验的是与 `rtc-cli -scenario room` 等价的流程：免密登录 → WS 握手 →
建会议房 → 换票 → 进房 → 离房。**第一次跑就抓到一个服务端 bug**：
主动 logout 发的 1000 被当成掉线，房里挂了半分钟幻影成员（已在 im-rtc-server 修）。

两个刻意的工程决定：
- **`IMCallEngine` 不依赖 libwebrtc**。它是 iOS-only 的预编译二进制包，
  一旦被 Engine 直接依赖，「跑一次单测」就变成「起模拟器 + 下载几百 MB」。
  媒体只以 `MediaAdapter` 协议出现，真实现放进随后的 iOS-only target。
  这与 Web 端「engine 必须能在无 DOM 的 Node 里构造」是同一条约束。
- **「协议里没有 null、没有浮点」编进了类型系统**：`IMJSON` 这个枚举里压根没有
  `.null` 与 `.double` 两个 case，解析阶段就挡掉。

## 下一步

**P3 第五刀 —— 媒体（要真机）**
实现 `IMMediaAdapter`（接缝已经在了）+ 独立的 iOS-only target 引 libwebrtc。
**两条 PeerConnection，各有固定 offerer**（pub=本端、sub=服务端），
所以不需要 perfect negotiation / rollback。

**libwebrtc 的分发已拍板（2026-09-05）：依赖 `stasel/WebRTC`，版本 `exact` 锁死。**

```swift
.package(url: "https://github.com/stasel/WebRTC.git", exact: "152.0.0")
```

已核实（不是凭印象）：当前 152.0.0、在维护、支持 SPM、iOS 12+（我们要 15+，够）、
BSD-3 + Google 的 WebRTC 许可（可商业再分发）。

**关键事实：Google 从 M80 起就不再发布官方的移动端预编译产物了。**
所以「自建 xcframework」不是「重新打包 Google 的产物」，而是**自己从源码编**
（depot_tools + 几十 GB + 几小时），成本比原先估的高得多。

选它的第三个理由是**这个决定可以随时反悔**：libwebrtc 被隔离在
`IMCallEngineWebRTC` 一个 target 里，将来要换成自建产物只改 `Package.swift`
一行依赖，**Engine / Kit / Demo 一行不动**。这正是当初把媒体挡在 Engine 之外的收益。

**P3 第六刀 —— Kit + Demo**：1v1 四态 + 来电横幅 + 悬浮球（草图 §03/§04）、Demo 四屏。
Kit 的空壳与 Demo 工程都已就位，直接往里填界面即可。
**Demo 的 `Main.storyboard` 要删掉**，纯代码建 window——Kit 的页面挂独立 window 层
（CONVENTIONS §8），不入宿主导航栈。
**P4**：九宫格（草图 §05）。服务端的 simulcast 与带宽估计都已就绪，
Web 端的 uikit 可以直接对照抄结构（`packages/call-uikit-react/src/layout/grid.ts`）。

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
- **Swift 的块注释是可嵌套的**：注释里出现 `/` 紧跟 `*`（比如写一个带通配符的路径）
  会开一层嵌套注释，把后面整个文件吞掉，报错只说「unterminated」。踩过两次。
- **`JSONSerialization` 分不清 true 与 1**：两者都是 `NSNumber`，
  且 `NSNumber(value: 1) is Bool` 为 **true**。用 `is Bool` 判类型的话，
  「bool 不能写成 0/1」这条协议规则在 Swift 端等于不存在。本仓用 `CFBooleanGetTypeID` 判。
- **4401 必须有重试上限**（`IMSignalConnection.maxAuthFailures = 3`，三端同一个数）：
  重连**带的是同一枚 token**，没有上限就是拿同一把坏钥匙永远敲同一扇门。
  Web 端实测过——服务端重启换了签名密钥，一个没关的标签页重试到第 19 次还在敲，
  日志里全是 `token_invalid`，把真正的问题淹掉了。到顶抛 `onKickedOut` 让宿主回登录页。
- **三端已知的两条真 bug，iOS 从第一天就带上了防线**：
  通话结束后房间必须回 idle（否则之后每一帧都发向已销毁的房间）；
  层上界要随订阅一起给到服务端（否则房间记 m、实际发 h）。

- **ObjC 的选择器要亲手编一遍才知道对不对**：`Demo/IMRTCDemo/IMRTCDemo/IMObjCAPICheck.m`
  就是干这个的（CONVENTIONS §4 的「编译即验证」），它已经抓到一个真问题——
  `setMuted(_:_:)` 两个参数都不带标签，生成的选择器是 `setMuted::completionHandler:`，
  ObjC 宿主得写 `[engine setMuted:cid :YES ...]` 那种带空标签的怪东西。
  **加了公开 API 就往那个文件里补一行调用。**
- **`IMMediaAdapter` 刻意不是 `@objc` 协议**：它的方法是 `async throws`，
  而且只被媒体 target 实现一次，没有让 ObjC 宿主自己实现的场景。
  所以带 media 参数的那个 `init` 不导出到 ObjC，ObjC 宿主用 `initWithUrl:deviceID:`
  那个纯信令形态的。
- **不给 Engine 传媒体适配器是正常用法**，不是降级：登录、振铃、成员进出、
  静音通知一个都不少，只有推流与画面挂载会以 `2005 invalid_state` 失败。
  **没有为它新造错误码**——错误码表是四仓共用的契约，加一个码等于改四个仓 + 改向量。

## 关联工程 / 常用命令

- 四仓（本地同级 `/Users/liying/IOSProject/im-rtc/`）：
  [im-rtc-server](https://github.com/BLiYing/im-rtc-server)（**协议契约在这里，只读引用**）·
  **im-rtc-ios**（本仓）· [im-rtc-web](https://github.com/BLiYing/im-rtc-web) ·
  [im-rtc-desktop](https://github.com/BLiYing/im-rtc-desktop)。
- 首批宿主（下游）：`../../IMProgram`（Objective-C iOS App，架构见其 `ARCHITECTURE.md`）。
- 常用命令（脚本随骨架落地）：
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口：两道门禁 + 自检 + 向量可达 + 编译 + 单测
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  swift test --filter CallFSMTests # 只跑某一份向量
  RTC_CONFORMANCE_DIR=/path ./scripts/test.sh   # 向量不在同级目录时
  ```
