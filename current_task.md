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

**会话没了却不给收场信号 + 没连接时帧被静默丢弃（2026-09-08）**，`./scripts/test.sh`
十步全绿、186 条用例。分支 `fix/parity-room-left`（worktree `../wt-ios-parity`，
**叠在 `fix/code-review-0908` 之上**）。**未真机复验。**

这两条是 **Web 那轮 `/code-review high` 的跨端对账**查出来的，不是 iOS 自审出来的。

| # | 缺口 | 症状 | 改法 |
|---|---|---|---|
| 1 | `IMRoomMachine.resume(_:resumed: false)` 只清房间、**一个事件都不抛** | 有 call 的场合有 `onCallEnd(network)` 兜着，**会议压根没有 call**：房间悄悄回 idle，而界面还显示「会议中」、计时器还在走；更要命的是一个结束类回调都没抛 → `leaveCallbacks` 不命中 → `media.close()` 永不调用，**摄像头麦克风一直开着**，上一轮 PC 还被带进下一次进房 | `IMEngineMachine` 抽出 `dropLostSession`：有 call 抛 `onCallEnd`（唯一出口，不重复补），没 call 但在房里补一条 `onRoomLeft` |
| 2 | `IMFrameLoop.sendFrame` 的 `guard let connection else { return }` | 状态机已经迁移、帧却没发出去，既不回滚也不报错。`login()` 之前调一次 `call()` → 通话机永久停在 `.inviting`，`hangup()` 拒 2005、`cancel()` 的帧同样被丢，**再也回不到 idle**，下一通真电话也被 2005 挡住 | 改成一次失败：抛 `2007 not_logged_in` 并走 `rollback(frame.type)`（顺手把 catch 里那三段回滚抽成同一个 `rollback`，与 Android 的 `onRequestFailed` 逐条对齐） |

**第 1 条三端同源**：Web（`engineMachine.dropLostSession`）与 Android
（`IMEngineMachine.dropLostSession`）同日补的是同一段，断言也是同一组。
**第 2 条 Android 早就是对的**——`IMSignalConnection.request` 未连接时立刻回
`NOT_LOGGED_IN`，iOS 与 Web 是漏的那两个。

**新增用例 5 条**（`Tests/IMCallEngineTests/LostSessionTests.swift`）：会议两条收场路径、
有 call 时不重复抛、idle 时不凭空抛、`resumed=true` 一个字不变。

---

**code review 的三条收场缺口 + 两条资源账（2026-09-08）**，`./scripts/test.sh` 十步全绿、181 条用例。
分支 `fix/code-review-0908`（worktree `../wt-ios-review-fixes`）。**未真机复验。**

前三条是同一个形状：**某一帧被服务端拒了，而本端没有任何一条路把状态收回来**——
状态机停在中间态，界面收不起来，红按钮在那个状态下算出的动作又被本地拒成 2005。
日志里只剩一串一模一样的 2005，真正的原因淹在上一条 error 里。
**三条 Android 早就有，是 iOS 漏的**（`IMCallEngine.onRequestFailed` 是那边的对照）。

| # | 缺口 | 症状 | 改法 |
|---|---|---|---|
| 1 | `room.leave` 被拒（1203）无人接 | 房间永久停在 `leaving`：`leaveCallbacks` 一条不抛 → `media.close()` 永不调用（**摄像头麦克风一直开着**），再 leave 拒 2005、再 join 也拒——除非 logout 永远进不了房 | `IMFrameLoop` 补 `roomLeave → leave_failed`；`IMRoomMachine` 补 `leave_failed` 分支（归零 + `onRoomLeft`，与 `leave.ok` 同一个收场）；`IMEngineMachine` 把它路由到房间机 |
| 2 | 只有 `call.invite` 映射 `call_failed` | `call.accept` 被拒（主叫刚取消 → 1401/1405）时通话机永停 `accepting`：来电页收不起来，而红按钮那时算出的是 reject，`reduceAct("reject")` 要求 `ringing`——只换回又一个 2005，**除了杀进程出不去** | 抽出 `callFailFrames = {invite, accept, join}`，三帧一起接 |
| 3 | `resume` 无条件把 `reconnecting` 推成 `joined` | `disconnected` 会把 `joining` 也推进 `reconnecting`，而那次 `room.join` 还在飞、服务端从没受理过。恢复后本端以为在房里 → 每帧换回 1201/1203，重新 join 又因「不在 idle」拒 2005 | 房间上下文加 `didJoin`（只由 `room.join.ok` 置位），`resume` 据它分辨来路：真进过房才回 `joined`，否则**重发一次 `room.join`**（房号房票都还在手上，攒下的意图照旧留着） |

