# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-19（快照整理时移出活快照）」是 09-18 的焦点原文；其上「2026-09-17 傍晚（/simplify 清理收口时移出活快照）」；再往前是「SDK 1.0.0 公网发布后精简：精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 · 发版 server `docs/ops/RELEASE.md` ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

- **09-22 音频路由四选一（听筒 / 扬声器 / 有线耳机 / 蓝牙）：自画面板版，真机 ✅（16:57~17:05 第九轮，grace iOS × alice Android）。**
  起因是用户反馈「插耳机/连蓝牙看不到切换选项」，核实属实（v1.35 只做了「跟随系统」，按钮外观从没变过）。
  先试的系统 `AVRoutePickerView` 那版已废弃（让系统直接改路由、绕开 `RTCAudioSession`，真机双向无声，见「已知坑」）。
  现在跟 Android 同一条路子：自己画面板，经 `RTCAudioSession` 切。
  - Engine 公开 API（设计文档 §7.5，**用户拍板「设备清单式」**）：`IMAudioRoute`（kind + 设备名 + uid）/ `IMAudioRouteKind` 四态 /
    `availableAudioRoutes` / `currentAudioRoute` / `setAudioRoute(_:)` / 回调 `callEngine(_:audioRoutesDidChange:current:)`。ObjC 面在 `IMObjCAPICheck.m` 验过。
  - 清单数据源是 **`availableInputs`（能选哪些）不是 `currentRoute`（在用哪个）**；纯逻辑 `imBuildAudioRoutes` / `imPickCurrentRoute` macOS 可测（9 条）。
  - 切换全程在 `RTCAudioSession.lockForConfiguration()` 里：扬声器走 `overrideOutputAudioPort(.speaker)`，其余先撤覆盖再 `setPreferredInput`
    （**永远不传 nil**，查不到退回内置麦）；**绝不碰 category**（通话中改 category 会把上行停死，真机翻过）。切换时同步 `desiredSpeakerOn`。
  - Kit：`IMAudioRoutePanel`（底部升起、行高 56、当前项打勾、点面板外取消）+ 扬声器键变形（当前路由字形 + 设备名 + `chevron-up`）。
    判据 `imShowsRoutePicker` = 清单多于内置两条。文案 `route.*` 五条在 server `strings.json`。
  **真机结论**：连打三通（语音 → 视频 → 语音）每通 `rtc_was_active=false / elapsed≈40 / inputs=1 / HFP`，每次挂断计数归零、`rtc_active=false`；
  面板扬声器 ↔ AirPods 来回切都落到位（`route_inputs` 跟着走）；用户确认双向都听得到。
  之前拖了 8 轮的「第二通双向无声」根因是 **`releaseAudioSession()` 绕过 `RTCAudioSession` 关底层、激活计数没还**（见「已知坑」第一条），已修。
  群通话用户也测过正常。**蓝牙连着时选「听筒」仍走蓝牙是设计行为**（用户 09-22 拍板：`override(.none)` 就是「交还系统」，
  系统有蓝牙就走蓝牙，不算限制、不要再想着改 category 去「修」它）。CLIENT_PARITY iOS 那行 🟡 → ✅；Android 三处同晚跟上并真机 ✅（v1.65）。
  角标离边 8 → 11（Android 真机反馈 8 压在圆边上，两端同改）；测法 / 判据 / 坑沉淀在 server `docs/ops/AUDIO_ROUTE_TESTING.md`，盯日志用 server `scripts/audiowatch.sh <uid>`。
  - **`/code-review --fix` 补的三处（09-22 晚，`test.sh` 全绿，未上真机）**：
    ① `applyCallAudioCategory` 与 `close()` 之间原来有一道没锁住的窗口——`reassertCallAudioCategory`
    （打断结束 / 媒体服务重置 / 路由变化发现类目不对）先读一次 `audioSessionActive` 再放锁，
    `close()` 若恰好插在这两步中间跑完，那次迟到的 `setActive(true)` 会算进已经清零的 `audioActivations`，
    在下一通电话身上顶账——原样重演这个文件要修的那个泄漏。现在改成锁内二次核实：还是活的才计数，
    不是就当场 `setActive(false)` 还掉，新增日志字段 `orphan_reclaimed`。**这条路径今天没真机走过**，
    真出现看 `orphan_reclaimed=true` 那一行。
    ② `setAudioRoute` 目标设备（蓝牙 / 有线耳机）已经不在 `availableInputs` 里时，原来会直接
    静默改到内置麦（`inputPort(for:)` 的兜底），与 `IMMediaAdapter.setAudioRoute` 协议注释写的
    「静默忽略」不符——现在先判一道 `routeStillAvailable`，真不在清单里就什么都不做；
    `inputPort(for:)` 的内置麦兜底留着，专门防它自己临界区里的协商窗口（不是同一件事）。
    ③ `imRouteChangeDeviceReasons` 被前一刀改成 `public`，理由写的是「`IMCallKit` 的
    `imShouldUpdateRoutePickerAvailability`（`IMAudioRoutePickerPolicy.swift`）也要用」——
    全仓搜不到这个函数或文件，是句悬空引用，改回内部可见性。
    单测补了两条纯逻辑用例（两只蓝牙同时在场时 `imPickCurrentRoute` 按 kind 认、天然分不出哪只在用；
    `audioRoutesChanged(current: nil)` 不该动 `speakerOn`）。
    **仍未处理、留作已知限制**：面板已经开着时若打断/媒体服务重置把会话打回未配置，
    `setAudioRoute` 此时只记得住「要不要外放」这个布尔，记不住用户选的具体蓝牙/有线设备——
    真要补要在 reassert 路径上重放具体设备，属于这次「不主动抢路由、交给系统协商」既定取舍之外的
    新行为，没有真机验证不敢动。
