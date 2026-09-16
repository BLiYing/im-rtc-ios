# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-16（第二、三轮）：来电铃声 + 回铃音 / 发布订阅被拒收场」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-16（第四轮，已提交（标题「构建: SDK 公网发布准备」，未推送），代码审查零问题）：Demo 拆成「源码档 / 公网包档」两档，为公网发布（`github.com/BLiYing/im-rtc-ios`，公开仓，tag `1.0.0` 待打）做准备。**
`./scripts/test.sh` 10 步全绿（300 例=299+1 skip，含 Demo `BUILD SUCCEEDED`）。

**背景**：仓库要公开，第三方用 SPM 填 `https://github.com/BLiYing/im-rtc-ios.git` + tag `1.0.0` 集成。原来 Demo 用 `XCLocalSwiftPackageReference relativePath "../.."` 引本地源码，跟第三方的集成写法不一致，没法验证「公网发布后到底能不能按文档接进去」。

**方案：Xcode 官方的「本地包覆盖同名远端包」机制，不用环境变量**（Dock 启动的 Xcode 读不到 shell 环境变量，且包解析有缓存，环境变量方案不可靠）：

1. **`Demo/IMRTCDemo/IMRTCDemo.xcodeproj` 的包依赖改成 `XCRemoteSwiftPackageReference`**，`repositoryURL = https://github.com/BLiYing/im-rtc-ios.git`，**暂时 `branch = main`**（tag 1.0.0 推上去、用户确认后再改成 `exactVersion 1.0.0`，见下面「下一步」）。三个 product 依赖（`IMCallEngine`/`IMCallKit`/`IMCallEngineWebRTC`）改挂到这个远端引用。**单独打开这个 `.xcodeproj` = 公网包档**——跟第三方拿到手的集成方式完全一样，要联网。
   手改 `project.pbxproj`：新对象 id `B22C4AC03049C665008A1C5F`（24 位十六进制，跟现有 id 核对过不冲突），`plutil -lint` 与 `xcodebuild -list -project` 都过。
2. **新建 `Demo/IMRTCDemo/IMRTCDemo.xcworkspace`**（`contents.xcworkspacedata` 两个 `FileRef`：`group:IMRTCDemo.xcodeproj` + `group:../..` 即本仓根目录）。本仓根目录名 `im-rtc-ios` 与远端 URL 末段同名，Xcode 自动用本地包**覆盖**掉那份远端依赖，不用改代码、不用加任何配置。**打开这个 workspace = 源码档**——日常开发默认用这个。
3. **`scripts/test.sh` 编 Demo 那步改成 `-workspace Demo/IMRTCDemo/IMRTCDemo.xcworkspace`**（原来是 `-project ...xcodeproj`），否则每次跑测试会悄悄联网走公网包档，且验的是 GitHub 上可能落后于本地未推送提交的旧代码。`CLAUDE.md` 新增一节「Demo 的两种打开方式」讲清楚两档怎么用；全仓 `grep -i xcodeproj` 核对过，没有其它脚本/文档提到打开 `.xcodeproj`。

**验证（真跑过，非纸面）**：
- `xcodebuild -resolvePackageDependencies -project Demo/IMRTCDemo/IMRTCDemo.xcodeproj -scheme IMRTCDemo`：`im-rtc-ios` 解析到 `https://github.com/BLiYing/im-rtc-ios.git @ main`，revision `df2cb7a`（GitHub 上的 main，落后本地未推送的 `502e745` 一个提交——预期内，没有去 push）。
- `xcodebuild -resolvePackageDependencies -workspace Demo/IMRTCDemo/IMRTCDemo.xcworkspace -scheme IMRTCDemo`：`im-rtc-ios` 解析到本地路径 `/Users/liying/IOSProject/im-rtc/im-rtc-ios`，没有联网 checkout。
- **负向验证**：在 `Sources/IMCallKit/KitEntry.swift` 的 import 后面插一行 `__TEMP_VERIFY_SOURCE_PROFILE_BUILD_ERROR__`，`xcodebuild -workspace ... build` 报错 `expressions are not allowed at the top level`（精确指到这一行）→ `BUILD FAILED`；撤销后 `git diff --stat` 确认 `KitEntry.swift` 不再出现在 diff 里，源码已恢复原样。
- `xcodebuild -workspace ... -destination 'generic/platform=iOS Simulator' build`：`BUILD SUCCEEDED`（源码档）。
- `xcodebuild -project ... -destination 'generic/platform=iOS Simulator' build`：**也 `BUILD SUCCEEDED`**（公网包档，用的是 GitHub 上落后一个提交的 main）——那个未推送的提交（`502e745`，发布/订阅被拒收场）没有动公开 API 面，所以对 Demo 编译没有影响，不是必然会过，纯属这次凑巧。
- `plutil -lint IMRTCDemo.xcodeproj/project.pbxproj` 与 `xcodebuild -list -project`/`-list -workspace` 均通过。

