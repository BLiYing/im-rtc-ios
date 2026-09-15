# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：就地覆盖、不追加。历史见 `git log` 与 [current_task.archive.md](current_task.archive.md)（末节「2026-09-11 精简前全文」）。
> 规范 [CONVENTIONS.md](CONVENTIONS.md) · 分期 server `docs/design/RTC_CALL_DESIGN.md` §10 ·
> 界面以设计稿 **v3.1** 为准：`../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html` / `RTC_CALL_UX_FLOWS.html`。
> ✅ 状态只写在 `../im-rtc-server/docs/CLIENT_PARITY.md`。

## 当前焦点

**2026-09-15：红键等不到结束事件时引擎也收场（`forceEnd`）+ 卡顿探针。已提交 `c7590f1`，两笔小账随后单独一笔；`./scripts/test.sh` 全绿（10 步，声明 240 = 执行 239 + 跳过 1）。10:03~10:13 与 Android alice、Web bob 真机联测通过（见下一步）；Android / Web 同形状已在各自仓落地。**
起因 09-13 14:53~14:58 frank（Android alice 群呼）：接听后 room.join 晚 28.6 秒才上线路，其间按红键，call.hangup 一帧没到服务端；
看门狗只收了界面，Engine 留在通话与房间里，其余三端一直看得见他。上一件（开摄像头刷新）已提交 `e1e6220`、三端验完。

- `IMCallEngine.forceEnd()`（`IMCallEngine+ForceEnd.swift`）：读 `IMContextMirror` 挑结束帧，`IMSignalConnection.fire` 直发、**不经帧循环**；
  本地收场走 `IMFrameLoop.forceEnd(callID:roomID:)`（先比对，防吞掉新来的一通）。帧怎么挑见纯函数 `IMEngineMachine.forceEnd`。
- Kit：看门狗到点调 `forceEnd`；按红键记 `[Kit] 按下红键`；Kit 已 idle 时 `callEnd` 不再弹结束画面（14:58:21 那 1.5 秒闪屏）。
- 防回魂：房间机 idle 下 `room.join.ok` 补发 `room.leave`、其余房间帧丢弃（服务端 join 只验房票不查成员）；房间 idle 时丢迟到的候选 / SDP。
- **join 为何卡 28 秒没定位**，只加诊断：`IMStallProbe`（`执行通道卡顿` / `执行通道卡顿恢复`，lane = main / concurrency_pool / frame_loop）、`请求往返慢`（≥ 2s）。
- `mediaEvents()` 拆到 `IMCallEngine+MediaEvents.swift`（主文件体量）。CLIENT_PARITY 加 `[^forceend]` 行（iOS 🟡，其余 ⬜）。

## 下一步

**真机验收（报通话时间）**：
1. ~~`forceEnd` 真机~~（09-15 已验）：正常挂断 10:03:28 按下 → 90ms 服务端受理、无 `强制收场`；故障注入拒掉 frank 的 hangup（10:05:12）→ 10:05:15 看门狗 `强制收场` 补发被受理，他端同刻看到离开。
2. 复现 09-13 **没复现**：10:12 通话中杀进程 → ⌘R → 恢复窗口过期后 10:12:50 再邀请 → 横幅接听 18ms 进房，无卡顿日志。再撞上就看 `执行通道卡顿` 的 lane 与 `请求往返慢`。
   **恢复窗口 30 秒内再邀请**，服务端当他还在通话里、不响铃——等「掉线超过恢复窗口」再邀。
3. ~~两笔小账~~（09-15 已修，三端同形状，真机未验）：本地收场时长改从本端抛 `onCallBegin` 那一刻算（`IMEngineContext.callStartedAtMS`，10:05 那次会从 124 秒变成约 6 秒）；
   invite.ok 回来之前按取消先挂起（`IMCallContext.cancelPending`），invite.ok 一到立刻补发 cancel，不再多一条 1401。
4. **19:14 那条**（服务端判掉线后本端卡 `connecting`、红键点不掉）：看门狗现在会 `forceEnd`，碰到再验。
4. 更早没验：九宫格正方形填满、横幅接听键是听筒、群视频来电页点开摄像头看得见自己。
5. 自动隐藏判据（已合入 main `f1055d3`，1v1 视频）：接通后控制条完整停 3 秒再淡出；挂断后结束画面标题栏不淡掉。
6. 跨端老批次（含本端「后置摄像头镜像」）清单见 `../im-rtc-server/current_task.md`「跨端待验」。

**待办**：
- `forceEnd` 三端对齐（Android 看门狗同样只收界面，Web 没有看门狗），形状见 CLIENT_PARITY `[^forceend]`；服务端 `room.join` 可考虑查通话成员作为第二道防线。
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
