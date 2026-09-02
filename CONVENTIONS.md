# CONVENTIONS —— im-rtc-ios 工程规范（Swift）

> 本文是**本仓代码的硬约束**。`CLAUDE.md` 讲「这个项目是什么」，本文讲「代码必须长什么样」。
> 协议字段与回调命名以 `im-rtc-server/docs/RTC_PROTOCOL.md` 与设计文档 §7.5 为准，本文不重复。

## 1. 分层与目标划分

```
IMCallEngine  无 UI。不 import UIKit（除 RTCVideoView 这类渲染载体的类型定义）。
IMCallKit     UI。依赖 Engine，只通过公开回调获取信息。
Demo          示例 App。依赖 Engine + Kit，不含任何 SDK 逻辑。
```

**依赖方向单向**：`Demo → Kit → Engine`。**Engine 绝不反向依赖 Kit**。
Engine 内部：`CallEngine（门面）→ StateMachine / Signaling / Media / Devices`，
子模块之间通过协议解耦，不互相直接 import 具体类型。

**新增东西放哪**：
| 新增 | 放哪 | 不要放哪 |
|---|---|---|
| 一个新回调 | `CallEngineDelegate.swift` + 设计文档 §7.5 同步 | 临时加个闭包属性 |
| 一个新信令帧 | `Signaling/Frames.swift` + 状态机对应分支 | 在 WS 回调里就地解析 |
| 一个新界面 | `IMCallKit/<场景>/` 独立文件 | 往已有 ViewController 里塞 |
| 媒体能力 | `Media/` 内，经 `MediaAdapter` 协议暴露 | Kit 里直接调 libwebrtc |

**Kit 禁止直接 import WebRTC**。视频画面通过 Engine 提供的 `attachView(uid:to:)` 挂载，
换媒体实现时 Kit 一行不用改。

## 2. 文件体量红线（防「上帝类」）

- 非测试 `.swift` 文件 **> 600 行**即失败。Swift 表达力高，600 行已经很长。
- 硬闸：`scripts/check-file-size.sh` —— pre-commit + `scripts/test.sh` 第 1 步。
- **超标的正确处理是拆分，不是放宽阈值**：
  - ViewController 膨胀 → 抽**协作对象**（`XxxPresenter` / `XxxLayoutter` / `XxxDataSource`），
    不是抽一堆私有方法进 extension 充数。
  - 一个类型的不同关注点 → 拆 `extension` 到独立文件（`CallEngine+Room.swift`）。
  - 状态机膨胀 → 按状态族拆（`CallStateMachine+Ringing.swift`）。
- 姊妹项目 IMProgram 的教训：两个 VC 长到 3000+ 行后极难改动，最终被迫大拆。**别重蹈覆辙。**
- 函数层面：**单个函数超过 ~50 行**就该拆；`switch` 的每个分支各自成函数。

## 3. 命名

- 类型 `UpperCamelCase`，方法/属性 `lowerCamelCase`；**公开类型统一 `IM` 前缀**
  （`IMCallEngine`、`IMCallParams`），避免与宿主符号冲突。
- 方法名遵循 Swift API Design Guidelines：读起来像句子（`engine.call(userIds:mediaType:)`）。
- **回调名三端同名**：`onCallReceived` / `onCallBegin` / `onCallEnd` …
  Swift delegate 方法写成 `callEngine(_:onCallEnd:)`，但**语义与参数名必须与 §7.5 对齐**。
- 时间量带单位：`timeoutMS`、`durationSec`。
- 禁止 `data` / `info` / `manager` / `helper` 这类无语义名字做类型名。

## 4. ObjC 互操作（首批宿主是 Objective-C App）

- **所有公开 API 必须 ObjC 可用**：`@objc public`、类继承 `NSObject`、
  枚举 `@objc enum ... : Int`、避免公开 API 用 Swift 独有类型
  （泛型、关联值 enum、元组、`Result`、结构体 with generics）。
- 回调**同时提供 delegate 与 block 两种形式**（ObjC 宿主两种习惯都有）。
- 参数用 `NSString` / `NSNumber` 桥接友好的类型；可选性显式标注（`_Nullable` 语义）。
- **Engine 内部不受此约束**——只有跨 module 的公开面要 ObjC 友好，
  内部尽管用 Swift 的表达力（enum with associated values、泛型、actor）。
- 新增公开 API 后要在 Demo 里加一段 ObjC 调用示例，编译即验证。

## 5. 并发

