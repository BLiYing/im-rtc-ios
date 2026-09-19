# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-19（快照整理时移出活快照）」是 09-18 的焦点原文；其上「2026-09-17 傍晚（/simplify 清理收口时移出活快照）」；再往前是「SDK 1.0.0 公网发布后精简：精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 · 发版 server `docs/ops/RELEASE.md` ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-19：三处修完，真机已验（iPhone 14 Pro 当发布方 × Chrome，`delay` 8 s + `silence` 80 s），已推送。**
- **握手超时不再干等服务端**（`8496a8f`，对齐 Android `closeAndReconnect` / Web `retireStaleSocket`）：`SignalConnection.handshake()` 失败码为 `signalingTimeout` 时本端以 1001 `hello timeout` 关 socket（原先不关、不重连，要干等 45 s 读超时）；
  `startConnect` 先 `retireStaleSocket()` 关旧的，socket 回调按 `ObjectIdentifier` 只认当前那条。`HandshakeTimeoutTests`（撤修复会失败）。真机三次 `hello timeout` 都由本端关 → 退避重连 → resumed → 补发 publish。
- **发布没等到应答的挂起重放从没生效过**（`1c540d5`）：`publish_deferred` 没登记进 `roomInternals`，事件落到通话机被静默丢掉，那一路永远停在 publishing；会议房还被 `ctx.call.state != .idle` 排除在挂起之外。两处补上，引擎级测试会议房 / 通话各一条。09-18 傍晚的 `bfbf7c9` 当时以为做完了，其实这条路是死的。
- **采集会话看门狗**（`0017680`）：`IMCaptureWatch` 的观察者关摄像头时立即摘掉（adapter 跨通话复用，纯语音几通里一直挂着）。
- **`ping_interval_sec` 钳到 [5,60]**（缺省 / 非正数按 15，与 Android 同值，`Heartbeat.clampedIntervalSec`，`HeartbeatTests`）；同批 Web `heartbeat.ts` 判死由 `>` 改 `>=`（原先 60 s 才判死，与其余端 45 s 不齐）。未上真机，CLIENT_PARITY 还没记这两条；**间隔钳制 Web / 桌面还没做**（已记在两仓「下一步」）。
- **回前台 / 网络变化立即重连**（09-18 晚，`f8bd7fa`，`SignalConnection+Nudge.swift`，与 Android 对齐）：iOS 回前台也探「连着」的（挂起过多半是假的）；两次至少隔 2 s。**救不了「后台被挂起超过 30 秒」**。状态见 CLIENT_PARITY `[^netchange]` `[^pubdefer]`。
- 装机：`xcodebuild -workspace Demo/IMRTCDemo/IMRTCDemo.xcworkspace -scheme IMRTCDemo -destination 'id=00008120-000131121E50C01E' -derivedDataPath .build/device-dd -allowProvisioningUpdates build` + `xcrun devicectl device install app --device E551B989-ADE1-528B-B043-9445498E8560 …/IMRTCDemo.app`。

**仍悬着（09-18 傍晚记下，没结案）**：
- **后台掉线 = App 被系统挂起**：18:04 切后台 → 18:05 恢复窗口（30 s）到期 → `reason=network`；App 整整 4 分钟零日志，客户端任何定时参数都救不了没在运行的进程。出路是让 App 在通话中别被挂起（`UIBackgroundModes` 只有 `audio`，靠活跃音频 I/O 保活，未证实）。
- **18:18 那通前台也断了，原因未定**：接通 19 s 后信令双向哑掉，服务端一个字节没收到，而客户端 `URLSessionWebSocketTask.send` 每帧都被收下（全段零条 `发帧失败`），36 s 后才以 TCP `Operation timed out` 放弃；同一 WiFi 上的 Android 没事。**别当网络问题结案，也别当已解决。**
- **simulcast 三层没开**：见「已知坑」里「包已换成 webrtc-sdk M150」那条。

**已收口（细节在 archive「2026-09-19」节）**：会议房 M2 四处 UI 修复（退订再重订画面定格、底部条格子、小格子紧凑名字牌、标题栏点击复制）用户确认已修好；视频通话双向无声（09-18 20:45 真机验过，根因留在「已知坑」）；结束帧表合并 `IMCallExit`、定时器 `imAfter` / `imEvery`、「调用结果回给调用方」`d2d2ae9`（真机未验 `joinCall` 1202/1402/1409 文案、拨号拿 callID、断网再挂断）、四仓 /simplify——均已推送。

## 下一步

