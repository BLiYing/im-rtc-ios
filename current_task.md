# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-17（SDK 1.0.0 公网发布后精简）：精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 · 发版 server `docs/ops/RELEASE.md` ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-17：SDK 1.0.0 已公网发布（SPM tag `1.0.0`，MIT），手上没有在做的改动**（main 已推、工作区干净）。
- Demo 两档：`IMRTCDemo.xcworkspace` = 源码档（日常用），单独开 `IMRTCDemo.xcodeproj` = 公网包档（锁 `exactVersion 1.0.0`，已验过）。
- 最近提交：§A 发布被拒收场 `502e745`（真机 ✅ 09-17）· 来电铃声 + 回铃音 `cbf8c55`（真机 ✅）· `call.incoming.inviter` `d80e09b` · API 命名对齐 `c74d1be` · ObjC 全可用 `d91227c` · 宿主对接 `ee51701`。
- 发布准备的细节（pbxproj 手改、负向验证、三份 `Package.resolved` 各怎么处理）在 archive 末节。

## 下一步

1. **累积的真机验收**：API 命名对齐的新签名（`callDidEnd` / `activeSpeakersDidChange` / `networkQualityDidChange` / `destroy()` / `openMicrophone` / `openCamera`）；
   M1/M2 两台设备群呼带 `chatGroupID`、中途 `joinCall`、选人页翻页 / 搜索 / 置灰；`inviter` 与「离场发起人可被重新邀请」双端联调；1409 两种文案连真服务端。
2. **下个版本（协议批次，server 下一步 0）**：`call.ringing` 发给在场全员，Kit 消费它建占位格、按裁决帧收掉。
3. **Kit 视频通话中摄像头无权限 / 无设备（2001/2002）没有界面提示**（Web / Android 有）；补完同步 server `/guide/kit#hints`。
4. **体量**：`IMWebRTCAdapter` 594、`IMCallController` 597、`IMCallOverlayViewController` 596、`SignalConnection` 594、`IMCallEngine` 558 行——往里加东西前先规划拆分。
5. 按需 / 后续期：来电振动；自定义铃声没有 Demo UI、没真机验过；`IMInviteMemberProvider` / `presentInvitePicker` 没真实宿主跑过；ObjC 状态观察者只有 delegate 没有 block；IMProgram / 容信真实接入（M3~M7）。

## 已知坑 / 限制

- **Demo 开 `.xcodeproj` 与开 `.xcworkspace` 是两个档**：脚本一律 `-workspace`，写成 `-project` 会联网、验的是 GitHub 上的旧代码。workspace 自己的 `Package.resolved` 不落地（Xcode.app 里开过也没有），别当配置错误去追。
- **音频会话不在 `login()` 时配置**（09-16 改）：「该出声没出声」先查是不是漏了 `ensureAudioSessionConfigured()`（挂在 `acquireMicrophone()` / `setSpeakerOn(_:)`）。
- **simulcast 没生效，换包暂缓**（09-09 拍板，**别重查**）：`stasel/WebRTC 152.0.0` 没有 `RTCVideoEncoderFactorySimulcast`，三层只跑 h。候选 `webrtc-sdk/Specs 150.7871.01`，核对全文在 archive「已知坑」第一条。
  **`IMVideoProfile.simulcastLayers` 的 h,m,l 顺序只能随换包一起改**（单独改 = 当场发 1/4 分辨率）；换包时同步 `CLIENT_PARITY.md` §3。
- **2006 阈值「3」未校准、Kit 不接 2006**（`default: break`）：见 server「已知坑」。
- **别单独 `rm -rf DerivedData`**：Xcode 开着时 SwiftPM 命中缓存 zip 跳过下载然后 `fatalError`（`There is no XCFramework found`）。平时 ⇧⌘K；真要清先退 Xcode：
  `osascript -e 'quit app "Xcode"'; sleep 3; rm -rf ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/org.swift.swiftpm/artifacts`。
- **Kit 界面代码 macOS 上编不到**（`#if canImport(UIKit)`）：`swift test` 绿不算数，要跑完整 `test.sh`（第 10 步编 Demo）。macOS 也编的 Controller 文件不能引用 `IMKitTheme`；`IMCallController+Ringtone.swift` 全包在 `#if canImport(UIKit)`。
- **`join_denied` 不是协议 reason**：`IMCallController` 在 `joinCall` 被 1409 拒时本地改写的伪原因，只用于结束画面，别拿去和其他端对齐。
- **「人先进来、轨道后到」是常态**：摆格子时的动作（层上报、尺寸、订阅）要能在轨道到达时再做一遍，别让去重表吃掉（`report(_:layer:hasVideo:)`）。
- **通话中关摄像头停的是采集、不是轨道**：重开失败只记日志；`stopCapture()` 在 async 上下文解析到 async 重载，同步停走 `IMWebRTCAdapter.halt`；本端画布靠 `IMVideoRegistry.firstFrameArrived` 揭示。
- 切后台 controller 自动 mute 摄像头；回前台不替用户打开本来关着的摄像头。
- `RTCPeerConnectionFactory` 全进程一份、永不销毁；挂载登记表只在主线程动；远端轨道要 `claimRemoteTracks` 认领。
- 下行 call 帧必须按 call_id 过滤（第三方呼叫的 `call.ended{busy}` 带新来那通的 id）；还在响铃的来电结束不进 ended。
- `IMPipView.setContent` 只摘还挂在自己身上的内容；格子恒为正方形（`imGridDimensions(_:aspect:)`，五端同算法）。
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
