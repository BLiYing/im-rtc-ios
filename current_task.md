# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-11 精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-15：宿主对接 M1 → M2 → M8（本仓部分）已实现，未提交；`./scripts/test.sh` 全绿（10 步，含新增单测），真机未验。**
依据 `../im-rtc-server/docs/design/HOST_INTEGRATION_DESIGN.md` §3.2-§3.4、`RTC_PROTOCOL.md` 对应章节；服务端与一致性向量由另一人同步在改，**本仓这轮没碰 server 仓**（含向量 / CLIENT_PARITY / guide）。

- **M1**（Engine）：`call.invite`/`call.incoming`/`call.connected` 补 `chat_group_id`（三帧都有）/`user_data`/`caller`（后两个只在 connected 新增）；`IMCallContext` 加 `callerUID`/`chatGroupID`/`userData`，`handleConnected` 三者「connected 为空就回落到 incoming / call() 记下的值」（`CallStateMachine+Recv.swift`）。新增 `IMCallOptions`（`Facade/IMCallOptions.swift`）、`call(_:mediaType:options:)` 与 `joinCall(_:)`（`Facade/IMCallEngine+HostIntegration.swift`，本地校验 chatGroupID ≤64 字节+无空白、userData ≤4096 字节，不合规与「名单里有自己」同一个出口）；`IMCallEngineDelegate` 的 `didReceiveCall`/`callDidBegin` **直接改签名**（不留旧 selector，设计 §3.3）；`IMErrorCode.inviteDenied = 1409`；`IMCallEngineWebRTC` 补 ObjC 工厂 `+[IMCallEngine webRTCEngineWithURL:deviceID:]`（`IMCallEngine+WebRTCFactory.swift`）。三条新一致性向量全绿，另加 `Tests/IMCallEngineTests/HostIntegrationTests.swift`（回落分支 / 本地校验 / 发到线路的字段，共 10 条用例）。
- **M2**（Kit）：新增 `IMInviteContext` / `IMInviteCandidate`（扩 `avatarURL`/`subtitle`/`selectable`/`unselectableReason`）/ `IMInviteMemberProvider`（`Sources/IMCallKit/State/IMInviteMemberProvider.swift`）；`IMCallKitConfig.inviteMemberProvider`（**强引用**）、`allowsManualUIDInput`（默认 false）；`IMInvitePickerViewController` 整体重写：300ms 搜索防抖、代际计数作废旧结果、滚到底翻页、加载中/失败(带重试)/超时(10s) 三态、已在通话中与 `selectable=false` 都置灰、最多选 `slotsLeft` 个；`IMCallOverlayViewController.onInvite` 先过 `canStartInvite()`（本端状态 + 宿主 `canInvite`），再问 `presentInvitePicker`（宿主接管选人页），否则弹 Kit 自带选人页；`IMCallKit.joinCall(_:)`（`IMCallController+Invite.swift`）；1409 两种文案——加人「对方暂时无法被邀请」（只 hint，不影响当前通话）、加入「无法加入该通话」（`didFailWithError` 记 `pendingJoinDenial`，随后 `callDidEnd(reason:"error")` 被改写成 Kit 本地伪原因 `"join_denied"`，从不上线路）。`Tests/IMCallKitTests/InviteMemberProviderTests.swift` 覆盖（8 条用例）。
- **M8（本仓部分）**：即上面的 `joinCall` 与 1409；服务端 `call.join` 由另一人实现，未联调。
- **Demo**：`DemoInviteProvider`（16 个真实账号在前 + 44 个假成员凑分页；搜索词 `fail` 模拟失败、`slow` 模拟超时不回调）；`DialerViewController` 群呼固定带 `chatGroupID: "demo-group"`，新增「加入这通电话」按 call_id 入口；`IMObjCAPICheck.m` 补 `webRTCEngineWithURL:deviceID:` / `IMCallOptions` / `joinCall:` 与两个改了签名的 delegate 方法的调用。

## 下一步

**真机验收（未做）**：
1. Demo 双端联调 M1/M2：两台设备群呼带 `chatGroupID`，被叫 `onCallReceived`/`onCallBegin` 拿到群号；中途在另一台设备上 `joinCall` 进房；选人页翻页、搜索 `fail`/`slow`、已在通话置灰。
2. 1409 的两种文案没连过真服务端——邀请鉴权回调是可选能力、默认关（HOST_INTEGRATION_DESIGN §3.5），等服务端那侧配上再对一遍错误路径。
3. IMProgram / 容信真实接入是后续期（M3-M7），不在本轮范围。

**待办 / 已知限制**：
- `IMCallController.swift`（571 行）与 `IMCallOverlayViewController.swift`（596 行）逼近 600 行体量红线（`check-file-size.sh` 只是 WARN），下次改动前先规划再拆一次。
- `IMInviteMemberProvider` 目前只有 Demo 一个实现验证过；`presentInvitePicker` 接管路径没有真实宿主跑过。
- 旧的 forceEnd / 卡顿探针 / 09-13 复现 / 「任何人都能加人」几条已验完并合入 main，移出本节，历史见 `git log` 与 archive。

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