- **主线程只做 UI**。信令、状态机、媒体回调一律在自己的队列上跑，
  **回调给宿主前显式切主线程**（宿主拿到回调就画界面，别让它们自己 hop）。
- 每个协作对象持有自己的串行队列，队列名带前缀：`com.imrtc.engine.signaling`。
- 共享可变状态必须有明确归属队列，并在属性上写注释说明；能用 `actor` 的新代码优先用。
- 不在锁内做 IO、不在锁内回调外部（宿主代码可能重入）。
- 定时器统一走 `DispatchSourceTimer`，持有方释放时必须 cancel（`Timer` 的 runloop 语义容易泄漏）。
- **禁止 `DispatchQueue.main.sync`**（死锁常客）。

## 6. 日志

- **统一走 Engine 内的日志入口**（`IMRTCLog`），底层用 `os.Logger`。
- **禁止 `print()` / `NSLog` / `debugPrint`**。姊妹项目上这条踩过坑：有兼容桥接兜底时
  违规会长期无人察觉。
- 必带字段：`callId` / `roomId` / `uid`（有哪个带哪个）。
- **脱敏**：token、UserSig 类凭据、SDP 完整内容不整条打印；凭据只打前 6 位 + 长度。
- **媒体回调里禁止日志**（每帧/每包都走的路径）。
- Kit 的日志走同一入口，前缀区分 `[Kit]` / `[Engine]`。

## 7. 内存与生命周期

- 闭包捕获 `self` 一律 `[weak self]`，除非明确是一次性且短命的。
- delegate 属性一律 `weak`。
- **Engine 必须能被完整释放**：`logout()` 后所有 goroutine 式的循环（重连、心跳、
  统计上报）都要停；写一个「反复 login/logout 100 次不涨内存」的测试钉死。
- 视频视图挂载/卸载要成对；`attachView` 之后宿主释放视图时必须能感知（用 weak 引用视图）。

## 8. UI（仅 IMCallKit）

- 原生 UIKit + AutoLayout，**不引第三方 UI 库**。
- **通话页固定深色、不随宿主主题**（对齐草图 §01；FaceTime / Telegram 同做法）。
  颜色集中在 `KitTheme`，禁止在组件里硬编码色值。
- 控制按钮统一 56pt 圆形；**开启态白底黑字**；挂断恒红、接听恒绿。
- Kit 的所有页面挂在**独立 window 层**，不入宿主导航栈——任何页面都能被来电覆盖。
- 文案集中在一个 `Localizable.strings`，**默认文案以草图 §09 文案表为准**；宿主可覆盖。
- 无障碍：所有按钮有 `accessibilityLabel`；不用颜色作为唯一信息载体
  （静音态除了变色还要换图标）。

## 9. 测试与「完成的定义」

- **每加一个功能就配单测**。状态机与信令编解码是**必须**有测试的部分。
- 状态机跑 `im-rtc-server/docs/conformance/*.json` 的**一致性向量**，与另外三端同一份。
- 纯逻辑（状态机、帧编解码、格子布局计算）用 XCTest 直接测，**不需要模拟器摄像头**。
- **音视频链路一律真机验收**，且要写清楚测了什么：接通/静音互见/翻转摄像头/切后台/弱网。
- `./scripts/test.sh` 是唯一测试入口。**别手拼 xcodebuild 命令行**（姊妹项目上这条踩过坑：
  命令行参数漂移导致"本地过了 CI 挂"）。

## 10. 提交与协作

- 提交信息格式：`类型(模块): 描述`，例如 `feat(kit): 群通话九宫格发言高亮`。
  类型取 `feat / fix / perf / refactor / docs / test / chore`。
- **直接在 main 提交**（本项目约定，不先开分支）。
- 提交前 pre-commit 跑体量门禁；被拦了就拆分，别 `--no-verify`。

## 11. 不做什么（刻意的边界）

- **不做宿主业务界面**：消息气泡、会话列表、群横幅。Demo 的通话记录页是示范不是要求。
- **不内置好友/联系人系统**：Demo 的联系人来自本地文件，宿主用自己的。
- **不在 Engine 里塞业务概念**：Engine 只认 `userId` / `roomId` / `callId`，
  不认「群」「会话」「好友」。群名之类的展示信息由宿主经 `userData` 透传。
- **MVP 不做锁屏来电**（需 PushKit + CallKit + VoIP 推送证书），只覆盖 App 前台在线来电。
  这条要写进每次交付说明，不许含糊。