- **09-22 Demo 各页自己的文案也进表了**：`gen-i18n.py` 拆成两份生成物——Kit 表 `IMMessages.gen.swift`（`imT()`）与 Demo 表 `Demo/.../DemoMessages.gen.swift`（`DemoText.swift` 的 `dt()`）。`HistoryTime.swift` 的三档文案改成可注入闭包，默认值仍是原中文——不破坏 `DemoLogicTests` 那张用例表，Demo 侧调用时传 `dt()` 本地化版本。9 个 Demo 文件接入。`test.sh` 全绿（11 步，含 `xcodebuild`）。
- **09-21 多语言（zh-CN / en）iOS 已做**：`IMCallKitConfig.locale` / `messages`，`imT(key)` 取词，文案表由 `scripts/gen-i18n.py` 从 server `docs/i18n/strings.json` 生成；Demo 设置页「语言 / Language」。设计见 server `docs/design/I18N_DESIGN.md`。

- **09-19 头像 / 名字对照设计文档补齐（未提交、未上真机）**：语音大头像页接头像图、接通后标题栏 1v1 走解析器（`imCallTitle(_:resolver:)`）、来电展开页取 inviter、成员列表头像底色改按 uid；新增 ObjC 入口 `IMDebugToken`（DEBUG 调试签票）与 `IMRTCLogBridge`（SDK 日志接进宿主日志）。IMProgram 已按本地 SPM 接入，见其 `current_task.md`。
- **09-19 新增 `IMCallEngine.fetchCallHistory(limit:cursor:)`**（`IMCallEngine+CallHistory.swift`，`GET /v1/calls`，游标翻页，只返回本人）：单测 `CallHistoryTests` 过、全量 406 项过；Demo 通话记录页改成调它（下拉刷新 + 倒数第 3 行加载下一页），本地拼记录那套（`Record` / `records` / 垃圾桶）已删。**未真机验**；依赖服务端 `requireBearer` 不再核对设备号（同日已修）。 09-19 晚记录页布局对齐 Android（左图标 / 中间两行 / 右时间，insetGrouped 卡片），时间按「今天 `HH:mm` / 昨天 / `M月d日` / 往年带年份」四档（`HistoryTime.swift`，`Tests/DemoLogicTests` 8 条用例，符号链接编进测试 target）。**未上真机**。

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
- **18:18 那通前台也断了，原因未定（用户 09-21 判定偶现、忽略；没复现前不追）**：接通 19 s 后信令双向哑掉，服务端一个字节没收到，而客户端 `URLSessionWebSocketTask.send` 每帧都被收下（全段零条 `发帧失败`），36 s 后才以 TCP `Operation timed out` 放弃；同一 WiFi 上的 Android 没事。**别当网络问题结案，也别当已解决。**
- **simulcast 三层 09-21 已开、真机验过**：l/m/h = 270×480 / 540×960 / 1080×1920，帧率 ~30。**未测** CPU / 发热、多人房降层是否生效。

