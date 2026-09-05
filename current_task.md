# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：只记当前状态，**就地覆盖、不追加**。历史见 `git log`。
> 工程规范见 [CONVENTIONS.md](CONVENTIONS.md)；方案与分期见 `im-rtc-server` 的
> `docs/design/RTC_CALL_DESIGN.md` §10；界面以草图 `docs/design/sketches/RTC_CALL_UX_SKETCH.html` §02~§05 为准。

## 当前焦点

**P3 前四刀已落地（2026-09-05）：协议层 + 三个状态机 + 信令连接 + **门面与回调表**。
向量全过，且已经真连上服务端跑通进房离房。**「自画 UI 的宿主」现在就能接了。**

服务端 P0~P4 与 Web P2 都已完成，本仓是当时四仓里最后开工的一个（Android 于 2026-09-05 进入范围，排在本仓之后）。

| 目录 | 内容 | 怎么验的 |
|---|---|---|
| `Protocol/` | 严格 JSON 值模型、编码硬规则、信封、45 个错误码、reason、40 个帧的字段声明与注册表 | envelope 26+9 条向量、错误码全表、reason 全表 |
| `StateMachine/` | 通话机（§5.1）、房间机（§5.3）、Engine 总状态 | `call_fsm` 16 条 + `room_fsm` 7 条向量 |
| `Signaling/` | WS 客户端、握手、心跳、按 req_id 配对、退避重连、4401 三次上限 | 13 条假连接时序用例 + **一条真服务端联调** |
| `Facade/` | `IMCallEngine` 门面、24 条回调的 delegate 表、block 接法、核心循环 | 13 条假连接 + 假媒体的接线用例 |
| `Media/` | `IMMediaAdapter` 协议（**只有接缝，没有实现**） | 由门面用例的假媒体驱动 |
| `Observability/` | `IMRTCLog` 与脱敏 | 日志纪律门禁（含自检） |

`Sources/IMCallKit/` 已经有**视图模型 + 布局算术 + 回调接线 + 界面**：

| | |
|---|---|
| `State/IMCallViewState` | 纯值语义的视图模型 + reducer + 红按钮四向分派 |
| `State/IMCallController` | 把 `IMCallEngineDelegate` 接成视图状态；界面动作也在这里 |
| `Layout/IMGrid` | 九宫格行列、层上界、时长格式化 |
| `UI/` | 主题、控制按钮、成员格子、通话页、来电横幅、悬浮球、网络条、**独立 window 层** |

**Kit 只消费公开回调表**：`IMCallController` 实现的就是 `IMCallEngineDelegate`，
与「宿主自画 UI」拿到的完全一致，没有一处私有通道。

Demo 已经接上 Kit——`kit.start()` **一行**就接管了通话界面（草图 §01 的用法 B）。
Demo 有草图 §02 的三个 tab：拨号（1v1 / 群呼选人 / 会议）、通话记录、设置。
通话记录**完全由 `callDidEnd` 拼出来**，走的是 block 接法（delegate 被 Kit 占着）。

**客户端日志回传已接上**：Demo 登录后装 `RemoteLogSink`，Engine 的每一个公开事件
都进日志，落在 `im-rtc-server/dev-logs/client-ios-<用户名>.log`；
`scripts/timeline.py` 把它与服务端、浏览器端合到一条时间轴。
线路格式对着真服务端 curl 验过（HTTP 200，timeline 能读）。

`Sources/IMCallEngineWebRTC/` 是媒体实现（iOS-only，接 `stasel/WebRTC` 152.0.0）：
两条 PeerConnection、候选缓冲、simulcast 三层、第一帧探针、画面挂载。
**编译验过、真机没验过**——出声出画要你在真机上跑一次。

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

**2026-09-05 真机联调修掉的（本仓这一侧）**：

