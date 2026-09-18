# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-17 傍晚（/simplify 清理收口时移出活快照）」；再往前是「SDK 1.0.0 公网发布后精简：精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 · 发版 server `docs/ops/RELEASE.md` ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-18：会议房 M2 真机验收进行中。M2 的 Engine 与 Kit 两段已在 09-18 凌晨做完（`2ee3527` / `289e3af`，见 server `docs/design/MEETING_ROOM_DESIGN.md` §7 第 2、5 步）。今天全是真机才暴露的修复，`test.sh` 10 步全绿。**

- **⚠️ simulcast 是「说了没做」**（09-18 查出，**未修**）：`publishCamera(simulcast:)` 按
  h/m/l 配了三个 `sendEncodings`、`room.publish` 也报了 `simulcast:true`，但上行统计里**只有 `h.`**
  （房间 41642481：1080×1920、3.1–4.7 Mbps），服务端那条 track 全程只出现过 `to:"h"`。
  根因是 `IMPeerConnections` 用裸 `RTCDefaultVideoEncoderFactory()`，没套 simulcast adapter，
  libwebrtc 只编第一个 encoding。**修不了一行了事**：钉住的 `stasel/WebRTC 152.0.0` 里
  没有 `RTCVideoEncoderFactorySimulcast`（94 个头文件全翻过），要换预编译包 = 动 `Package.swift`
  + 影响已发布的 1.0.0 tag，单独一刀。后果见 server `bwe.go`：订阅侧报 `l` 也只能收这一层 1080p。
- **补了判据日志**（未提交）：`IMAspectVideoView` 加
  `画面缩放判据 owner= view= video= fraction= mode=`（与 Android `IMVideoFitter` 同名字段）。
  09-18 真机上同一个「钉住主画面 + 16:9 源」Android 按判据留黑边、iOS 却铺满，
  而两端日志都看不出各自量到了多大的容器——先把这行补上再定位。
- **退订再重订之后画面定格**（`5324c62`）：M2 第一次让「退订→重订」成为常规动作，
  协议 `track_id` 不变但媒体层拿到的是**新的轨道对象**，而 `IMVideoRegistry.claim` 有一条
  `owners[trackID] != owner` 的闸（「已经认过就别再认」）——归属没变就直接 return，
  新轨道永远躺在 `orphans` 里，渲染器还挂在死掉的旧轨道上。三端同病。
- **演讲者底部条的格子被压成竖条**（`493340a`）：`UIStackView` 的 `fillEqually` 只管「彼此一样宽」，
  这条 stack 自己没有宽度约束、格子又没有 intrinsic size，结果被压成又窄又高的条。
  加 `stripTileSide = 84` 的显式宽约束。
- **小格子里名字一个字都看不见**（`dcdcb71` + `1345685`）：名字牌宽度上限是 `trailing - 40`，
  84pt 的格子里只剩 32pt，而牌子里固定要吃掉 `8 + 5 + 9 + 8 = 30pt`——**留给名字的正好 2pt**。
  先把上限改成只留一个边距并让名字截断；再加一档**紧凑排版**（边长 < 110 自动换档，
  留白 12→4、字号 12→10，固定件压到 28pt），三端同值。
- **标题栏改成写房号、点一下复制**（`dbff38c`）：人数只留右上角「👥 N」，标题不再重复同一个数字。
  `IMCallHeaderView.apply` 多一个默认参数 `titleIsCopyable`（源码兼容）。

**真机没验**：以上四条**都还没装到手机上过**（用户最后一次重装在 `1345685` 之前）。
下一轮装机要重点看：翻走 >10 秒再翻回画面恢复、底部条名字、新标题栏与点击复制。

**服务端侧与本端相关的两条**（都已修，见 server `current_task.md`）：编解码裁剪不幂等导致
「iOS 收不到 Web 的 VP8 / Android 收不到 iOS 的 H.264」；重协商之后要补关键帧。

**2026-09-17 夜：可取消定时器抽成 `Support/IMTimer.swift`（队列 5 的定时器样板）**：`imAfter` / `imEvery` 是 `package` 级别（三个 target 共用、宿主看不见），
`makeTimerSource` 15 处全换掉（Engine 5 / WebRTC 1 / Kit 9），`IMTimerTests` 3 例。`DispatchWorkItem + asyncAfter` 那几处语义不同，没动。行为不变。

