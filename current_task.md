# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：只记当前状态，**就地覆盖、不追加**。历史见 `git log` 与
> [current_task.archive.md](current_task.archive.md)（只读归档，2026-09-06 搬入）。
> 工程规范见 [CONVENTIONS.md](CONVENTIONS.md)；方案与分期见 `im-rtc-server` 的
> `docs/design/RTC_CALL_DESIGN.md` §10；**界面以设计稿 v3 为准**：
> `../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html`（令牌 / 图标 / 组件红线）与
> `RTC_CALL_UX_FLOWS.html`（权限 / 小窗 / 互换 / 加人）。**两稿已升到 v3.1**——
> v3.1 推翻了 v3 的六条（小窗入口、视频版式退化、小窗挂断、呼叫页标题、Android 画中画与全屏），
> 冲突时以 v3.1 为准。


## 当前焦点

**2026-09-11：接听时的摄像头权限，三端一起对齐交互稿 `RTC_CALL_UX_FLOWS.html` §01 权限时机表 + §11-10。已合 main，用户自己打包真机验。**

本仓两处：

1. **群视频接听补问摄像头**。原先按 `cameraOn` 判要哪些设备，群通话默认关摄像头，于是群接听从来不问摄像头——
   与权限表「接听群通话 → 麦克风 + 摄像头」不符，也和 Web / Android 不齐。
   现在走 `imPermissionDevicesForAnswering(mediaType:cameraOptedOut:)`（与 Android / Web 同一条判据）：
   视频且没在来电页亲手关摄像头 → 两样都要。`cameraOptedOut` 只在 `.incoming` 阶段切摄像头时置位，群通话默认关不算。
2. **过权限门不再替用户开摄像头**。原先摄像头拿 `startLocalPreview` 探、探完还 `setCamera(true)`：
   群通话默认关着进来，过一遍权限门按钮就亮了、摄像头也真开着。现在 `probeDevice` 只问系统权限，
   预览由 `startPreviewIfWanted()` 看 `cameraOn` 决定（群通话拨出中打开摄像头也从这里起预览）。

`RTC_CONFORMANCE_DIR=… ./scripts/test.sh` 全绿（10 步，205 用例 + 1 跳过）。**worktree 里必须带那个环境变量**。
**本仓这一刀没上过真机**（同一套规则 Android 在 PKD130 上验过）。

**simulcast 换包方案已验证完、暂缓**（2026-09-09 拍板），结论与 checksum 全在「已知坑」第一条，不用重查。

## 下一步

- **本仓的静默失败点清单**（P0×3 / P1×7 / P2×8，2026-09-09 扫描）见
  `../im-rtc-server/docs/ops/silent-failure/ios.md`，跨端结论与修复顺序见同目录的
  `SILENT_FAILURE_AUDIT.md`。**逐条状态只在那里维护，别抄回本文件。**
  未修的头两条：麦克风推流失败被 `try?` 吞掉（接通了但一个字都没发出去）、权限卡 continuation 可永久挂起。

### 真机验收

**本轮优先（摄像头权限这一刀）**：

1. **群视频接听**：弹麦克风 + 摄像头两样；接通后自己那格是头像、摄像头按钮关态、对端看不到画面；点开后对端看得到。
2. **1v1 视频来电页关摄像头再接**（先在设置里关掉相机权限）：只弹麦克风、能接通；接通后点开摄像头 → 「无权限」、通话不断。
3. **群视频拨出**：摄像头默认关、不起预览；拨出中点开 → 看得见自己。

**上一轮挂着的**（分支 `worktree-fix-autohide-arm-gate`，1v1 视频）：接通后控制条完整停 3 秒再淡出；挂断后结束画面标题栏不淡掉。

### 真机验收（**这一整批一条都没验**）

按风险排序，前两条不过其余不用看：

1. **语音判定**（server）：`SPEECH_DEBUG=1 ./scripts/dev.sh` → 不说话时是不是真的不亮了；
   说话时亮不亮、条高随音量变不变；把 `margin` 的实测值发回来核门槛。
2. **说话指示器三态**：别人的格子「关 / 开着没说话 / 正在说话」，自己那格只有前两态；
   1v1 不显示说话但显示麦克风开关；多人同时说话每格各亮各的。
3. **Android 呼叫中按静音**：**接通前**按静音 → 对方接 → 确认对方听不见，
   且日志里有 `补做发布前攒下的静音`。（上次验成了「接通后按」，没走到修复那条路。）