| 症状 | 根因 |
|---|---|
| **九宫格里一格远端画面都没有**（协商全通、`firstVideoFrame` 照抛、日志全绿） | 挂载登记表**按 track_id 当 uid 用**，而 `attachView` 传的是真 uid，两把钥匙永远对不上。Web 端一直是对的（`viewRegistry.ts` 有 orphans + claim 两张表），iOS 这边缺了整个「认领」环节。现补 `IMMediaAdapter.claimRemoteTracks`，由核心循环每推进一步同步一次 |
| **挂断即闪退** | `RTCPeerConnectionFactory` 原先是「一通电话一个」的存储属性，通话结束时整个丢掉。Swift 释放存储属性的顺序**未定义**：工厂先于 `pub`/`sub` 被释放时，PC 析构落在一个已经没了的 libwebrtc 线程上。改成全进程共用一个、永不销毁（SSL 也一并挪过去）。另外 `close()` 里在**后台线程**动 `RTCMTLVideoView` 的 UIKit——登记表改成主线程独占 |
| **拨出时看不见自己，随手点一下静音又出来了** | 采集起来之后只 `apply(.setCamera(true))`，而视频通话的 `cameraOn` 本来就是 true，前后状态相等 → `didSet` 不发通知 → 没人去调 `attachLocalPreview`。点静音真的改了状态，顺带触发了一次重挂 |
| 界面显示「已静音」而对方照样听得见 | 发布是异步的，这期间点的静音/关摄像头都以 `cid.isEmpty` 为由静默跳过了，只改了界面。现在发布完成后把界面上的意图补应用一遍 |
| **一枚废票会无限重连**（服务端日志里全是 `token_invalid`，客户端一次 4401 都没看见） | `receive` 失败与 `didCloseWith` 是两条独立的路，谁先到没保证。原先失败时直接按 1001 收尾，而 1001 的语义是「服务端下线，立刻重连」。现在先读 `task.closeCode`，读不到就给代理回调留 150ms |
| 「呼叫名单里含自己」被就地拒掉后卡在「正在呼叫…」 | 只抛 error，界面不知道该退回哪儿。补抛 `onCallEnd{reason:error}` |

**新增：采集画质档位** `IMVideoProfile`（360p / 720p / 1080p，默认 720p），
`IMWebRTCAdapter(videoProfile:)`；simulcast 三层码率跟着档位走，单层发布也压上限。
Demo 的设置页里可选（换档位下一通电话生效）。**画质是宿主策略，不是服务端下发的**——
与换 token 同一条边界（协议 §1.5）。

**2026-09-05 第二轮复测修掉的（本仓这一侧）**：

1. **来电被对方取消 / 自己拒接之后，来电页当场变成通话页**（标题 + 九宫格 +
   本端预览，停一两秒才消失）。实测原话：「为何还弹出一个那个接通才有的界面」。
   两处一起改：**还在响铃的来电结束时直接回 idle，不进结束态**；
   结束态本身也不再复用通话页的骨架，只留居中那一句话
   （拨出没打通的一侧仍然停一下说明原因——那边人是需要知道为什么的）。
2. **九宫格格子被拉伸**。两个人时是 1 行 2 列，每格半个屏宽、整个屏高，
   竖屏上就是两条细长条。现在**格子恒为正方形**，且**行列跟着容器形状走**：
   同样两个人，竖屏上下摞、横屏左右排。规则见 `imGridDimensions`
   （Web 的 `gridDimensions` 是同一个算法，四端共用一份）。
3. 群通话里某人拒接 / 没接之后，**他的格子还挂着「（响铃中）」**——
   从主叫的角度看，对方拒接就跟什么都没发生一样。补订阅了
   `userDidReject` / `userDidNotRespond`。

**2026-09-05 第三轮复测**：**语音通话里不再给摄像头按钮**（拍板见设计文档 §11 第 10 条）。
协议上没有「转视频」这回事，原先那个按钮点了确实出镜、对方确实看得见，
而本端格子的显示条件写的是 `mediaType == "video"`——**自己不知道自己已经出镜了**。
判据是 `media_type` 而不是「本端摄像头开没开」：「以语音接听」的那通电话仍是 video，
按钮要留着（`imShowsCameraButton(for:)`）。

群呼选人名单补到 9 个人。
自己会被过滤掉，原先 8 个名字只剩 7 个可选，**永远凑不出真正的九宫格**
（自己 + 8 = 9 才是 3×3）。

## 下一步

**P3 第五刀 —— 媒体：代码已落地，等真机验收**

`IMWebRTCAdapter` 实现了 `IMMediaAdapter` 的全部方法。**能证明的只有「编得过」**——
音视频一律真机验收（模拟器无摄像头、麦克风受限）。第一次真机跑要看的四件事：

1. 本端预览出画面（`attachLocalView`）；
2. 与浏览器互打，两边都能听见、看见；
3. 静音/关摄像头对端能收到 `userAudioAvailable` / `userVideoAvailable`；
4. **九宫格里层上界真的降档**——服务端日志有「带宽估计调整下发层上界」。

**模拟器上已经跑通到「已连接」**（2026-09-05）：登录 → 握手 → 日志回传落到
`dev-logs/client-ios-alice.log` 并出现在 timeline 里。媒体仍未验（模拟器无摄像头）。

跑法：
- **模拟器**：直接跑，服务器默认 `http://127.0.0.1:8787` 就是对的（模拟器与 Mac 共用网络栈）。
- **真机**：服务器框留空，填 Mac 的局域网 IP——`./scripts/dev.sh` 启动时会打印那一行。
  手机要和 Mac 在同一个 Wi-Fi。填过一次就记住，下次不用再敲。

