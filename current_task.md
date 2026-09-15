# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-15（第三轮）：四端 API 命名对齐」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-16：群通话「添加成员」选人页（用户自测通过，已提交）。** 提交前按用户要求没跑全量；只单独 `xcodebuild` 编了 Demo（含 Kit UI）→ `BUILD SUCCEEDED`，单测没跑。
上一轮四端 API 命名对齐已提交 `c74d1be`，细节在 archive 末节。

- **布局**（09-15 夜）：`IMInvitePickerViewController` 从 `UITableViewController` 改成 `UIViewController` + 内嵌 `UITableView`：搜索框钉顶（safeArea +8，高 36）、
  邀请按钮钉底（safeArea −16，高 44）、列表夹在中间单独滚。`UISearchBar` 自带放大镜，iOS 不用另画。
- **列表全部列出**（用户 09-16 拍板，推翻设计稿「选人页不列发起人」）：不再按自己 / 发起人过滤，不再拼「（是你）」「（发起人）」；在通话里的人统一置灰「已在通话中」。
  `inCall` 原先只取 `state.participants`（**不含自己**），现补上 `engine.uid`。**离场的发起人**置灰「暂时无法邀请」（`isCallerWhoLeft`；服务端对发起人回 `bad_params`，拉不回来），文案是我定的。
- **行样式**：文件内新增私有 `IMInviteCandidateCell`——32pt `IMAvatarDiscView`（首字母 + 按 uid 渐变）+ 名字 / 副标题两行 + 系统勾选，行高 56。
  原先注册的是默认样式 `UITableViewCell`，`detailTextLabel` 为 nil，副标题从来没显示过（所以状态才拼在名字后面）。
  **`avatarURL` 仍然不取图**：Kit 里没有取图代码（`IMInviteCandidate` 注释写的「Kit 自己去取图」没兑现），只画首字母盘，与 Android 一致。

## 下一步

1. **键盘弹起时底部邀请按钮会不会被挡**没专门验过；「暂时无法邀请」（离场的发起人）文案待用户确认。
2. **真机验收（累积项，未做）**：API 命名对齐新签名（`callDidEnd` / `activeSpeakersDidChange` / `networkQualityDidChange` 在 Kit / Demo ObjC / 自画 UI 都收得到，`destroy()`、`openMicrophone` / `openCamera`）；
   M1/M2 两台设备群呼带 `chatGroupID`、中途 `joinCall` 进房、选人页翻页/搜索/置灰；1409 两种文案没连过真服务端。IMProgram / 容信真实接入是后续期（M3-M7）。

**待办 / 已知限制**：
- `IMCallController.swift`（581 行）、`IMCallOverlayViewController.swift`（596 行）、`IMCallEngine.swift`（594 行）都逼近 600 行红线，下次改动前先规划再拆；`destroy()` / 媒体开关已拆到 `+Lifecycle.swift` / `+MediaSwitches.swift`，别再往主文件塞。
- `IMInviteMemberProvider` 只有 Demo 一个实现验证过；`presentInvitePicker` 接管路径没有真实宿主跑过。
- **ObjC 状态观察者只有 delegate 形式，没配 block 形式**（`IMCallControllerStateObserver`，CONVENTIONS §4 的「两种都给」没做）：没有宿主提需求，先不加。
- **Kit 在视频通话中摄像头无权限 / 无设备（2001/2002）时没有专门的界面提示**——待补。

## 已知坑 / 限制

- **simulcast 没生效，换包暂缓**（2026-09-09 拍板，**别重查**）：`stasel/WebRTC 152.0.0` 没有 `RTCVideoEncoderFactorySimulcast`，三个 encoding 进得了 SDP 但只跑第一个（h），SFU 降层对 iOS 无效。
  选定候选 `webrtc-sdk/Specs 150.7871.01`（`RTC*` 原名、product 同名、0 处改名）；checksum、逐类兼容核对、换包三件事、M152→M150 与 H.264/VP8 取舍、兜底 M144，全在 archive 末节「已知坑」第一条。
  **`IMVideoProfile.simulcastLayers` 的 h,m,l 顺序只能随换包一起改**，单独改成 l 在前 = 当场发 1/4 分辨率。真换包时同步 `CLIENT_PARITY.md` §3 里程碑表。
- **2006 阈值「3」未校准、Kit 不接 2006**（iOS `default: break`）：见 server「已知坑」。
- **别单独 `rm -rf DerivedData`**：Xcode 开着时只删掉 `SourcePackages/`，SwiftPM 命中 `~/Library/Caches/org.swift.swiftpm/artifacts/` 里的 44MB WebRTC zip 就跳过下载然后 `fatalError`
  （`There is no XCFramework found …`），越清越坏。平时用 ⇧⌘K；真要清先退 Xcode 两个一起清：
  `osascript -e 'quit app "Xcode"'; sleep 3; rm -rf ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/org.swift.swiftpm/artifacts`。已踩了就把缓存 zip 挪走（别删）再 `xcodebuild -resolvePackageDependencies`。
- **Kit 界面代码 macOS 上编不到**（`#if canImport(UIKit)`）：`swift test` 绿不算数，只有 `test.sh` 第 10 步编 Demo、碰 `WebRTC.xcframework`。macOS 也要编的 Controller 文件不能引用 `IMKitTheme`（时长常量放 `IMCallViewRules.swift`）。
  **2026-09-15 踩了一次**：`swift build`/`swift test` 在这台机器上把整个 `#if canImport(UIKit)` 块当空文件——文件里就算有明显的未导入符号（缺一行 `import IMCallEngine`）也**不会报错**，`swift build --target IMCallKit` 照样绿；只有 `xcodebuild`（test.sh 第 10 步）才会真的编到这些文件。改 Kit 的 UI 文件后**必须跑一次完整 `test.sh`**，光看 `swift build`/`swift test` 的绿没有意义。
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
  swift test --filter KitRulesTests     # 只跑纯逻辑用例
  cd ../im-rtc-server && ./scripts/dev.sh                                   # 起服务端
  RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests # 真服务端联调
  ```
