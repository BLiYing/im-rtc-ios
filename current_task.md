# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-16（第一轮）：`call.incoming.inviter` + 离场发起人可被重新邀请」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-16（第二轮，已提交 `cbf8c55`，真机验收通过）：来电铃声 + 回铃音，顺带修音频会话时机缺陷。**`./scripts/test.sh` 全绿（10 步，293 例=292 执行+1 skip，含 Demo `BUILD SUCCEEDED`）。

**音频会话时机（治本，没走 Kit 临时切 category 的退路）**：`IMWebRTCAdapter.configureAudioSession()` 原来挂在 `open(_:)`（= `login()`）上，登录一成功就把会话接管成 `.playAndRecord`+`.voiceChat`+active，跟有没有通话无关——宿主背景音乐被掐断（没开 `.mixWithOthers`），响铃期间会话已是通话态、铃声等于没做。查过 iOS 这边没有 Android `IMMediaDriver.drive()`（按 room_token 判「媒体真正启动」）那种集中判断点，媒体是 `IMWebRTCAdapter` 内部按需惰性起（`ensurePeers()`），所以把配置挪到了实际拿麦克风的那一刻：
- `IMWebRTCAdapter.open(_:)` 只接线 events，不再碰会话。
- `acquireMicrophone()` 开头调新方法 `ensureAudioSessionConfigured()`（`audioSessionActive` 标记只配一次，归 `lock`）。
- `answerSubOffer(_:)` 也调它——**这条是收听远端音频那一路**：服务端推 `room.offer(pc=sub)` 后，状态机在同一次 reduce 里就产出应答帧、整条链路跑在 Engine 帧循环里，
  跟 Kit 什么时候起 `Task` 调 `acquireMicrophone()` **没有任何先后约束**，下行 offer 完全可能先到。漏了它的症状是「接通了但听不到对方」，
  而且是这次挪动**新引入**的窗口（旧实现会话在 `login()` 就配好了，永远碰不到）。
- `setSpeakerOn(_:)` **只记选择、不配置会话**（整个方法已搬进 `+AudioSession.swift`）。它一度也是触发入口，理由是 Kit 在「进房即可发布」那一刻先同步调它、再另起 `Task` 异步走到 `acquireMicrophone()`，
  会话没配好时 `overrideOutputAudioPort` 会静默失效。但 `/code-review` 抓到：**那颗扬声器按钮在拨出中（`.outgoing`）就能点**
  （`IMCallOverlayViewController.renderControls` 里 `.outgoing` 落在带 `speakerButton` 的两个分支上；`.incoming` 是 `top = []`，所以只有主叫的回铃音暴露），
  那时回铃音正放着，由它去配置会话等于当场把回铃音掐断或拽到通话路由上——**正好把这次要修的毛病又犯一遍**。
  改成：记进 `desiredSpeakerOn`，已配置就立即应用，没配置就等上面两个入口配好后由 `ensureAudioSessionConfigured()` 补应用，意向不丢。
  **残留限制**：响铃期间点它只决定「接通后用哪路」，不改回铃音本身的外放与否（回铃音是 Kit 的 `AVAudioPlayer` 放的，不归 adapter 管）；按钮亮灭仍跟 `state.selfState.speakerOn`，界面不自相矛盾。
- `close()` 收场对称补上：配置过的话调新方法 `IMWebRTCAdapter+Support.releaseAudioSession()`（`RTCAudioSession.session.setActive(false, options: [.notifyOthersOnDeactivation])`，仍在 `lockForConfiguration` 里做，不绕开 `RTCAudioSession`）；没配置过（只起过预览、mic 从没 acquire 就被挂断）不动会话。
- 没有证据显示这次挪动会破坏 libwebrtc 音频单元的初始化时序：`ensurePeers()`/工厂本来就是惰性建的，配置时机只是从「远早于 PC 创建」挪到「紧邻 PC/轨道创建之前」，方向是更贴近而不是更冒险；`xcodebuild` 编译通过，但**时序是否真的安全只能靠真机听感验证**，见下面「必须真机验证」。