**已收口（细节在 archive「2026-09-19」节）**：会议房 M2 四处 UI 修复（退订再重订画面定格、底部条格子、小格子紧凑名字牌、标题栏点击复制）用户确认已修好；视频通话双向无声（09-18 20:45 真机验过，根因留在「已知坑」）；结束帧表合并 `IMCallExit`、定时器 `imAfter` / `imEvery`、「调用结果回给调用方」`d2d2ae9`（真机未验 `joinCall` 1202/1402/1409 文案、拨号拿 callID、断网再挂断）、四仓 /simplify——均已推送。

## 下一步

1. 后台存活：通话中切后台被系统挂起（见上）——现在麦克风真在录了，先复测一次看 `audio` 后台模式能否保住进程。
2. iOS simulcast 余项：真机看 CPU / 发热；多人房里让某接收者掉带宽，看服务端出现 `to:"m"/"l"`。
3. ~~2.0.0 发版~~ 已发（09-20，tag `2.0.0`）。simulcast 那刀在 tag 之后、未发版。
4. 会议房离场不释放远端视图（暂不修，等真机看到内存问题，见「已知坑」）。
5. 按需 / 后续期：自定义铃声没有 Demo UI、没真机验过；`IMInviteMemberProvider` / `presentInvitePicker` 没真实宿主跑过；IMProgram / 容信真实接入（M3~M7）。

## 已知坑 / 限制
- **「第一通有声、挂断再打就哑」根因：`RTCAudioSession` 激活计数没还（09-22，第九刀才对）。**
  症状：同一进程第一通正常，挂断后第二通（不分语音 / 视频 / 群）双向无声、面板切不动；重启 App 又好一通。
  - **决定性日志**（`dev-logs/client-ios-grace.log`，全天 8 轮 100% 吻合）：第一通 `Number of current activations: 1`
    → `已配成通话态 elapsed_ms=46 inputs=1 outputs=BluetoothHFP`；挂断只见 libwebrtc 自己 `2→1`，**从没归零**；
    第二通 `activations: 2`、`elapsed_ms=3 inputs=0 outputs=BluetoothA2DPOutput` →
    `Failed to set preferred input number of channels -50` → `InitRecording: InitPlayOrRecord failed`。
  - **机制**（`RTCAudioSession.setActive:` 从 WebRTC.framework 反汇编核实，与上游略有出入）：
    `setActive(true)` 只在 `isActive == NO` 时真激活底层，否则只加计数；`setActive(false)` 只在
    `isActive && count == 1` 时真关底层并清 `isActive`，**其余只减计数、`isActive` 保持 YES**。
    旧 `releaseAudioSession()` 为了传 `notifyOthersOnDeactivation` 走 `session.session.setActive(false)`
    ——绕过 `RTCAudioSession` 直接关了底层，它却仍记着 `count=1 / isActive=YES`；下一通 `setActive(true)`
    看 `isActive=YES` 就只加计数，**底层会话根本没激活**，`currentRoute` 看到的是系统闲置态（A2DP、0 输入口）。
    没接蓝牙时音频单元启动会隐式激活会话、用内置麦，所以 09-16 起一直没暴露。
  - **修法**：激活 / 释放全走 `RTCAudioSession.setActive(_:)`（它真关底层时自己传 `notifyOthersOnDeactivation`，
    头文件明写），`audioActivations` 记我们欠几次、`close()` 按数还清；日志新增 `rtc_was_active` / `rtc_active`。
  - **前几刀为什么都错**：`setPreferredInput(nil)`、开场 `applyAudioRoute(defaultRoute())`、切内置时改 category options
    ——看到的 A2DP / `inputs=0` 全是「会话没激活」的表象；后两刀还各自新添了坑（开场钉路由撞 HFP 协商窗口传 nil；
    通话中改 category 把上行停死）。**排查口诀**：`elapsed_ms` 个位数 + `rtc_was_active=true` = 这一刀没做；
    判路由切没切成看 `inputs` / `route_inputs`，不看 `outputs`。
  - **仍没解释的**：16:27:46 那通视频在会话配好之后、libwebrtc 拿到锁配置之前空了 17 s（两条采样日志同一毫秒到齐），
    其余 10 通都是 80 ms。`applySpeakerRoute` 现在记耗时（第九轮最慢一次 339 ms），下次再出现先看它。
  - **`上行音频采样` 的包数 / 采样时长冻住 ≠ 上行死了，先看是不是静音**：这个 webrtc-sdk fork 静音时会真的
    `AudioDeviceIOS::StopRecording`（释放麦克风、橙点熄灭），取消静音才 `StartRecording`，计数在静音期间不动。
    09-22 第九轮我按这个误判过一次「切路由后上行停死」。判上行是否真死：静音期之外计数还不涨才算。