**第 3 条为什么不能靠 `join_failed` 兜住**：`rejectAll` 唤醒的是隔着两跳 actor 的
`IMFrameSender`，而 `disconnected` 走帧泵、`IMFrameLoop` 又是可重入 actor——
`disconnected` 完全可能先到，随后的 `join_failed` 因为 `guard state == .joining` 变成空操作。
**所以改成认账不认时序**，三端同一份（Android 同轮一起改）。

另外两条是资源账，症状是「越用越卡 / 越用越占」而不是任何一条报错：

- `IMVideoRegistry.attach` 对 `addSubview` 判重，却无条件 `track.add(view)`，`bind` 里还再加一次——
  而 `RTCVideoTrack.add` **不去重**。`render` 每次状态变化都无条件 `attachLocalPreview`，
  `onActiveSpeakers` 每 300ms 就让状态变一次：一通视频打几分钟，同一个 `RTCMTLVideoView`
  上挂了几百个重复 sink，每帧渲染几百遍；卸载只 `remove` 一次，多的**永远回收不掉**。
  → 加 `rendered` 集合，一对最多接一次；换轨道与卸载都划掉。
- `IMURLSessionWebSocket.finish()`（服务端关闭 / 连接失败走它）**从不 invalidate URLSession**，
  只有主动 `close()` 才做。而 URLSession 强引用 delegate 直到 invalidate——
  每次失败的重连尝试都漏一条 session + socket + 整条回调链，退避封顶 30 秒，
  锁屏一小时上百份，重连成功或 logout 都收不回来。→ 这条路也 `finishTasksAndInvalidate()`。

**向量没动**：`join_failed` / `leave_failed` 本来就不在 `room_fsm.json` 里（是本端的收场事件，
不是协议帧）；两条 reconnect 向量的初始态都是 `room: joined`，`didJoin` 不影响它们。
向量跑法里补了一句种子（初始就在房里的把 `didJoin` 一起置上）——**是种子不完整，不是实现变了**。

**新增 7 条用例**（`RequestFailureRecoveryTests.swift`）：leave_failed 的四条（回 idle、清账、
非 leaving 时是空操作、engine 层路由）、call_failed 的三条（accepting 收场、join_call 收场、
顺带清房间）。

## 下一步

- **真机验收本轮的每一条**（清单见交互稿 **v3.1 §09 的 22 条**）：权限说明卡与被拒降级、
  小窗互换 / 长按拖动 / 吸角、标题栏加人与选人半屏、占位格终局、控制条自动隐藏、切后台恢复、
  悬浮球视频缩略；**本轮新增的 6 条**（通话中来电只出提示、群里发起人挂断只是退出、
  退出后可被重新邀请、离线成员的格子不再一直转、两端关摄像头小窗仍在、小窗上的红键能直接结束）。
- 悬浮球拖到底部 = 挂断（交互稿 M2）**没做**，留给下一刀。
- 「只引 Engine 自画 UI」的 iOS Demo 示范仍未做。
- `IMCallOverlayViewController` 512 行已过预警线（600 上限）：下次动它先拆版式（audio / video / grid 各一个协作对象）。
- Swift 6 语言模式下的 Sendable 警告（`IMSignalConnection` 的 `Task {}` 捕获）仍是欠账。

## 已知坑 / 限制

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