**铃声实现**：
- 素材 `Sources/IMCallKit/Resources/im_ringtone.mp3` / `im_ringback.mp3`，`Package.swift` 给 `IMCallKit` target 加 `resources: [.process("Resources")]`。
- 纯判据 `ringtoneFor(_ state: IMCallViewState, muted: Bool) -> IMRingtoneKind`（`IMCallViewRules.swift`，不带 UIKit，`swift test` 覆盖得到）：`muted`/`isMeeting` → `.none`；`incoming` → `.incoming`；`outgoing` → `.ringback`；其余 → `.none`。停铃按 phase 收敛，不按事件特判（`.callEnd` 在 `incoming` 时直接回 `idle`、不经过 `ended`，两者 default 分支都落 `.none`）。
- 播放层 `Sources/IMCallKit/State/IMCallController+Ringtone.swift`（新文件，`#if canImport(UIKit)`，`AVAudioPlayer`，`numberOfLoops = -1`）；挂载点是 `IMCallController.onStateChanged(from:)`（`state` 的 `didSet` 已去重），**没有**挂 `IMCallControllerObserver.callController(_:didChange:)`（`broadcast()` 在 state 没变时也会被调，会重复触发）。
- `IMCallKitConfig` 加 `incomingRingtone: URL?` / `ringbackTone: URL?`（nil = 内置）/ `ringtoneMuted: Bool = false`；`IMCallController` 新增 `config` 引用（`IMCallKit.init` 换成真实例，语义同 `bannerFirst`——现用现读，不是 init 快照）。
- Demo：`DemoSession.ringtoneMuted` 落 `UserDefaults`（同 `bannerFirst`/`floatingWindow` 写法），`SettingsViewController` 加「静音来电铃声」开关，供真机对照验证。
- 测试：`Tests/IMCallKitTests/RingtoneRulesTests.swift`（6 条，覆盖 incoming/outgoing/会议/muted/其余阶段/两条停铃路径）。

**体量**：改完 `IMWebRTCAdapter.swift` 584 行、`IMCallController.swift` 594 行，都在 600 红线内（`setSpeakerOn` 搬走后主文件又降了 13 行）。
腾行数靠**拆文件**：新建 `Sources/IMCallEngineWebRTC/IMWebRTCAdapter+AudioSession.swift`（58 行）放 `ensureAudioSessionConfigured()`。
**旧注释一个字都没动**——第一版曾为腾额度精简过两个文件里跟本轮无关的旧注释（`RTCPeerConnection` 报废必崩、`lock` 数据竞争、跨 await 代际、
`setSpeakerOn` 不绕开 `RTCAudioSession`、`acquireMicrophone` 的 cid、`close()` 代际，以及 `IMCallController` 顶部三段），
已用 `git show HEAD:` 逐字复原并核对过 diff：两个文件加起来只剩两行删除（`lock` 去掉 `private`、搬走的那句 `configureAudioSession()`），其余全是新增。
**下次再碰这两个文件，腾体量一律拆文件，不许动注释**——那些注释记的是已经付过代价的坑。
（`ringtonePlayer` / `ringtoneKind` 是存储属性，Swift 不允许扩展加存储属性，只能留在主体里，逻辑都在 `+Ringtone.swift`。）

## 下一步

1. **累积未做的真机验收**（上一轮遗留，与本轮无关但仍待办）：API 命名对齐新签名（`callDidEnd`/`activeSpeakersDidChange`/`networkQualityDidChange`/`destroy()`/`openMicrophone`/`openCamera`）；M1/M2 两台设备群呼带 `chatGroupID`、中途 `joinCall` 进房、选人页翻页/搜索/置灰；`call.incoming.inviter` 与「离场发起人可被重新邀请」两条双端联调；1409 两种文案没连过真服务端。IMProgram / 容信真实接入是后续期（M3-M7）。