- **别再用 `AVRoutePickerView` 做通话里的路由切换（09-22 真机：两个方向同时无声，拔了蓝牙也不恢复）。**
  症状：AirPods 连上、用系统面板切过一次路由之后，alice(Android) 说话 grace(iOS) 听不到，
  iOS 说话 Android 也听不到；**断开蓝牙依旧无声**。那一版四个文件已删，现在走的是自画面板。
  - **为什么前两轮真机没暴出来**：①点不动 ②面板弹不出，都卡在「根本切不成」，所以从没真正切过一次路由。
  - **违反的是两条白纸黑字的既有约束**（`IMWebRTCAdapter+AudioSession.swift` 头部与 `setSpeakerOn` 注释）：
    「**设置类的入口（改路由、改音量这种）一律不许触发配置，只许记录意向**」——而那版观察者在
    `IMCallController.init()` 就去碰 `AVAudioSession.sharedInstance()`，比 `ensureAudioSessionConfigured()` 早得多；
    「`setSpeakerOn` 走 `RTCAudioSession` 而不是直接碰 `AVAudioSession`——**libwebrtc 自己也在管这个 session，
    绕开它会两边打架**」——而 `AVRoutePickerView` 是让**系统**去改路由，彻底绕开 `RTCAudioSession`。
  - **最像的机制（假说，至今未用日志证实）**：那是媒体/AirPlay 语义的控件，把 AirPods 设为输出时
    很可能落到 **A2DP（只有输出、没有输入）**，而通话要的是 HFP；`.playAndRecord` 撞上没有输入的路由，
    正是 `applyCallAudioCategory` 注释里记过的那个画面——`inputs=0`、`totalSamplesDuration=0`、
    `overrideOutputAudioPort` 回 `-50`。ADM 的 `InitPlayOrRecord` 一旦失败，
    **`RTCPeerConnectionFactory` 全进程一份、永不销毁**，所以拔了蓝牙也不会自愈。
  - **现在这版为什么不该重蹈覆辙**：切换全程在 `RTCAudioSession.lockForConfiguration()` 里、
    只动 `overrideOutputAudioPort` / `setPreferredInput`、绝不碰 category，libwebrtc 全程知情。
    **但这只是推理，同样没上过真机**——验收时第一件事就是「切过一趟之后双向还有没有声音」。
    真出问题看这几行（Xcode 控制台，别等回传——iOS 回传会整批丢）：`音频路由变化 reason=… outputs=…`
    （`BluetoothA2DPOutput` 还是 `BluetoothHFP`）、`上行音频采样 … session.inputs=…`（是不是 0）、
    `音频路由已切换` / `音频路由切换失败`、以及 libwebrtc 的 `InitPlayOrRecord failed`。
  - **设计稿 §04「iOS 不画这张面板，直接用系统 `AVRoutePickerView`」这条已被证伪、但还没改**：
    它还跟同一段里「图标换成当前路由的字形、文案换成设备名」自相矛盾——那个系统控件
    画的是自己的 AirPlay 字形，既不给蓝牙耳机图标也不给设备名文案。**改设计稿要动五仓真相源，待办。**