4. **iOS 镜像**：翻到后置摄像头，自己看到的字不该是反的。
5. **web 挂断后重进**：bob 进群通话 → 挂断 → 再邀请回来 → 这次该看得到他的画面。
6. **通话时长**：群通话里中途加入的人退出后，记录里的时长是他自己那段，不是整通。
7. 之前那七条 code-review 修复也都没验（故障注入手册 `docs/ops/FAULT_INJECTION.md`）。

### 待办

- **下一个任务（已和用户对齐）**：四端扫一遍**静默失败点**——早退分支、被吞掉的异常、
  静默空实现。今天两个 bug 全是这一类（一句不吭的 `return`，界面/日志/报错三个观测面
  同时是瞎的）。只给真正可疑的加日志，判据卡死到「正常时一通电话最多出现一次」。
- **desktop 端说话指示器没做**：它 `MediaAdapter` 唯一实现是 `tests/FakeMediaAdapter.h`，
  libwebrtc 还没接进来，九宫格本身就是 ⬜。要等媒体面落地。
- **`CLIENT_PARITY.md` 没更新**：真机验完再改；验之前 iOS/Android 停在 🟡，不写 ✅。
- **web 端 `getUserMedia` 那类失败仍可能静默**：日志回传够不到浏览器 console。


## 已知坑 / 限制

- **本仓的 simulcast 其实没生效；换包方案已验证完毕，但 2026-09-09 决定暂缓。**

  **决定**：暂时不换（用户拍板 2026-09-09）。理由是现阶段三端画面都看得见，
  「Android 在 iOS 上偏糊」已由另外两刀缓解（`im-rtc-android` 的上行预算播种 +
  `im-rtc-server` 的 BWE 死锁修复），清晰度问题可以靠后。**下面这份验证结果是留着做决定用的，
  不要重新查一遍。**

  ### 现状：为什么没生效

  `stasel/WebRTC` exact `152.0.0` **没打进 `RTCVideoEncoderFactorySimulcast`**——
  94 个头文件里没有，`nm -g WebRTC | grep -i simulcast` 也是空。
  `acquireCamera(simulcast:)` 造的三个 `RTCRtpEncodingParameters` 进得了 SDP
  （服务端看到的是 `rid=h` 而不是空串），但只有一个编码器在跑。
  **证据**：服务端全量日志里 H264 视频轨道 101 条**全是 1 层**，从没出现过 2 层或 3 层。

  后果是**降层只砸别人**：iOS 发的流没有低层可掉，SFU 的 `bw_cap=l` 对它无效
  （`selectLayer` 兜底到「发布端最低的那层」= h）。同一份日志里 iOS 的下行 21 条
  即使 17 条 `bw_cap=l` 也照发 h；VP8 那边 32 条有 20 条真降到了 `l`。
  **「为什么只有 Android 糊」的答案在这里**，不在 Android 的编码参数上。

  ### 候选包：两个都下载验过（校验过官方 checksum）

  | | **webrtc-sdk/Specs** ← 选它 | LiveKit/webrtc-xcframework | 现在的 stasel/WebRTC |
  |---|---|---|---|
  | 版本 | `150.7871.01` | `150.7871.01` | `152.0.0` |
  | `RTCVideoEncoderFactorySimulcast` | 头文件 + 符号都在 | 在，但叫 `LKRTC*` | **不存在** |
  | 类名前缀 | **原样 `RTC*`** | 全部 `LKRTC*` | `RTC*` |
  | SwiftPM product 名 | **`WebRTC`**（与现在同名） | `LiveKitWebRTC` | `WebRTC` |
  | 改名工作量 | **0 处** | ~110 处 / 5 个文件 | — |

  `webrtc-sdk/Specs` 的 SwiftPM 声明（`Package.swift` 里换成 `binaryTarget`）：

  ```
  url:      https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip
  checksum: 03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa
  ```

  **兼容性做过逐类核对**：本仓用到的 30 个 `RTC*` 类型在新包里**一个都不缺**。
  类数 stasel152=70 / webrtc-sdk150=88，是真超集（多出 `RTCFrameCryptor` 等 19 个），
  只少一个 `RTCDtlsFingerprint`（本仓没用）。

  ### 换包时要一起做的三件事

  1. `Package.swift` 换依赖声明（`binaryTarget` + 上面那个 checksum）。
  2. `IMPeerConnections.sharedFactory` 套上 adapter：
     `RTCVideoEncoderFactorySimulcast(primary:fallback:)`（头文件里就这一个初始化方法）。
  3. **`IMVideoProfile.simulcastLayers` 的顺序改成 l, m, h** —— 见下面那条坑，
     它**只能和第 2 步一起改**。

  ### 换包时才能改的那一行（单独动 = 纯回归）

  `simulcastLayers` 现在是 h, m, l（`scaleResolutionDownBy` 1, 2, 4），按 libwebrtc
  的要求是反的（要从大到小，见 Android `IMVideoProfile.kt` 的注释）。
  **但 simulcast 没生效时真正跑起来的是第一个 encoding**，现在第一个是 h（满分辨率）；
  改成 l 在前，iOS 会当场开始发 1/4 分辨率。**看着像一行就能修的 bug，其实是回归。**

  ### 决定前要先想清的两件事

  - **里程碑是往回走的**：M152 → M150。`webrtc-sdk` 那条线没有比 M150 更高的
    （`144.7559.15` 日期虽新但那是维护中的 M144 老线）。所以「既要 simulcast、
    又要 ≥M152」这个组合不存在。M150 发布于 2026-08-31、仍在维护，
    不是当初否掉 `bengreenier/webrtc` 那种冻在 M115 的死包。
  - **codec 选 H.264 还是 VP8 得实测**：新包里 `RTCDefaultVideoEncoderFactory`
    有 `preferredCodec` 属性，可以显式钉住、不必听凭默认注册顺序。但两条路都有代价——
    钉 H.264 保住硬件编码（省电省热），却和 §11 #4 定的「**VP8 做基线**」相左，
    而且 H.264 跨端要跑 `CLIENT_PARITY.md` 那份三条实测清单；走 VP8 与 Android/Web 一致，
    代价是 iPhone 上**三路 libvpx 软编**的 CPU 与发热。只有真机测得出来。

  ### 兜底

  `144.7559.15` 在 **iOS 与 Android 两条线上都有**（webrtc-sdk 两个平台版本号同步发布），
  Android 的 `libs.versions.toml` 本来就写着兜底这一版。所以万一 M150 真机出问题，
  两端能一起退到 M144，退路是对称的。

  ### 真要换的时候还要动的

  `../im-rtc-server/docs/CLIENT_PARITY.md` §3 那张里程碑表（那是跨仓真相源，
  版本状态**只写在那里**）。§4 写了什么时候该改那张表。
  **现在不用改**——表上写的 iOS = stasel 152.0.0 / M152 仍然是事实。