1. 后台存活：通话中切后台被系统挂起（见上）——现在麦克风真在录了，先复测一次看 `audio` 后台模式能否保住进程。
2. iOS simulcast 三层：套 `RTCVideoEncoderFactorySimulcast` + 层序改 l,m,h 同一刀（见「已知坑」）。
3. 2.0.0：真机验 `joinCall` 文案 / 拨号 callID / 断网再挂断，用户通知后发版。
4. 会议房离场不释放远端视图（暂不修，等真机看到内存问题，见「已知坑」）。
5. 按需 / 后续期：自定义铃声没有 Demo UI、没真机验过；`IMInviteMemberProvider` / `presentInvitePicker` 没真实宿主跑过；IMProgram / 容信真实接入（M3~M7）。

## 已知坑 / 限制

- **Demo 开 `.xcodeproj` 与开 `.xcworkspace` 是两个档**：脚本一律 `-workspace`，写成 `-project` 会联网、验的是 GitHub 上的旧代码。workspace 自己的 `Package.resolved` 不落地（Xcode.app 里开过也没有），别当配置错误去追。
- **音频会话不在 `login()` 时配置**（09-16 改）：「该出声没出声」先查是不是漏了 `ensureAudioSessionConfigured()`（挂在 `acquireMicrophone()` / `setSpeakerOn(_:)`）。
- **libwebrtc 的 `webRTCConfiguration` 是会话快照**（09-18 视频通话双向无声真根因，`IMWebRTCAudioConfiguration`）：这个 fork 的 `-[RTCAudioSessionConfiguration init]` 读的是**当下会话的 category/mode**，默认值是首次被碰那一刻的快照（上游写死 PlayAndRecord）。
  视频通话响铃期预览先建工厂 → 快照 = SoloAmbient → 开麦 `-50` → `InitPlayOrRecord failed`；纯音频先配会话后建工厂 → 快照对，同进程之后的视频也好（所以症状「偶然好了」）。
  修法：`sharedFactory` 建之前 + 每次 `applyCallAudioCategory` 时 `setWebRTC(_:)` 钉死 PlayAndRecord/VoiceChat。验收看 `音频会话已配成通话态 webrtc_config=…PlayAndRecord/…VoiceChat`、无 `有人把音频会话写成非通话类目`、`上行音频采样 packetsSent` 在涨。
- **包已换成 webrtc-sdk M150（09-18），但 simulcast 还没开**：`Package.swift` 现在是自己写的
  `.binaryTarget` 指向 `webrtc-sdk/Specs` 的 `150.7871.01`——**不能用 `.package(url:)` 引它**，
  它的 `Package.swift` 近期 tag 全是坏的（声明 `tools-version:5.9` 却用了 6.2 才有的 `.visionOS(.v26)`）。
  模块名仍是 `WebRTC`，所以 `import` 一行没改。**升级要自己算 checksum**：`swift package compute-checksum`。
  **SwiftPM 首次解析偶尔卡成龟速**（冷缓存三次：21 分钟 / 72 分钟 / 64 秒；同期 curl 稳定 2~3 MB/s，
  SwiftPM 拉 stasel 18 秒，两个地址的重定向链和后端一模一样）。**原因没查出来，但是偶发的**，别当阻塞项。
  碰上了就 curl 下来放进 `~/Library/Caches/org.swift.swiftpm/artifacts/<URL 里非字母数字全换成下划线>`。
  **下一步**：`IMPeerConnections.sharedFactory` 套 `RTCVideoEncoderFactorySimulcast`，
  同时把 `IMVideoProfile.simulcastLayers` 的 h,m,l 改成 l,m,h（Android / Web 都是低→高，libwebrtc 要求如此；
  **两件事必须同一刀**——单独改顺序 = 当场发 1/4 分辨率，因为现在只有第一条 encoding 生效）。
  开三层后验收看服务端是否出现三条 `to:"h"/"m"/"l"`，**并且每个 rid 的分辨率对得上**（只数三条会被顺序错骗过去）。
- **2006 阈值「3」未校准、Kit 不接 2006**（`default: break`）：见 server「已知坑」。
- **别单独 `rm -rf DerivedData`**：Xcode 开着时 SwiftPM 命中缓存 zip 跳过下载然后 `fatalError`（`There is no XCFramework found`）。平时 ⇧⌘K；真要清先退 Xcode：
  `osascript -e 'quit app "Xcode"'; sleep 3; rm -rf ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/org.swift.swiftpm/artifacts`。
