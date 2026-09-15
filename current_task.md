# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-11 精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-15（第三轮，含协调方复查后一处修正）：四端 API 命名对齐落地，只改本仓，未 commit；`./scripts/test.sh` 全绿（10 步，284 例=283 执行+1 skip）。**
背景：四端（Web/iOS/Android/桌面 C）核对完命名，按统一规格改；服务端 `/guide` 文档与 `CLIENT_PARITY.md` 由主会话改，本仓这轮**没碰 server 仓**。改动点：

1. **`IMCallEngineDelegate.callEngine(_:callDidEnd:reason:durationSec:endedBy:)` 的 `reason` 从 `String` 改成 `IMCallEndReason`**（`Sources/IMCallEngine/Facade/IMCallEngineDelegate.swift`）。`IMCallEndReason`（`Protocol/CallEndReason.swift`）补**显式原始值** 0~11（与桌面 C 同值），陌生线路值经 `IMCallEndReason.from(wire:)` 折 `.error`。转换发生在 `IMEventDispatcher.callDelegate`（`case .callEnd`），**`addEventObserver` 的 `IMCallEvent.payload["reason"]` 不变，仍是原始字符串**。Kit 侧 `IMCallController+Delegate.swift` 在这个边界转回 `reason.wireValue`（Kit 内部继续按字符串走 `imEndReasonText` 等，`join_denied` 伪原因不进枚举）。
2. **`activeSpeakersDidChange`/`networkQualityDidChange` 从 `[[String: Any]]` 改成强类型**：新增 `IMSpeaker`（`uid`/`volume`）与 `IMNetworkQuality`（`uid`/`level`），`@objc public final class : NSObject`，放在新文件 `Sources/IMCallEngine/Facade/IMMediaSnapshot.swift`（查过重名，无冲突）。转换同样在 `IMEventDispatcher`。
3. **新增 `IMCallEngine.destroy() async`**（`Sources/IMCallEngine/Facade/IMCallEngine+Lifecycle.swift`）：`logout()` + 撤全部 block 观察者（`IMEventDispatcher.removeAllObservers()`）+ 断 delegate；可重复调用。之后 `login`/`publishMicrophone`/`publishCamera`/`startLocalPreview`/`probeMicrophone`/`openMicrophone`/`openCamera` 继续抛 `invalid_state`（`requireMedia()`/`login()` 各加一道 `guardNotDestroyed()`）；其余 fire-and-forget 方法**不额外加判断**，靠 `logout()` 已置空连接后 `IMFrameLoop.sendFrame` 现成的「未登录」本地收场（`not_logged_in` + `onCallEnd`）与 `setMuted`/`updateToken` 本身「找不到目标就什么都不做」的既有语义，这条判断写进了 `IMCallEngine+Lifecycle.swift` 顶部注释。
4. **新增按类型媒体开关**（腾讯 TUICallEngine 同名，`Sources/IMCallEngine/Facade/IMCallEngine+MediaSwitches.swift`）：`openMicrophone()`/`closeMicrophone()`/`openCamera()`/`closeCamera()`。**记账收在 `publish(_:simulcast:)` 这一个入口**（`IMCallEngine.swift`，按 `info.kind` 写 `publishedMicCID`/`publishedCameraCID`），不管发布是 `publishMicrophone`/`publishCamera` 直接调的还是 `openMicrophone`/`openCamera` 触发的，认的是同一份「引擎里这个类型实际发布了没有」——**协调方复查发现最初版本 open*/publishMicrophone 两边各记一份账，混用会重复发布，已修正**：先 `publishMicrophone` 再 `openMicrophone` 现在能识别出已发布，只 `setMuted`。通话结束/离房/房间关闭（`onCallEnd`/`onRoomLeft`/`onRoomClosed`，Engine init 里挂的内部 block observer）与 `logout()` 都会清零。`closeCamera` 核实过 `IMWebRTCAdapter.setMuted` 对已发布摄像头置 `muted=true` 会真的 `halt` 采集，注释已按实际行为写。`publishMicrophone`/`publishCamera`/`setMuted` 保留作高级接口，Kit 内部未换用（按规格）。`makeConnection` 顺带拆到新文件 `IMCallEngine+Connection.swift`（本轮把 `IMCallEngine.swift` 顶到 607 行触发体量门禁，拆完回落到 558 行）。

**没做 / 偏离规格**：均无偏离；ObjC 状态观察者块形式（上一轮已知限制）、真机联调仍是遗留项，见下。

## 下一步

**真机验收（未做，累积项）**：
1. 本轮四端命名对齐：新签名走一遍真机通话，确认 `callDidEnd`/`activeSpeakersDidChange`/`networkQualityDidChange` 三端（Kit/Demo ObjC/宿主自画）都收得到；`destroy()`、`openMicrophone`/`openCamera` 未在真机走过。
2. 上一轮 M1/M2：两台设备群呼带 `chatGroupID`、中途 `joinCall` 进房、选人页翻页/搜索/置灰；1409 两种文案没连过真服务端（邀请鉴权回调默认关）。
3. IMProgram / 容信真实接入是后续期（M3-M7），不在本轮范围。

**待办 / 已知限制**：
- `IMCallController.swift`（581 行）与 `IMCallOverlayViewController.swift`（596 行）逼近 600 行体量红线（`check-file-size.sh` 只是 WARN），下次改动前先规划再拆一次。
- `IMCallEngine.swift` 本轮加了 `isDestroyed`/`publishedMicCID`/`publishedCameraCID` 三个字段与 `guardNotDestroyed()`/`requireMedia()` 改动后到 594 行，也在往红线靠，`destroy()`/媒体开关的实现体已经拆到独立的 `+Lifecycle.swift`/`+MediaSwitches.swift`，下次别再往主文件塞。
- `IMInviteMemberProvider` 目前只有 Demo 一个实现验证过；`presentInvitePicker` 接管路径没有真实宿主跑过。
- **ObjC 状态观察者只有 delegate 形式，没配 block 形式**（`IMCallControllerStateObserver`，CONVENTIONS §4 的「两种都给」这次没做）：目前没有真实宿主提出这个需求，先不加。
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