- **2006 的阈值「3」没经过真机校准，而且它现在抛出来也没人接。** 两件事一起记（2026-09-09）：
  - **阈值待校准**：libwebrtc 判 `failed` 约 30 秒一轮，连续 3 次就是**一分半以后**宿主才知道，
    用户多半早挂了。真机弱网跑过之后很可能要调成 2 次、或者改成按时间而不是按次数。
    四端 libwebrtc 版本还不一样（iOS M152 / Android M150 / 桌面 M150 / Web 是浏览器自带），
    `failed` 的触发时机不见得对得齐——这条只有真机验得出来。
  - **目前它在界面上等于不存在**：四端 Kit 的错误出口都只认几个码
    （Web uikit 2 个、iOS `default: break`、Android `when` 没有 `else`），2006 落地即消失。
    所以现在**回归风险≈0，价值也≈0**，要等 Kit 那几个兜底补上才通。
  - 弱网环境暂缓搭建（2026-09-09 决定），有条件再做。

- **「人先进来、轨道后到」是常态，不是异常**：`onUserEnter` 那一刻他的远端视频轨道往往还没到。
  任何「摆好格子就顺手做一次」的动作（层上报、尺寸、订阅）**都要能在轨道到达时再做一遍**，
  且别让去重表把补做的那次也吃掉——层上界为此空转过整整一版（`report(_:layer:hasVideo:)` 已补）。

- **别单独 `rm -rf ~/Library/Developer/Xcode/DerivedData`**（2026-09-06 踩，半小时）：Xcode 开着时
  那条 `rm` 会半途失败（`Directory not empty`），只删掉 `SourcePackages/`，而
  `~/Library/Caches/org.swift.swiftpm/artifacts/` 里那个 44MB 的 WebRTC zip 还在。SwiftPM 见缓存命中
  就**跳过下载**去解压它以为已放好的那份——路径没了，它**不回退、只 `fatalError`**。表现是
  `There is no XCFramework found at …/artifacts/webrtc/WebRTC/WebRTC.xcframework`，**越清越好不了**。
  平时用 **⇧⌘K（Clean Build Folder）** 就够，它不动 `SourcePackages`。真要清就先退 Xcode、两个一起清
  （重下 44MB）：`osascript -e 'quit app "Xcode"'; sleep 3; rm -rf ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/org.swift.swiftpm/artifacts`。
  已经踩了就把缓存那个 zip **挪走（别删，网慢能还原）**再 `xcodebuild -resolvePackageDependencies`。
  `test.sh` 前 9 步全绿说明不了问题——**只有第 10 步碰 `WebRTC.xcframework`**。