- **Kit 界面代码 macOS 上编不到**（`#if canImport(UIKit)`）：`swift test` 绿不算数，要跑完整 `test.sh`（第 10 步编 Demo）。macOS 也编的 Controller 文件不能引用 `IMKitTheme`；`IMCallController+Ringtone.swift` 全包在 `#if canImport(UIKit)`。
- **新定时器用 `imAfter` / `imEvery`**（`package`，别改成 `public`）：返回的已经 resume 过，调用方自己持有、自己 `cancel()`。
- **结束帧一律查 `IMCallExit`**：别在状态机 / 帧循环里再手写「某状态发 hangup / reject / cancel」，改表要同时过 `CallExitTableTests`。
- **`join_denied` 不是协议 reason**：`IMCallController` 在 `joinCall` 被拒（任何码）时本地改写的伪原因，只用于结束画面，别拿去和其他端对齐。
- **「人先进来、轨道后到」是常态**：摆格子时的动作（层上报、尺寸、订阅）要能在轨道到达时再做一遍，别让去重表吃掉（`report(_:layer:hasVideo:)`）。
- **通话中关摄像头停的是采集、不是轨道**：重开失败只记日志；`stopCapture()` 在 async 上下文解析到 async 重载，同步停走 `IMWebRTCAdapter.halt`；本端画布靠 `IMVideoRegistry.firstFrameArrived` 揭示。
- 切后台 controller 自动 mute 摄像头；回前台不替用户打开本来关着的摄像头。
- `RTCPeerConnectionFactory` 全进程一份、永不销毁；挂载登记表只在主线程动；远端轨道要 `claimRemoteTracks` 认领。
- **会议房离场的人，轨道 / 视图要到整通结束才释放**（09-18 评审记下、**有意暂不修**）：`IMVideoRegistry` 四张表
  只有 `removeAll()`（挂断 / 登出）清远端，`remove(owner:)` 只用于本端预览。代价是 25 人长会议里进出越多内存越涨
  （只是引用，下行已停、不占带宽和解码）。留着是为了断线重连时画面不闪；**要修得分清「真离场」（`room.participant_left`）
  与「掉线待恢复」**，只在前者按 owner 清。等真机看到内存问题再动。
- 下行 call 帧必须按 call_id 过滤（第三方呼叫的 `call.ended{busy}` 带新来那通的 id）；还在响铃的来电结束不进 ended。
- `IMPipView.setContent` 只摘还挂在自己身上的内容；格子恒为正方形（`imGridDimensions(_:aspect:)`，五端同算法）。
- **Kit 的颜色 / 弹簧 / 尺寸字面量一律进 `IMKitTheme`**，贴边 / 吸角算术放 `Layout/` 纯函数配单测（macOS 能编）。状态机的 `out` / `invalidStateOutput` 是 `MachineTypes.swift` 里的模块级函数：别在状态机类型里再加同名 `static func out`，会把它遮住。
- `UIStackView` 三段式要把两头钉死高度（64 / 96）；渐变头像用 `IMAvatarDiscView`；图标一律 SF Symbols（`IMKitIcon`）。
- 权限状态查询只决定要不要出说明卡，判失败靠真探。
- 公开 API 必须 ObjC 友好（`IMMediaAdapter` 刻意不是 `@objc`）；加公开 API 就往 `IMObjCAPICheck.m` 补一行。
- `JSONSerialization` 分不清 true 与 1（用 `CFBooleanGetTypeID`）；注释里别写 `/*`（Swift 块注释可嵌套）。
- 4401 重试上限 3（五端同数）；日志回传请求超时 5 秒。
- 画质是宿主策略（`IMVideoProfile`），改档位同步服务端 `bwe.go` 的 `bitrateHigh`。
- SDK 版本号只改 `Sources/IMCallEngine/Facade/IMCallEngineVersion.swift`（五端统一，发版还要改 Demo 的 `exactVersion`，见 RELEASE.md）；Demo `MARKETING_VERSION` 不联动。
- Demo 里每条 `guard … else { return }` 都要留一句日志：真机「点了没反应」基本都是静默 return。
- MVP 不覆盖锁屏来电（PushKit + CallKit 属后续期），每次交付都要明说。

## 关联工程 / 常用命令

- 五仓（本地同级）：server（协议契约，只读引用）· **ios**（本仓）· web · desktop · android。首批宿主：`../../IMProgram`（ObjC）。
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口（10 步，末步编 Demo，走 workspace）
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  SKIP_DEMO_BUILD=1 ./scripts/test.sh   # 跳过 xcodebuild（快，但验不到 Kit 的 UI）
  cd ../im-rtc-server && ./scripts/dev.sh                                   # 起服务端
  RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests # 真服务端联调
  xcodebuild -project Demo/IMRTCDemo/IMRTCDemo.xcodeproj -scheme IMRTCDemo -destination 'generic/platform=iOS Simulator' build   # 公网包档
  ```