**待办 / 已知限制**：
- `IMWebRTCAdapter.swift`（594 行）、`IMCallController.swift`（597 行）、`IMCallOverlayViewController.swift`（596 行）、`IMCallEngine.swift`（558 行）、`SignalConnection.swift`（594 行）都逼近或已经很接近 600 行红线（`check-file-size.sh` 目前是 WARN，没超）——下次往这几个文件加东西之前先规划怎么拆。
- **这一轮没做振动**（来电时手机震动），需要时另开一轮引 AudioToolbox / CoreHaptics。
- 宿主自定义铃声（`incomingRingtone`/`ringbackTone`）目前只有代码路径，没有 Demo UI 演示，也没有真机验证过传自定义文件能正常播放。
- `IMInviteMemberProvider` 只有 Demo 一个实现验证过；`presentInvitePicker` 接管路径没有真实宿主跑过。
- **ObjC 状态观察者只有 delegate 形式，没配 block 形式**（`IMCallControllerStateObserver`，CONVENTIONS §4 的「两种都给」没做）：没有宿主提需求，先不加。
- **Kit 在视频通话中摄像头无权限 / 无设备（2001/2002）时没有专门的界面提示**——待补。

## 已知坑 / 限制

- **音频会话不再在 `login()` 时配置**（2026-09-16 改）：如果以后发现某条路径「应该出声却没出声」，先确认是不是漏了 `ensureAudioSessionConfigured()` 这一环（目前挂在 `acquireMicrophone()` / `setSpeakerOn(_:)` 两处），**别把老经验（会话在登录后就绪）当成还成立的前提**。
- **simulcast 没生效，换包暂缓**（2026-09-09 拍板，**别重查**）：`stasel/WebRTC 152.0.0` 没有 `RTCVideoEncoderFactorySimulcast`，三个 encoding 进得了 SDP 但只跑第一个（h），SFU 降层对 iOS 无效。
  选定候选 `webrtc-sdk/Specs 150.7871.01`（`RTC*` 原名、product 同名、0 处改名）；checksum、逐类兼容核对、换包三件事、M152→M150 与 H.264/VP8 取舍、兜底 M144，全在 archive 末节「已知坑」第一条。
  **`IMVideoProfile.simulcastLayers` 的 h,m,l 顺序只能随换包一起改**，单独改成 l 在前 = 当场发 1/4 分辨率。真换包时同步 `CLIENT_PARITY.md` §3 里程碑表。
- **2006 阈值「3」未校准、Kit 不接 2006**（iOS `default: break`）：见 server「已知坑」。
- **别单独 `rm -rf DerivedData`**：Xcode 开着时只删掉 `SourcePackages/`，SwiftPM 命中 `~/Library/Caches/org.swift.swiftpm/artifacts/` 里的 44MB WebRTC zip 就跳过下载然后 `fatalError`
  （`There is no XCFramework found …`），越清越坏。平时用 ⇧⌘K；真要清先退 Xcode 两个一起清：
  `osascript -e 'quit app "Xcode"'; sleep 3; rm -rf ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/org.swift.swiftpm/artifacts`。已踩了就把缓存 zip 挪走（别删）再 `xcodebuild -resolvePackageDependencies`。