**2026-09-17 夜：结束帧映射表合并（队列 3）**：四份「这个状态怎么结束」合成 `StateMachine/CallStateMachine+Exit.swift` 的 `IMCallExit`
（`reduceAct` 退出方法 / `endFrames` / 迟到帧补发与挂着的 cancel / 帧循环失败收场集合都查它），`CallExitTableTests` 逐条对 `call_fsm.json`。行为不变。

**2026-09-17 夜：「调用结果回给调用方」2.0.0 改造（server `docs/design/ACTION_RESULT_DESIGN.md`）已提交 `d2d2ae9`（未推送），code-review 已过。**
发起类方法改 `async throws`（`call` 返回 callID）、本地拒绝走 `IMMachineOutput.reject`、`IMFrameLoop.request` 结算直接帧、
`IMRTCError.forType`、destroy 契约（`DestroyContractTests`）、Kit 从 throw 取码（删 `joiningCallID` / `pendingJoinDenial`）；Kit 主动加入任何失败都是「无法加入该通话」（对齐 Web / Android）。`test.sh` 10 步全绿 + Demo 编译。
真机未验（joinCall 1202/1402/1409 文案、拨号拿 callID、通话中断网再挂断）。

**2026-09-17 傍晚：四仓 /simplify 清理做完并推送（本仓 `dc76a99`…`7c3f457`，`test.sh` 10 步全绿 322 例 + Demo 编译；用户已复看，正常）。**
- 行为不变：`IMEmittedEvent.error(_:)` 工厂、`IMSysErrorFrame.decode` 推送 / 应答共用、状态机 `out` / `invalidStateOutput` 合并、周期事件先 `IMRTCLog.isEnabled` 再拼字段、`sys.pong` 不进帧泵、`stampCallStart` 单字段比较；
  WebRTC 适配器 `ensurePeers` 取一次、`close()` 取消开摄像头 Task；Kit 色值 / 弹簧 / 小头像 44 收进 `IMKitTheme`，`imPinEdges` / `imConfigureCircleIconButton`，悬浮球贴边下沉 `Layout/IMFloatingBubbleLayout.swift`（有单测）。
- **行为变化只在 Demo**：通话记录改用 `imEndReasonText`（hangup 显示「通话结束 · 时长」，offline / answered_elsewhere 等不再显示英文）；`DemoSession.onChange` 改 `add/removeChangeObserver`。
- 09-17 下午（体量五刀、block 状态观察者、来电振动、用户真机验收旧 1、2）已移进 archive。

## 下一步

1. 2.0.0：真机验上面三项（断网再挂断顺带验结束帧表），用户通知后发版。
2. 按需 / 后续期：自定义铃声没有 Demo UI、没真机验过；`IMInviteMemberProvider` / `presentInvitePicker` 没真实宿主跑过；IMProgram / 容信真实接入（M3~M7）。

## 已知坑 / 限制

- **Demo 开 `.xcodeproj` 与开 `.xcworkspace` 是两个档**：脚本一律 `-workspace`，写成 `-project` 会联网、验的是 GitHub 上的旧代码。workspace 自己的 `Package.resolved` 不落地（Xcode.app 里开过也没有），别当配置错误去追。
- **音频会话不在 `login()` 时配置**（09-16 改）：「该出声没出声」先查是不是漏了 `ensureAudioSessionConfigured()`（挂在 `acquireMicrophone()` / `setSpeakerOn(_:)`）。
- **simulcast 没生效，换包暂缓**（09-09 拍板，**别重查**）：`stasel/WebRTC 152.0.0` 没有 `RTCVideoEncoderFactorySimulcast`，三层只跑 h。候选 `webrtc-sdk/Specs 150.7871.01`，核对全文在 archive「已知坑」第一条。
  **`IMVideoProfile.simulcastLayers` 的 h,m,l 顺序只能随换包一起改**（单独改 = 当场发 1/4 分辨率）；换包时同步 `CLIENT_PARITY.md` §3。
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