真机上必须有的两个 Info.plist 键（已配）：`NSAppTransportSecurity.NSAllowsLocalNetworking`
（iOS 默认禁明文 HTTP；127.0.0.1 不受管所以模拟器一直是好的，局域网 IP 受管）
与 `NSLocalNetworkUsageDescription`（iOS 14 起连局域网设备要授权，
**信令和 WebRTC 候选两条都会触发**）。少任一条的症状都是「连不上但不报错」。

**P3 第六刀 —— Kit 剩余界面 + Demo 三屏：已落地（2026-09-05）**
来电横幅（`bannerFirst`）、悬浮球（`floatingWindow`，可拖、吸边、点开还原）、
「以语音接听」、扬声器切换（新公开方法 `setSpeakerOn`，四处同步：协议/门面/实现/ObjC 检查）、
网络质量条。全部**只编译验过，真机没验过**。

**还没做的**：iOS Demo 的「自画 UI」模式（草图 §02-D 那个总开关）。用法 A 在
Web Demo 里已经完整示范，iOS 等回调表稳定后再补一份。

**P4 —— 九宫格的打磨**：格子布局现在是等分网格，草图 §05 还要主讲人放大、
双击切焦点。服务端的 simulcast 与带宽估计都已就绪。
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
- **4401 必须有重试上限**（`IMSignalConnection.maxAuthFailures = 3`，四端同一个数）：
  重连**带的是同一枚 token**，没有上限就是拿同一把坏钥匙永远敲同一扇门。
  Web 端实测过——服务端重启换了签名密钥，一个没关的标签页重试到第 19 次还在敲，
  日志里全是 `token_invalid`，把真正的问题淹掉了。到顶抛 `onKickedOut` 让宿主回登录页。
- **各端已知的两条真 bug，iOS 从第一天就带上了防线**：
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
  **没有为它新造错误码**——错误码表是五仓共用的契约，加一个码等于改五个仓 + 改向量。

- **Kit 的界面代码 macOS 上编不到**：它们全在 `#if canImport(UIKit)` 里，
  `swift build` 会整个跳过——**全绿完全不代表那些文件是好的**。
  真正编它们的是 `test.sh` 第 10 步（Demo 依赖 IMCallKit，为 iOS 编一遍）。
  改 Kit 的 UI 之后光看 `swift test` 绿是不够的。
- **iOS 构建有一批 Sendable 警告**（`SignalConnection.swift` 的
  `Task {}` 闭包捕获 self），macOS 的 `swift build` 看不到。它们**在 Swift 6
  语言模式下会变成错误**，属已知欠账，要单独一刀处理（大概是把
  `IMSignalConnection` 改成 actor 或补 `@unchecked Sendable` 并说明理由）。

- **媒体那一层 macOS 上也编不到**：`IMCallEngineWebRTC` 整个包在
  `#if canImport(WebRTC) && canImport(UIKit)` 里。验它的同样是 `test.sh` 第 10 步
  （Demo 依赖它，为 iOS 编一遍）。已验证过这个闸门不是摆设：往里塞一行类型错误，
  iOS 构建会真的失败。
- **libwebrtc 的实际代价是 43 MB / 首次约 40 秒**（M152，量过的）。
  之后缓存在 `~/Library/Caches/org.swift.swiftpm`，增量构建 0.9 秒、
  `swift test` 12 秒不变。原先「几百 MB」的说法是高估。
- **音频会话要配 `.voiceChat` 模式**：不配的话没有回声消除，自己会听到自己，
  而那听起来像「对方设备有问题」，很容易查错方向。

- **横幅 / 悬浮球模式下 window 铺满全屏但只有那一小块吃触摸**（`IMPassthroughWindow`
  的 `hitTest`），其余点击穿透给宿主。不做这个的话一个 56pt 的小球把整个 App 都挡住。
- **Demo 的记录靠 `pendingPeer` 记主叫的对方**：`callBegin` 的载荷里没有 callee，
  主叫这边只有拨号那一刻知道对方是谁。这是宿主侧的记账，不是回调表缺字段——
  宿主拨号时本来就知道自己拨给了谁。

- **「编得过」离「跑得起来」很远**：模拟器上第一次跑连着崩了两次，两个都是
  编译期完全看不出来的——
  ① Xcode 把 storyboard 引用同时放在 **build setting** `INFOPLIST_KEY_UIMainStoryboardFile`
     里，删了 `Main.storyboard` 和 Info.plist 里的键还不够，那个 build setting 也要删，
     否则启动即崩 `Could not find a storyboard named 'Main'`；
  ② `RTCPeerConnection.delegate` 是 **weak**，`connection.delegate = IMPCDelegate(...)`
     之后对象当场被释放。**必须先留强引用再赋值**。
  以后动 Demo 的启动路径或媒体层，光看 `test.sh` 绿是不够的，要真的跑一次。

