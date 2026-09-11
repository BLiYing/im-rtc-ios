# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-11 精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-11 夜：开摄像头「画面出来又刷新一下」——本端改成和 Android 同一套（关时换隐藏新画布、开后等首帧才揭示），iOS / Android 两边加诊断日志。已提交 `e1e6220`，本端 19:17 真机不再刷新。**
上一刀 `e2e9749`（重开时换新画布）已提交。

- **本端格子先黑一下 / 露旧帧**：Kit 按 `cameraOn` 同步揭示，而 `resetForReopen` 走 `Task`→`setMuted`→主线程晚一拍；`CAMetalLayer` 留住最后一帧。
  改法在 `Sources/IMCallEngineWebRTC/IMVideoViews.swift` 的 `IMVideoRegistry`：**关时** `swapCanvas` 换隐藏新画布 + `armGate` 挂首帧探针；**开时** `awaitFirstFrame`，`firstFrameArrived` 才揭示（对应 Android release+init + `onFirstFrameRendered`）。
- **Android 看 iOS 刷新一下**：根因在 Android 接收端（19:17 真机，见 `../im-rtc-android/current_task.md`）。本仓顺手留下：`MAINTAIN_RESOLUTION`（`IMWebRTCAdapter+Support.swift` 的 `preferResolutionOverFramerate`）、上行采样 `IMUplinkVideoStats.swift`。
- 统计值转字符串抽成 `Sources/IMCallEngine/Observability/IMStatsFields.swift`（macOS 可测，`StatsFieldsTests`）。公开回调没变。
- 日志：`本端画面首帧到达`（waitMs + 帧尺寸）· `上行视频采样` · `编码降级偏好=MAINTAIN_RESOLUTION` · `画面尺寸变化`（每视图 ≤ 6 行）。
- `./scripts/test.sh` 全绿（10 步，声明 215 = 执行 214 + 跳过 1）。WebRTC 部分 macOS 编不进，**只有第 10 步把关，没真机验**。

## 下一步

**真机验收（报通话时间）**：
1. 开摄像头刷新感：本端 19:17、Android 看 iOS 20:04、Web 看 iOS 21:11 都验过不再刷新；iOS 看别人重开摄像头用户确认本来就正常，不用补。
2. **19:14 另记、没修**：服务端判掉线后本端卡在 `connecting`，call/cancel 被拒 2005、红键点不掉，19:15 才本地收场——疑似没跟上服务端结束通话。
3. 更早没验：九宫格正方形填满、横幅接听键是听筒、群视频来电页点开摄像头看得见自己。
4. 自动隐藏判据（已合入 main `f1055d3`，1v1 视频）：接通后控制条完整停 3 秒再淡出；挂断后结束画面标题栏不淡掉。
5. 跨端老批次（含本端「后置摄像头镜像」）清单见 `../im-rtc-server/current_task.md`「跨端待验」。

**待办**：
- 静默失败点清单（P0×3 / P1×7 / P2×8）：`../im-rtc-server/docs/ops/silent-failure/ios.md`，逐条状态只在那里。未修头两条：麦克风推流失败被 `try?` 吞掉（接通了一个字都没发出去）、权限卡 continuation 可永久挂起。
- `Vectors.swift` 找向量仍是「同级没有就往上逐级找」，会捡到上层旧克隆（web 已修同类问题）。
- `CLIENT_PARITY.md` 真机验完再改，验之前停 🟡。

## 已知坑 / 限制

- **simulcast 没生效，换包暂缓**（2026-09-09 拍板，**别重查**）：`stasel/WebRTC 152.0.0` 没有 `RTCVideoEncoderFactorySimulcast`，三个 encoding 进得了 SDP 但只跑第一个（h），SFU 降层对 iOS 无效。
  选定候选 `webrtc-sdk/Specs 150.7871.01`（`RTC*` 原名、product 同名、0 处改名）；checksum、逐类兼容核对、换包三件事、M152→M150 与 H.264/VP8 取舍、兜底 M144，全在 archive 末节「已知坑」第一条。
  **`IMVideoProfile.simulcastLayers` 的 h,m,l 顺序只能随换包一起改**，单独改成 l 在前 = 当场发 1/4 分辨率。真换包时同步 `CLIENT_PARITY.md` §3 里程碑表。
- **2006 阈值「3」未校准、Kit 不接 2006**（iOS `default: break`）：见 server「已知坑」。
- **别单独 `rm -rf DerivedData`**：Xcode 开着时只删掉 `SourcePackages/`，SwiftPM 命中 `~/Library/Caches/org.swift.swiftpm/artifacts/` 里的 44MB WebRTC zip 就跳过下载然后 `fatalError`
  （`There is no XCFramework found …`），越清越坏。平时用 ⇧⌘K；真要清先退 Xcode 两个一起清：
  `osascript -e 'quit app "Xcode"'; sleep 3; rm -rf ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/org.swift.swiftpm/artifacts`。已踩了就把缓存 zip 挪走（别删）再 `xcodebuild -resolvePackageDependencies`。
- **Kit 界面代码 macOS 上编不到**（`#if canImport(UIKit)`）：`swift test` 绿不算数，只有 `test.sh` 第 10 步编 Demo、碰 `WebRTC.xcframework`。macOS 也要编的 Controller 文件不能引用 `IMKitTheme`（时长常量放 `IMCallViewRules.swift`）。
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
  swift test --filter KitRulesTests     # 只跑纯逻辑用例
  cd ../im-rtc-server && ./scripts/dev.sh                                   # 起服务端
  RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests # 真服务端联调
  ```