- **Kit 界面代码 macOS 上编不到**（`#if canImport(UIKit)`）：`swift test` 绿不算数，只有 `test.sh` 第 10 步编 Demo、碰 `WebRTC.xcframework`。macOS 也要编的 Controller 文件不能引用 `IMKitTheme`（时长常量放 `IMCallViewRules.swift`）；铃声播放层（`IMCallController+Ringtone.swift`）同理全包在 `#if canImport(UIKit)`，改它之后必须跑一次完整 `test.sh`。
- **`join_denied` 不是协议 reason**：`IMCallController` 在 `IMCallKit.joinCall(_:)` 被 1409 拒绝时，把随后到来的 `callDidEnd(reason:"error")` 本地改写成这个伪原因，只用来在结束画面显示「无法加入该通话」，从不上线路、也不在 `IMCallEndReason` 里——四端一致性向量不认识它，改这块时别把它当成协议的一部分去对齐其他端。
- **「人先进来、轨道后到」是常态**：摆格子时做的动作（层上报、尺寸、订阅）要能在轨道到达时再做一遍，别让去重表吃掉补做（`report(_:layer:hasVideo:)`）。
- **通话中关摄像头停的是采集、不是轨道**：重开失败只记日志（按钮开着、格子一直底色）；Kit 每点一次开一个 `Task` 调 `setMuted`，没严格排队；
  `stopCapture()` 在 async 上下文会解析到 async 重载，同步停走 `IMWebRTCAdapter.halt`；本端画布关着时隐藏，靠 `IMVideoRegistry.firstFrameArrived` 揭示。
- 切后台视频被系统暂停：controller 自动 mute 摄像头轨道（对端看到头像）；回前台不替用户打开本来关着的摄像头。
- `RTCPeerConnectionFactory` 全进程一份、永不销毁（否则挂断闪退）；挂载登记表只在主线程动；远端轨道要 `claimRemoteTracks` 认领。
- 下行 call 帧必须按 call_id 过滤：通话中被第三方呼叫时的 `call.ended{busy}` 带的是新来那通的 id。
- 还在响铃的来电结束不进 ended；主叫侧停一下说明原因（`imEndReasonText`，与 Web 逐字对齐）。
- `IMPipView.setContent` 只摘还挂在自己身上的内容（A/B 互换是先钉全屏、再塞小窗）。
- 格子恒为正方形、行列跟容器形状走（`imGridDimensions(_:aspect:)`），五端同一个算法。
- `UIStackView` 没有固有尺寸，三段式要把两头钉死高度（64 / 96）；给 UILabel 插渐变子层没用，用 `IMAvatarDiscView`。
- 图标一律 SF Symbols（`IMKitIcon`），emoji 在设备上会变方框问号。
- 权限状态查询只决定要不要出说明卡，判失败靠真探。
- 公开 API 必须 ObjC 友好（`IMMediaAdapter` 刻意不是 `@objc`）；加公开 API 就往 `IMObjCAPICheck.m` 补一行。
- `JSONSerialization` 分不清 true 与 1（用 `CFBooleanGetTypeID`）；Swift 块注释可嵌套，注释里别写 `/*`。
- 4401 重试上限 3（五端同数）；日志回传请求超时 5 秒。
- 画质是宿主策略（`IMVideoProfile`），改档位同步服务端 `bwe.go` 的 `bitrateHigh`；宿主的选择自己持久化，Engine 不替宿主记。
- SDK 版本号只改 `Sources/IMCallEngine/Facade/IMCallEngineVersion.swift`（五端统一 1.0.0，ObjC 走 `IMCallEngine.sdkVersion`）；Demo 的 `MARKETING_VERSION` 不联动。
  「关于」里「H.264 硬编优先」没实测，看服务端 `上行 Track 已接入 … codec=`。
- Demo 里每条 `guard … else { return }` 都要留一句话：真机上「按钮点了没反应」基本都是静默 return。
- MVP 不覆盖锁屏来电（PushKit + CallKit 属后续期），每次交付都要明说。

## 关联工程 / 常用命令

- 五仓（本地同级）：server（协议契约，只读引用）· **ios**（本仓）· web · desktop · android。首批宿主：`../../IMProgram`（ObjC）。
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口（10 步，末步为 iOS 编 Demo）
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  SKIP_DEMO_BUILD=1 ./scripts/test.sh   # 跳过 xcodebuild（快，但验不到 Kit 的 UI）
  swift test --filter RingtoneRulesTests   # 只跑铃声判据用例
  cd ../im-rtc-server && ./scripts/dev.sh                                   # 起服务端
  RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests # 真服务端联调
  ```