- **适配器跨通话复用，状态要在 `close()` 里复位**（09-21 真机：后置挂断，下一通还是后置）：`usingFrontCamera` 原先漏了，现已复位；以后给 `IMWebRTCAdapter` 加「每通一份」的状态，都要问一句 `close()` 里清了没有。

- **Demo 开 `.xcodeproj` 与开 `.xcworkspace` 是两个档**：脚本一律 `-workspace`，写成 `-project` 会联网、验的是 GitHub 上的旧代码。workspace 自己的 `Package.resolved` 不落地（Xcode.app 里开过也没有），别当配置错误去追。
- **音频会话不在 `login()` 时配置**（09-16 改）：「该出声没出声」先查是不是漏了 `ensureAudioSessionConfigured()`（挂在 `acquireMicrophone()` / `setSpeakerOn(_:)`）。
- **libwebrtc 的 `webRTCConfiguration` 是会话快照**（09-18 视频通话双向无声真根因，`IMWebRTCAudioConfiguration`）：这个 fork 的 `-[RTCAudioSessionConfiguration init]` 读的是**当下会话的 category/mode**，默认值是首次被碰那一刻的快照（上游写死 PlayAndRecord）。
  视频通话响铃期预览先建工厂 → 快照 = SoloAmbient → 开麦 `-50` → `InitPlayOrRecord failed`；纯音频先配会话后建工厂 → 快照对，同进程之后的视频也好（所以症状「偶然好了」）。
  修法：`sharedFactory` 建之前 + 每次 `applyCallAudioCategory` 时 `setWebRTC(_:)` 钉死 PlayAndRecord/VoiceChat。验收看 `音频会话已配成通话态 webrtc_config=…PlayAndRecord/…VoiceChat`、无 `有人把音频会话写成非通话类目`、`上行音频采样 packetsSent` 在涨。
- **包已换成 webrtc-sdk M150（09-18）；simulcast 09-21 已开（工厂 + 层序同一刀，待真机验）**：`Package.swift` 现在是自己写的
  `.binaryTarget` 指向 `webrtc-sdk/Specs` 的 `150.7871.01`——**不能用 `.package(url:)` 引它**，
  它的 `Package.swift` 近期 tag 全是坏的（声明 `tools-version:5.9` 却用了 6.2 才有的 `.visionOS(.v26)`）。
  模块名仍是 `WebRTC`，所以 `import` 一行没改。**升级要自己算 checksum**：`swift package compute-checksum`。
  **SwiftPM 首次解析偶尔卡成龟速**（冷缓存三次：21 分钟 / 72 分钟 / 64 秒；同期 curl 稳定 2~3 MB/s，
  SwiftPM 拉 stasel 18 秒，两个地址的重定向链和后端一模一样）。**原因没查出来，但是偶发的**，别当阻塞项。
  碰上了就 curl 下来放进 `~/Library/Caches/org.swift.swiftpm/artifacts/<URL 里非字母数字全换成下划线>`。
  **09-21 已做**：`IMPeerConnections.sharedFactory` 套 `RTCVideoEncoderFactorySimulcast`，
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