**Package.resolved 处理**：
- 根 `Package.resolved`（本仓自己 `swift build`/`swift test` 用）：不受影响，没改。
- `Demo/IMRTCDemo/IMRTCDemo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`：这是 **xcodeproj 单独打开（公网包档）** 用的那份，本来就进 git（只有 webrtc 一个 pin），现在 Xcode 重新解析后多了 `im-rtc-ios` 的远端 branch pin，**已更新并保留跟踪**——延续原有先例，且这本来就该是「公网包档」的真实解析快照。
- `Demo/IMRTCDemo/IMRTCDemo.xcworkspace/xcshareddata/swiftpm/Package.resolved`（**源码档**自己那份）：**目前还不存在**——`xcodebuild -resolvePackageDependencies`/`build` 命令行跑完不会落这个文件，只有真的在 Xcode.app 里打开这个 workspace 一次才会生成（GUI-only 行为，命令行验证不到，试了 `-resolvePackageDependencies` 和整个 `build` 两种都没落地，判断是 Xcode 的既有限制不是这次配置错）。写进了「下一步」。预期内容应该只有 `webrtc` 一个 pin（`im-rtc-ios` 被本地覆盖，不会出现在 pins 里，跟原 xcodeproj-only-local 时代的那份文件形态一致）。

## 下一步

0. **公网发布相关（本轮遗留）**：
   - tag `1.0.0` 推上 GitHub 后，把 `IMRTCDemo.xcodeproj` 里 `XCRemoteSwiftPackageReference` 的 `requirement` 从 `branch = main` 改成 `kind = exactVersion, version = 1.0.0`（等用户确认，本轮不做）。
   - 找机会用 Xcode.app 真的打开一次 `IMRTCDemo.xcworkspace`，看它是否生成自己的 `xcshareddata/swiftpm/Package.resolved`；生成后按「只含 webrtc pin」的预期核对内容，确认无误后加入 git（沿用本仓其它 `Package.resolved` 都进 git 的先例）。
   - 本地未推送的 `502e745`（发布/订阅被拒收场）迟早要推；推之前如果又有新提交，公网包档解析到的 revision 还会再变，属正常现象，不用大惊小怪。
1. **§A 发布被拒收场：用故障注入上真端走一遍**（先 `FAULT_INJECTION=1 ./scripts/dev.sh`）：通话接通后 `curl -X POST $B/v1/dev/faults -d '{"action":"reject","uid":"<本端uid>","frame_type":"room.publish","code":1302}'`，再开一次麦 / 摄像头 → 本端收场、结束原因 error、对端收到挂断。过了把 CLIENT_PARITY 那一行 🟡 转 ✅。代码已提交，真机验收后续再做（2026-09-16 用户定）。
2. **累积未做的真机验收**（上一轮遗留，与本轮无关但仍待办）：API 命名对齐新签名（`callDidEnd`/`activeSpeakersDidChange`/`networkQualityDidChange`/`destroy()`/`openMicrophone`/`openCamera`）；M1/M2 两台设备群呼带 `chatGroupID`、中途 `joinCall` 进房、选人页翻页/搜索/置灰；`call.incoming.inviter` 与「离场发起人可被重新邀请」两条双端联调；1409 两种文案没连过真服务端。IMProgram / 容信真实接入是后续期（M3-M7）。

**待办 / 已知限制**：
- `IMWebRTCAdapter.swift`（594 行）、`IMCallController.swift`（597 行）、`IMCallOverlayViewController.swift`（596 行）、`IMCallEngine.swift`（558 行）、`SignalConnection.swift`（594 行）都逼近或已经很接近 600 行红线（`check-file-size.sh` 目前是 WARN，没超）——下次往这几个文件加东西之前先规划怎么拆。
- **这一轮没做振动**（来电时手机震动），需要时另开一轮引 AudioToolbox / CoreHaptics。
- 宿主自定义铃声（`incomingRingtone`/`ringbackTone`）目前只有代码路径，没有 Demo UI 演示，也没有真机验证过传自定义文件能正常播放。
- `IMInviteMemberProvider` 只有 Demo 一个实现验证过；`presentInvitePicker` 接管路径没有真实宿主跑过。
- **ObjC 状态观察者只有 delegate 形式，没配 block 形式**（`IMCallControllerStateObserver`，CONVENTIONS §4 的「两种都给」没做）：没有宿主提需求，先不加。
- **Kit 在视频通话中摄像头无权限 / 无设备（2001/2002）时没有专门的界面提示**——待补。

## 已知坑 / 限制

- **Demo 打开 `.xcodeproj` 和打开 `.xcworkspace` 是两个不同档**（2026-09-16 起，见上面「当前焦点」）：`.xcodeproj` 单独打开 = 公网包档（远端 `github.com/BLiYing/im-rtc-ios.git`），`.xcworkspace` = 源码档（本地包覆盖）。**改 `scripts/test.sh` 或任何新脚本时别手滑写成 `-project`**——那样会联网、且验的是 GitHub 上可能落后于本地的代码。`.xcworkspace` 自己的 `xcshareddata/swiftpm/Package.resolved` 命令行落不了地，只有 Xcode.app 真开一次才生成，别把它的缺席当成配置错误。
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