- **Kit 的界面代码 macOS 上编不到**（全在 `#if canImport(UIKit)`），`swift test` 绿不算数；`test.sh` 第 10 步为 iOS 编 Demo 才是闸门。
  Controller 那些在 macOS 上也要编的文件**不能引用 `IMKitTheme`**（它是 UIKit-only）——时长常量放 `IMCallViewRules.swift`。
- **权限状态查询只决定要不要出说明卡**，判失败靠真探：Web 端在合成媒体源上撞过「查询说被拒、其实拿得到」。
- **`UIStackView` 没有固有尺寸**，三段式要把两头钉死高度（64 / 96），中间那段才被完全确定。为此错过三轮。
- **公开 API 必须 ObjC 友好**；`IMMediaAdapter` 刻意不是 `@objc` 协议。加了公开 API 就往 `IMObjCAPICheck.m` 补一行。
- **MVP 不覆盖锁屏来电**（PushKit + CallKit 属后续期）；每次交付都要明说。
- **iOS 切后台视频会被系统暂停**：现在由 controller 自动 mute 摄像头轨道，对端看到头像而不是黑屏；回前台不替用户打开他本来关着的摄像头。
- **`RTCPeerConnectionFactory` 全进程一份、永不销毁**，否则挂断即闪退；挂载登记表只在主线程上动；远端轨道要「认领」（`claimRemoteTracks`）。
- **图标一律 SF Symbols**（`IMKitIcon`）：emoji 在设备上会变成方框问号。
- **给 UILabel 插渐变子层是没用的**：CALayer 画完自身内容（= 文字）才画子层，`at: 0` 只在
  子层之间排序。要渐变底 + 文字就用 `IMAvatarDiscView`（容器画渐变、文字在它上面）。
- **下行 call 帧必须按 call_id 过滤**：通话中被第三方呼叫时，服务端发来的 `call.ended{busy}`
  带的是**新来那通**的 call_id，不过滤就会把正在进行的通话拆掉（真机 08:30:39）。
- **`IMPipView.setContent` 只摘还挂在自己身上的内容**：A/B 互换的顺序是「先钉全屏、再塞小窗」，
  无条件摘会把刚被全屏容器领养走的那一个摘下来，大窗当场空白。
- **格子恒为正方形、行列跟容器形状走**（`imGridDimensions(_:aspect:)`），五端同一个算法，改一边要改五边。
- **还在响铃的来电结束时不进 ended**；主叫那一侧要停一下说明原因（`imEndReasonText`，与 Web 逐字对齐）。
- **`JSONSerialization` 分不清 true 与 1**，本仓用 `CFBooleanGetTypeID` 判；**Swift 块注释可嵌套**，注释里别写 `/*`。
- **4401 重试上限 3**（五端同一个数）；**日志回传要给请求设超时**（已设 5 秒）。
- **画质是宿主策略**（`IMVideoProfile`），改档位要同步服务端 `bwe.go` 的 `bitrateHigh`；
  **宿主的选择要自己持久化**（Demo 存的是档位名），Engine 不替宿主记。
- **Demo 里任何一条 `guard … else { return }` 都要留下一句话**：真机上「按钮点了没反应」
  基本都是静默 return 或者提示落在了看不见的位置（整页最底下的 `errorLabel`）。

## 关联工程 / 常用命令

- **各端能力对照表：`../im-rtc-server/docs/CLIENT_PARITY.md`**（✅ 只写在那里，本文件不重复）。
- 五仓（本地同级 `/Users/liying/IOSProject/im-rtc/`）：server（协议契约，只读引用）· **ios**（本仓）· web · desktop · android。
- 首批宿主（下游）：`../../IMProgram`（Objective-C iOS App）。
- 常用命令：
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口（10 步，末步为 iOS 编 Demo）
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  SKIP_DEMO_BUILD=1 ./scripts/test.sh   # 跳过 xcodebuild（快，但验不到 Kit 的 UI）
  swift test --filter KitRulesTests     # 只跑本轮新加的纯逻辑用例
  cd ../im-rtc-server && ./scripts/dev.sh                                   # 起服务端
  RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests # 真服务端联调
  ```