- **UIStackView 没有固有尺寸，`setContentHuggingPriority` 对它不起作用。**
  一条「A 顶 B、B 顶 C、C 贴底」的约束链里如果有两个未知高度，就是**欠定**的，
  UIKit 不报冲突、也不报错，只是把剩余空间随便给谁。通话页为此错了三轮：
  先是网格内部用 required 钉死高度、再是控制条吃光了下面三分之二、
  最后是标题区跑到屏幕正中。**结论：这类三段式布局要把两头钉死高度**，
  中间那段的高度才被完全确定。查它最快的办法是给三段各上一个半透明底色，
  一张截图就看出谁占了哪块——比读约束和加日志都快。
- **Kit 的 emoji 图标在设备上会变成方框问号**：emoji 要靠字体回退，
  `UILabel` + 系统字体这条路不保证命中。**图标一律用 SF Symbols**
  （矢量、跟字重、深浅色自适应，而且开/关两态有成对符号）。
- **日志回传要给请求设超时**：`URLRequest` 默认 60 秒，而 `flushing` 那个闩要等回调
  才放开——一个卡住的请求就能让后面**所有日志静默丢掉**，症状是日志文件停在
  某个时间点不动而应用还活着。已设 5 秒。

- **`RTCPeerConnectionFactory` 必须活得比它造出来的 PC 久**，所以它是全进程一份的
  `static let`（`IMPeerConnections.sharedFactory`）。做成实例属性会在通话结束时
  跟着 PC 一起被释放，而 Swift 释放存储属性的顺序未定义——工厂先走就是**挂断即闪退**，
  而且崩在 libwebrtc 内部，看不出跟自己哪一行有关。`RTCInitializeSSL` 同理（全局、无引用计数）。
- **挂载登记表只在主线程上动**（`IMVideoRegistry`）：里面存的是 `RTCMTLVideoView`
  （背后是 `CAMetalLayer`）。锁保护得了字典，保护不了 UIKit——
  在后台线程 `removeFromSuperview()` 一个正在渲染的 Metal 视图，进程是要挂的。
- **远端轨道要「认领」**：`didAdd rtpReceiver` 只带 track_id，归属写在信令帧里，
  **谁先到都可能**。少了 `claimRemoteTracks` 这一步就是「协商全通、首帧照抛、
  但一格画面都不出来」。改媒体层时别把这条丢了。
- **语音通话里没有摄像头按钮**（`imShowsCameraButton(for:)`，与 Web 的
  `showsCameraButton` 同一条判据）。想做「通话中转视频」得先加协议帧
  （`call.upgrade_request` / `upgrade_accept|reject`）= 改五仓，见设计文档 §11-10。
- **格子恒为正方形，行列跟容器形状走**（`imGridDimensions(_:aspect:)`）：
  让格子吃满整块区域（`fillEqually` 两层）的话，竖屏两个人就是两条细长条。
  这条规则四端共用一份，Web 的 `layout/grid.ts` 是同一个算法——**改一边要改两边**。
- **还在响铃的来电结束时不进 ended**：那一侧什么都还没做，结束画面没有意义，
  而 ended 会把通话页的骨架整个铺出来。主叫那一侧相反，必须停一下说明原因。
- **画质是宿主策略**：`IMVideoProfile` 由宿主给，宿主要「后台可控」就把它放进自己的
  配置接口。**改档位要同步服务端 `internal/sfu/bwe.go` 的 `bitrateHigh`**，
  两边对不上会让降层判断按一个错的数字做。

## 关联工程 / 常用命令

- **各端能力对照表：`../im-rtc-server/docs/CLIENT_PARITY.md`**（逐端逐特性状态的**单一真相源**，✅ 只写在那里，本文件不重复）。

- 五仓（本地同级 `/Users/liying/IOSProject/im-rtc/`）：
  [im-rtc-server](https://github.com/BLiYing/im-rtc-server)（**协议契约在这里，只读引用**）·
  **im-rtc-ios**（本仓）· [im-rtc-web](https://github.com/BLiYing/im-rtc-web) ·
  [im-rtc-desktop](https://github.com/BLiYing/im-rtc-desktop) ·
  [im-rtc-android](https://github.com/BLiYing/im-rtc-android)。
- 首批宿主（下游）：`../../IMProgram`（Objective-C iOS App，架构见其 `ARCHITECTURE.md`）。
- 常用命令（脚本随骨架落地）：
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口：两道门禁 + 自检 + 向量可达 + 编译 + 单测
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  swift test --filter CallFSMTests # 只跑某一份向量
  RTC_CONFORMANCE_DIR=/path ./scripts/test.sh   # 向量不在同级目录时
  ```
