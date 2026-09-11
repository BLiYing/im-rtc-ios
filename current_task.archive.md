# current_task 归档（只读）—— im-rtc-ios

> 2026-09-06 从 `current_task.md` 整体搬来。之后的历史看 `git log`。


## 2026-09-08 之前的「当前焦点」（review 修复那一刀挤下来的）

**握手被拒按「谁救得了」分流（2026-09-08）**，`./scripts/test.sh` 十步全绿。

补齐 Android `629352a` 那条五端契约。原先 `abortIfHandshakeRejected` 是
「不可重试 → 一律 `configRejected`」一个桶，**不可重试 ≠ 参数不对**，
合成一类等于给宿主一条错的建议。同轮修掉两条边界，三个缺陷都在同一个函数里：

| 缺陷 | 症状 | 改法 |
|---|---|---|
| 三类合成一桶 | 1101 明明换一枚票就能好，报成「去改配置」；1104 是被顶下线，该回登录页 | 1101 → `authExpired`、1104 → `takenOver`、其余 → `configRejected`。`IMKickedOutReason` 三个值本来就都在，只是没往那儿分 |
| local 组没挡 | `close()` 拿 `2005 invalid_state`（`retryable == false`）结掉在飞的握手，那是**宿主自己按的 logout**。只看 `retryable` 的话一次正常 logout 就报成「服务端拒了你的参数」——而静默续期正是先 logout 再换票，等于**续期把人踹回登录页** | `giveUpReason` 先 `guard !error.code.isLocal` |
| 未知码兜底反了 | 未知码在 `PendingRequests.settle` 里折成 `internalError`（1501，而它 `retryable == true`）→ **服务端每加一个新的终局码，客户端就多一种无限重连**。Android 漏 1106 那次就是这个形状 | 折算前把帧上的 `retryable` 留进 `IMRTCError.unknownCodeRetryable`（internal，不进公开 API），只在本端不认识那个码时才有值；判据变成 `unknownCodeRetryable ?? code.isRetryable` |

判据仍然是错误码表里的 `retryable`（四端共用的 `error_codes.json`），**没有另立名单**。

**合入时顺手拆了一刀**：rebase 到「本地收场」那一刀之上后，`SignalConnection.swift`
被两边加起来顶到 617 > 600（单独哪条分支都不超）。判据独立成
`Signaling/HandshakeGiveUp.swift` 的自由函数，文件回到 577——**与 Web 那边对称**
（`signaling/handshakeGiveUp.ts` 也是同一个纯函数）。

**新增 5 条用例，注入旧逻辑验过载重**：把 `giveUpReason` 换回「不可重试 → configRejected」，
三条立刻红（分流、未知终局码、logout 误判），第四条是护栏用例、本就不该被这个注入影响。

**没做**：本轮纯信令逻辑，**没上真机**；Web 侧同一条契约在 `im-rtc-web` 并行修。
`CLIENT_PARITY.md` 第 180 行那格与第 124 行的历史说明目前仍不准（写着「只有 Android 有」），
等 Web 也落地后一次改到位。

---

**上行协商闸门补上了（2026-09-08）**，`./scripts/test.sh` 十步全绿。**未真机复验。**

真机日志里的这一串：

```
event userVideoAvailable available=1 uid=alice
(sdp_offer_answer.cc:4305): Called in wrong state: stable (INVALID_STATE)
event error code=1501 name=internal
```

发布 audio 与 video 两条轨道 → 两次 `publish.ok` → 状态机连吐两帧 `room.offer{pub}`。
两个一起在飞：offer#2 的 `setLocalDescription` 覆盖掉 offer#1，answer#1 把状态推回 `stable`，
answer#2 再来就是上面那条。那一次自愈了，**但 Android 上同一个缺陷的后果是上行再也协商不出去**。

**「帧泵是 actor 所以串行」挡不住这一类**：`connection.request` 只等到 `room.offer.ok`，
answer 是随后一条独立的帧，offer→answer 整个回合不在串行范围内。

闸门落在 `IMFrameLoop`（不是媒体层）——只有那里能表达「这一帧先别发」。
与 Android 的 `IMNegotiationGate` **有两处刻意的不同**，别照抄：

| | Android | iOS |
|---|---|---|
| 锁 | 要（三个线程碰） | **不要**，`IMFrameLoop` 是 actor |
| `pendingIceRestart` | 要 | **不要**，那一位在 `IMWebRTCAdapter.pubICERestartPending` 上，排队不会弄丢 |

放闸的四个终局一个都不能少：answer 落地、answer 应用失败、发帧失败、通话结束；
**会话恢复时还要 `resetPubNegotiation()`** —— 换了连接旧 answer 永远不会回来，
不放就是 Android 上那个「上行永久沉默」。

**网络一直不回来时通话再也退不出去，已修（2026-09-08）**，`./scripts/test.sh` 十步全绿。
**未真机复验。**

真机现场：carol 断网后停在「正在重连」，**不接网就一直停在通话界面，挂断也无效**。
本地放弃的**唯一**入口是「重连上了但 `resumed == false`」时的 `synthesizeNetworkEnd`，
它要求先连回来；网络不回来那一刻永远不会到。而挂断只产出一帧发不出去的 `call.hangup`，
本地状态按 §4.2 铁律 1 一动不动，所以点了没反应。**四端同形**，Android 已同步修。

改法：`IMSignalConnection` 起一条倒计时，断开超过**上界**就抛 `onSessionUnrecoverable`，
状态机走与 `resumed == false` 完全相同的那段（房间归零 + 本地合成 `ended{network}`）。
协议 §1.4 补了对应条款（不是线路改动，没有新字段）。

**上界怎么来的（不能拍脑袋取 30 秒）**：服务端那 30 秒不是从我们断开算起，
是从**它自己察觉**算起，而它要连续 3 个心跳周期收不到东西才察觉（§1.3）。
最晚 = `断开 + 3×ping + 30s`，默认心跳 15 秒即 75 秒，再加 5 秒余量。
**取短了会杀掉一通还能恢复的电话** —— 真机 11:37 那次断开 14 秒后重连成功、通话照常继续。

**顺带修掉一件让排查瞎掉的事**：`IMRTCLog` 原先「装了 sink 就 return」，
Demo 登录后装的是回传服务端的 `RemoteLogSink`，于是 Xcode 控制台再也没有 Engine 日志 ——
而那天要查的故障**本身就是网络断了**，唯一的出口跟着一起没了（iOS 侧日志停在 11:45:16，
之后两分钟的现场一个字都没留下）。改成 fan-out，与 Android 的 `DemoLogSink` 一致。
**这一条没有单测**：控制台那一路在单测里观测不到，硬造一个只会得到一条抓不住回归的假用例。

**没做**：「离线时按挂断也立即收场」这一半**按拍板延期**。

**SDK 层校验 device_id（2026-09-07）**。补齐 Android 那半个改动，和 Web 同一轮。


## 2026-09-09 之前的「当前焦点」

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

# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：只记当前状态，**就地覆盖、不追加**。历史见 `git log`。
> 工程规范见 [CONVENTIONS.md](CONVENTIONS.md)；方案与分期见 `im-rtc-server` 的
> `docs/design/RTC_CALL_DESIGN.md` §10；界面以草图 `docs/design/sketches/RTC_CALL_UX_SKETCH.html` §02~§05 为准。

## 当前焦点

**P3 前四刀已落地（2026-09-05）：协议层 + 三个状态机 + 信令连接 + **门面与回调表**。
向量全过，且已经真连上服务端跑通进房离房。**「自画 UI 的宿主」现在就能接了。**

服务端 P0~P4 与 Web P2 都已完成，本仓是当时四仓里最后开工的一个（Android 于 2026-09-05 进入范围，排在本仓之后）。

| 目录 | 内容 | 怎么验的 |
|---|---|---|
| `Protocol/` | 严格 JSON 值模型、编码硬规则、信封、45 个错误码、reason、40 个帧的字段声明与注册表 | envelope 26+9 条向量、错误码全表、reason 全表 |
| `StateMachine/` | 通话机（§5.1）、房间机（§5.3）、Engine 总状态 | `call_fsm` 16 条 + `room_fsm` 7 条向量 |
| `Signaling/` | WS 客户端、握手、心跳、按 req_id 配对、退避重连、4401 三次上限 | 13 条假连接时序用例 + **一条真服务端联调** |
| `Facade/` | `IMCallEngine` 门面、24 条回调的 delegate 表、block 接法、核心循环 | 13 条假连接 + 假媒体的接线用例 |
| `Media/` | `IMMediaAdapter` 协议（**只有接缝，没有实现**） | 由门面用例的假媒体驱动 |
| `Observability/` | `IMRTCLog` 与脱敏 | 日志纪律门禁（含自检） |

`Sources/IMCallKit/` 已经有**视图模型 + 布局算术 + 回调接线 + 界面**：

| | |
|---|---|
| `State/IMCallViewState` | 纯值语义的视图模型 + reducer + 红按钮四向分派 |
| `State/IMCallController` | 把 `IMCallEngineDelegate` 接成视图状态；界面动作也在这里 |
| `Layout/IMGrid` | 九宫格行列、层上界、时长格式化 |
| `UI/` | 主题、控制按钮、成员格子、通话页、来电横幅、悬浮球、网络条、**独立 window 层** |

**Kit 只消费公开回调表**：`IMCallController` 实现的就是 `IMCallEngineDelegate`，
与「宿主自画 UI」拿到的完全一致，没有一处私有通道。

Demo 已经接上 Kit——`kit.start()` **一行**就接管了通话界面（草图 §01 的用法 B）。
Demo 有草图 §02 的三个 tab：拨号（1v1 / 群呼选人 / 会议）、通话记录、设置。
通话记录**完全由 `callDidEnd` 拼出来**，走的是 block 接法（delegate 被 Kit 占着）。

**客户端日志回传已接上**：Demo 登录后装 `RemoteLogSink`，Engine 的每一个公开事件
都进日志，落在 `im-rtc-server/dev-logs/client-ios-<用户名>.log`；
`scripts/timeline.py` 把它与服务端、浏览器端合到一条时间轴。
线路格式对着真服务端 curl 验过（HTTP 200，timeline 能读）。

`Sources/IMCallEngineWebRTC/` 是媒体实现（iOS-only，接 `stasel/WebRTC` 152.0.0）：
两条 PeerConnection、候选缓冲、simulcast 三层、第一帧探针、画面挂载。
**编译验过、真机没验过**——出声出画要你在真机上跑一次。

**`./scripts/test.sh` 十步全绿**，47 个用例，**全程不需要模拟器**。
第十步是新加的「Demo 为 iOS 编译」：`generic/platform=iOS Simulator` 只编译不跑，
它验的是上面 `swift test`（跑在 macOS 上）验不到的两件事——Demo 还编不编得过、
以及**公开面对 ObjC 到底可不可用**。

真服务端联调（默认 XCTSkip，手动跑）：
```bash
cd ../im-rtc-server && ./scripts/dev.sh
RTC_LIVE_SERVER=http://127.0.0.1:8787 swift test --filter LiveServerTests
```
它验的是与 `rtc-cli -scenario room` 等价的流程：免密登录 → WS 握手 →
建会议房 → 换票 → 进房 → 离房。**第一次跑就抓到一个服务端 bug**：
主动 logout 发的 1000 被当成掉线，房里挂了半分钟幻影成员（已在 im-rtc-server 修）。

两个刻意的工程决定：
- **`IMCallEngine` 不依赖 libwebrtc**。它是 iOS-only 的预编译二进制包，
  一旦被 Engine 直接依赖，「跑一次单测」就变成「起模拟器 + 下载几百 MB」。
  媒体只以 `MediaAdapter` 协议出现，真实现放进随后的 iOS-only target。
  这与 Web 端「engine 必须能在无 DOM 的 Node 里构造」是同一条约束。
- **「协议里没有 null、没有浮点」编进了类型系统**：`IMJSON` 这个枚举里压根没有
  `.null` 与 `.double` 两个 case，解析阶段就挡掉。

**2026-09-05 真机联调修掉的（本仓这一侧）**：

| 症状 | 根因 |
|---|---|
| **九宫格里一格远端画面都没有**（协商全通、`firstVideoFrame` 照抛、日志全绿） | 挂载登记表**按 track_id 当 uid 用**，而 `attachView` 传的是真 uid，两把钥匙永远对不上。Web 端一直是对的（`viewRegistry.ts` 有 orphans + claim 两张表），iOS 这边缺了整个「认领」环节。现补 `IMMediaAdapter.claimRemoteTracks`，由核心循环每推进一步同步一次 |
| **挂断即闪退** | `RTCPeerConnectionFactory` 原先是「一通电话一个」的存储属性，通话结束时整个丢掉。Swift 释放存储属性的顺序**未定义**：工厂先于 `pub`/`sub` 被释放时，PC 析构落在一个已经没了的 libwebrtc 线程上。改成全进程共用一个、永不销毁（SSL 也一并挪过去）。另外 `close()` 里在**后台线程**动 `RTCMTLVideoView` 的 UIKit——登记表改成主线程独占 |
| **拨出时看不见自己，随手点一下静音又出来了** | 采集起来之后只 `apply(.setCamera(true))`，而视频通话的 `cameraOn` 本来就是 true，前后状态相等 → `didSet` 不发通知 → 没人去调 `attachLocalPreview`。点静音真的改了状态，顺带触发了一次重挂 |
| 界面显示「已静音」而对方照样听得见 | 发布是异步的，这期间点的静音/关摄像头都以 `cid.isEmpty` 为由静默跳过了，只改了界面。现在发布完成后把界面上的意图补应用一遍 |
| **一枚废票会无限重连**（服务端日志里全是 `token_invalid`，客户端一次 4401 都没看见） | `receive` 失败与 `didCloseWith` 是两条独立的路，谁先到没保证。原先失败时直接按 1001 收尾，而 1001 的语义是「服务端下线，立刻重连」。现在先读 `task.closeCode`，读不到就给代理回调留 150ms |
| 「呼叫名单里含自己」被就地拒掉后卡在「正在呼叫…」 | 只抛 error，界面不知道该退回哪儿。补抛 `onCallEnd{reason:error}` |

**新增：采集画质档位** `IMVideoProfile`（360p / 720p / 1080p，默认 720p），
`IMWebRTCAdapter(videoProfile:)`；simulcast 三层码率跟着档位走，单层发布也压上限。
Demo 的设置页里可选（换档位下一通电话生效）。**画质是宿主策略，不是服务端下发的**——
与换 token 同一条边界（协议 §1.5）。

**2026-09-05 第二轮复测修掉的（本仓这一侧）**：

1. **来电被对方取消 / 自己拒接之后，来电页当场变成通话页**（标题 + 九宫格 +
   本端预览，停一两秒才消失）。实测原话：「为何还弹出一个那个接通才有的界面」。
   两处一起改：**还在响铃的来电结束时直接回 idle，不进结束态**；
   结束态本身也不再复用通话页的骨架，只留居中那一句话
   （拨出没打通的一侧仍然停一下说明原因——那边人是需要知道为什么的）。
2. **九宫格格子被拉伸**。两个人时是 1 行 2 列，每格半个屏宽、整个屏高，
   竖屏上就是两条细长条。现在**格子恒为正方形**，且**行列跟着容器形状走**：
   同样两个人，竖屏上下摞、横屏左右排。规则见 `imGridDimensions`
   （Web 的 `gridDimensions` 是同一个算法，四端共用一份）。
3. 群通话里某人拒接 / 没接之后，**他的格子还挂着「（响铃中）」**——
   从主叫的角度看，对方拒接就跟什么都没发生一样。补订阅了
   `userDidReject` / `userDidNotRespond`。

**2026-09-05 第三轮复测**：**删掉「以语音接听」按钮**（拍板 §11-10 定稿）。
视频来电页改成给一个**摄像头开关**——关掉再接听就是同一件事，而且状态看得见、
还能再打开；两个「接听」并排放着，用户得先分辨哪个是哪个。
关着接听时 `publishFor` **连摄像头都不开**（不是「开了再静音」）：用户表示不出镜，
指示灯就不该亮。`acceptAudioOnly` / `audioOnlyAccept` 一并删掉。

**语音通话里不再给摄像头按钮**（拍板见设计文档 §11 第 10 条）。
协议上没有「转视频」这回事，原先那个按钮点了确实出镜、对方确实看得见，
而本端格子的显示条件写的是 `mediaType == "video"`——**自己不知道自己已经出镜了**。
判据是 `media_type` 而不是「本端摄像头开没开」：「以语音接听」的那通电话仍是 video，
按钮要留着（`imShowsCameraButton(for:)`）。

群呼选人名单补到 9 个人。
自己会被过滤掉，原先 8 个名字只剩 7 个可选，**永远凑不出真正的九宫格**
（自己 + 8 = 9 才是 3×3）。

## 下一步

**P3 第五刀 —— 媒体：代码已落地，等真机验收**

`IMWebRTCAdapter` 实现了 `IMMediaAdapter` 的全部方法。**能证明的只有「编得过」**——
音视频一律真机验收（模拟器无摄像头、麦克风受限）。第一次真机跑要看的四件事：

1. 本端预览出画面（`attachLocalView`）；
2. 与浏览器互打，两边都能听见、看见；
3. 静音/关摄像头对端能收到 `userAudioAvailable` / `userVideoAvailable`；
4. **九宫格里层上界真的降档**——服务端日志有「带宽估计调整下发层上界」。

**模拟器上已经跑通到「已连接」**（2026-09-05）：登录 → 握手 → 日志回传落到
`dev-logs/client-ios-alice.log` 并出现在 timeline 里。媒体仍未验（模拟器无摄像头）。

跑法：
- **模拟器**：直接跑，服务器默认 `http://127.0.0.1:8787` 就是对的（模拟器与 Mac 共用网络栈）。
- **真机**：服务器框留空，填 Mac 的局域网 IP——`./scripts/dev.sh` 启动时会打印那一行。
  手机要和 Mac 在同一个 Wi-Fi。填过一次就记住，下次不用再敲。

真机上必须有的两个 Info.plist 键（已配）：`NSAppTransportSecurity.NSAllowsLocalNetworking`
（iOS 默认禁明文 HTTP；127.0.0.1 不受管所以模拟器一直是好的，局域网 IP 受管）
与 `NSLocalNetworkUsageDescription`（iOS 14 起连局域网设备要授权，
**信令和 WebRTC 候选两条都会触发**）。少任一条的症状都是「连不上但不报错」。

**P3 第六刀 —— Kit 剩余界面 + Demo 三屏：已落地（2026-09-05）**
来电横幅（`bannerFirst`）、悬浮球（`floatingWindow`，可拖、吸边、点开还原）、
「以语音接听」、扬声器切换（新公开方法 `setSpeakerOn`，四处同步：协议/门面/实现/ObjC 检查）、
网络质量条。全部**只编译验过，真机没验过**。

**还没做的**：iOS Demo 的「自画 UI」模式（草图 §02-D 那个总开关）。用法 A 在
Web Demo 里已经完整示范，iOS 等回调表稳定后再补一份。

**P4 —— 九宫格的打磨**：格子布局现在是等分网格，草图 §05 还要主讲人放大、
双击切焦点。服务端的 simulcast 与带宽估计都已就绪。
**P4**：九宫格（草图 §05）。服务端的 simulcast 与带宽估计都已就绪，
Web 端的 uikit 可以直接对照抄结构（`packages/call-uikit-react/src/layout/grid.ts`）。

## 已知坑 / 限制

- **公开 API 必须 ObjC 友好**：首批宿主 IMProgram 是 Objective-C。`@objc public` + NSObject 子类 +
  `@objc enum : Int`，公开面不用泛型/关联值 enum/元组。见 CONVENTIONS §4。
- **MVP 不覆盖锁屏来电**：需要 PushKit + CallKit + VoIP 推送证书，属后续期。
  只覆盖 App 前台且信令在线时的来电——每次交付都要明说，不许含糊。
- **音视频一律真机验收**：模拟器无摄像头、麦克风受限。"编译通过"不等于"功能可用"。
- **libwebrtc 版本要锁死**：预编译包随 Chromium 里程碑更新，季度升级一次，
  API 变化由 `MediaAdapter` 隔离。
- **未签名装机 Keychain 不可用**（姊妹项目 IMProgram 的已知坑）：Demo 存 token 用
  `UserDefaults` 即可，别引 Keychain 依赖。
- **iOS 切后台视频会被系统暂停**（Background Audio 只保音频），对端应退回头像——
  这是平台规则不是 bug，UI 要正确表现。
- **Swift 的块注释是可嵌套的**：注释里出现 `/` 紧跟 `*`（比如写一个带通配符的路径）
  会开一层嵌套注释，把后面整个文件吞掉，报错只说「unterminated」。踩过两次。
- **`JSONSerialization` 分不清 true 与 1**：两者都是 `NSNumber`，
  且 `NSNumber(value: 1) is Bool` 为 **true**。用 `is Bool` 判类型的话，
  「bool 不能写成 0/1」这条协议规则在 Swift 端等于不存在。本仓用 `CFBooleanGetTypeID` 判。
- **4401 必须有重试上限**（`IMSignalConnection.maxAuthFailures = 3`，四端同一个数）：
  重连**带的是同一枚 token**，没有上限就是拿同一把坏钥匙永远敲同一扇门。
  Web 端实测过——服务端重启换了签名密钥，一个没关的标签页重试到第 19 次还在敲，
  日志里全是 `token_invalid`，把真正的问题淹掉了。到顶抛 `onKickedOut` 让宿主回登录页。
- **各端已知的两条真 bug，iOS 从第一天就带上了防线**：
  通话结束后房间必须回 idle（否则之后每一帧都发向已销毁的房间）；
  层上界要随订阅一起给到服务端（否则房间记 m、实际发 h）。

- **ObjC 的选择器要亲手编一遍才知道对不对**：`Demo/IMRTCDemo/IMRTCDemo/IMObjCAPICheck.m`
  就是干这个的（CONVENTIONS §4 的「编译即验证」），它已经抓到一个真问题——
  `setMuted(_:_:)` 两个参数都不带标签，生成的选择器是 `setMuted::completionHandler:`，
  ObjC 宿主得写 `[engine setMuted:cid :YES ...]` 那种带空标签的怪东西。
  **加了公开 API 就往那个文件里补一行调用。**
- **`IMMediaAdapter` 刻意不是 `@objc` 协议**：它的方法是 `async throws`，
  而且只被媒体 target 实现一次，没有让 ObjC 宿主自己实现的场景。
  所以带 media 参数的那个 `init` 不导出到 ObjC，ObjC 宿主用 `initWithUrl:deviceID:`
  那个纯信令形态的。
- **不给 Engine 传媒体适配器是正常用法**，不是降级：登录、振铃、成员进出、
  静音通知一个都不少，只有推流与画面挂载会以 `2005 invalid_state` 失败。
  **没有为它新造错误码**——错误码表是五仓共用的契约，加一个码等于改五个仓 + 改向量。

- **Kit 的界面代码 macOS 上编不到**：它们全在 `#if canImport(UIKit)` 里，
  `swift build` 会整个跳过——**全绿完全不代表那些文件是好的**。
  真正编它们的是 `test.sh` 第 10 步（Demo 依赖 IMCallKit，为 iOS 编一遍）。
  改 Kit 的 UI 之后光看 `swift test` 绿是不够的。
- **iOS 构建有一批 Sendable 警告**（`SignalConnection.swift` 的
  `Task {}` 闭包捕获 self），macOS 的 `swift build` 看不到。它们**在 Swift 6
  语言模式下会变成错误**，属已知欠账，要单独一刀处理（大概是把
  `IMSignalConnection` 改成 actor 或补 `@unchecked Sendable` 并说明理由）。

- **媒体那一层 macOS 上也编不到**：`IMCallEngineWebRTC` 整个包在
  `#if canImport(WebRTC) && canImport(UIKit)` 里。验它的同样是 `test.sh` 第 10 步
  （Demo 依赖它，为 iOS 编一遍）。已验证过这个闸门不是摆设：往里塞一行类型错误，
  iOS 构建会真的失败。
- **libwebrtc 的实际代价是 43 MB / 首次约 40 秒**（M152，量过的）。
  之后缓存在 `~/Library/Caches/org.swift.swiftpm`，增量构建 0.9 秒、
  `swift test` 12 秒不变。原先「几百 MB」的说法是高估。
- **音频会话要配 `.voiceChat` 模式**：不配的话没有回声消除，自己会听到自己，
  而那听起来像「对方设备有问题」，很容易查错方向。

- **横幅 / 悬浮球模式下 window 铺满全屏但只有那一小块吃触摸**（`IMPassthroughWindow`
  的 `hitTest`），其余点击穿透给宿主。不做这个的话一个 56pt 的小球把整个 App 都挡住。
- **Demo 的记录靠 `pendingPeer` 记主叫的对方**：`callBegin` 的载荷里没有 callee，
  主叫这边只有拨号那一刻知道对方是谁。这是宿主侧的记账，不是回调表缺字段——
  宿主拨号时本来就知道自己拨给了谁。

- **「编得过」离「跑得起来」很远**：模拟器上第一次跑连着崩了两次，两个都是
  编译期完全看不出来的——
  ① Xcode 把 storyboard 引用同时放在 **build setting** `INFOPLIST_KEY_UIMainStoryboardFile`
     里，删了 `Main.storyboard` 和 Info.plist 里的键还不够，那个 build setting 也要删，
     否则启动即崩 `Could not find a storyboard named 'Main'`；
  ② `RTCPeerConnection.delegate` 是 **weak**，`connection.delegate = IMPCDelegate(...)`
     之后对象当场被释放。**必须先留强引用再赋值**。
  以后动 Demo 的启动路径或媒体层，光看 `test.sh` 绿是不够的，要真的跑一次。

- **UIStackView 没有固有尺寸，`setContentHuggingPriority` 对它不起作用。**
  一条「A 顶 B、B 顶 C、C 贴底」的约束链里如果有两个未知高度，就是**欠定**的，
  UIKit 不报冲突、也不报错，只是把剩余空间随便给谁。通话页为此错了三轮：
  先是网格内部用 required 钉死高度、再是控制条吃光了下面三分之二、
  最后是标题区跑到屏幕正中。**结论：这类三段式布局要把两头钉死高度**，
  中间那段的高度才被完全确定。查它最快的办法是给三段各上一个半透明底色，
  一张截图就看出谁占了哪块——比读约束和加日志都快。
- **Kit 的 emoji 图标在设备上会变成方框问号**：emoji 要靠字体回退，
  `UILabel` + 系统字体这条路不保证命中。**图标一律用 SF Symbols**
  （矢量、跟字重、深浅色自适应，而且开/关两态有成对符号）。
- **日志回传要给请求设超时**：`URLRequest` 默认 60 秒，而 `flushing` 那个闩要等回调
  才放开——一个卡住的请求就能让后面**所有日志静默丢掉**，症状是日志文件停在
  某个时间点不动而应用还活着。已设 5 秒。

- **`RTCPeerConnectionFactory` 必须活得比它造出来的 PC 久**，所以它是全进程一份的
  `static let`（`IMPeerConnections.sharedFactory`）。做成实例属性会在通话结束时
  跟着 PC 一起被释放，而 Swift 释放存储属性的顺序未定义——工厂先走就是**挂断即闪退**，
  而且崩在 libwebrtc 内部，看不出跟自己哪一行有关。`RTCInitializeSSL` 同理（全局、无引用计数）。
- **挂载登记表只在主线程上动**（`IMVideoRegistry`）：里面存的是 `RTCMTLVideoView`
  （背后是 `CAMetalLayer`）。锁保护得了字典，保护不了 UIKit——
  在后台线程 `removeFromSuperview()` 一个正在渲染的 Metal 视图，进程是要挂的。
- **远端轨道要「认领」**：`didAdd rtpReceiver` 只带 track_id，归属写在信令帧里，
  **谁先到都可能**。少了 `claimRemoteTracks` 这一步就是「协商全通、首帧照抛、
  但一格画面都不出来」。改媒体层时别把这条丢了。
- **没有「以语音接听」按钮**，视频来电页上那个摄像头开关就是它（拍板 §11-10）。
  关着接听时 `publishFor` 连摄像头都不开——**不是「开了再静音」**，指示灯不该亮。
  `toggleCamera` 在没进房时只改界面：来电页上房间还不存在，publish 会被 R1 拒成 2005。
- **语音通话里没有摄像头按钮**（`imShowsCameraButton(for:)`，与 Web 的
  `showsCameraButton` 同一条判据）。想做「通话中转视频」得先加协议帧
  （`call.upgrade_request` / `upgrade_accept|reject`）= 改五仓，见设计文档 §11-10。
- **格子恒为正方形，行列跟容器形状走**（`imGridDimensions(_:aspect:)`）：
  让格子吃满整块区域（`fillEqually` 两层）的话，竖屏两个人就是两条细长条。
  这条规则四端共用一份，Web 的 `layout/grid.ts` 是同一个算法——**改一边要改两边**。
- **还在响铃的来电结束时不进 ended**：那一侧什么都还没做，结束画面没有意义，
  而 ended 会把通话页的骨架整个铺出来。主叫那一侧相反，必须停一下说明原因。
- **画质是宿主策略**：`IMVideoProfile` 由宿主给，宿主要「后台可控」就把它放进自己的
  配置接口。**改档位要同步服务端 `internal/sfu/bwe.go` 的 `bitrateHigh`**，
  两边对不上会让降层判断按一个错的数字做。

## 关联工程 / 常用命令

- **各端能力对照表：`../im-rtc-server/docs/CLIENT_PARITY.md`**（逐端逐特性状态的**单一真相源**，✅ 只写在那里，本文件不重复）。

- 五仓（本地同级 `/Users/liying/IOSProject/im-rtc/`）：
  [im-rtc-server](https://github.com/BLiYing/im-rtc-server)（**协议契约在这里，只读引用**）·
  **im-rtc-ios**（本仓）· [im-rtc-web](https://github.com/BLiYing/im-rtc-web) ·
  [im-rtc-desktop](https://github.com/BLiYing/im-rtc-desktop) ·
  [im-rtc-android](https://github.com/BLiYing/im-rtc-android)。
- 首批宿主（下游）：`../../IMProgram`（Objective-C iOS App，架构见其 `ARCHITECTURE.md`）。
- 常用命令（脚本随骨架落地）：
  ```bash
  ./scripts/install-hooks.sh       # 新 clone 跑一次
  ./scripts/test.sh                # 唯一测试入口：两道门禁 + 自检 + 向量可达 + 编译 + 单测
  BUILD_ONLY=1 ./scripts/test.sh   # 只编译
  swift test --filter CallFSMTests # 只跑某一份向量
  RTC_CONFORMANCE_DIR=/path ./scripts/test.sh   # 向量不在同级目录时
  ```


---

# 2026-09-08 搬入：上一轮（已完成）

## 上一轮

**握手被拒就一次放弃（同日，已提交 71c0fcd）**。原先的放弃逻辑只认关闭码 4401，
不认 `sys.hello` 应答里的错误码，于是 1004 走的是「无限退避重连」那条路。
现在按 `IMErrorCode.isRetryable` 分流，不可重试的一次就停并抛
`IMKickedOutReason.configRejected`；闩是 `state = .closed`。
五端契约，Web 同轮补齐，**桌面端仍缺**（它的 `onKickedOut` 没有原因参数，
补它是公开 API/ABI 变更）。状态见 `CLIENT_PARITY.md` v1.17。

---

## 2026-09-11 精简前全文（✅ 已完成项与冗长细节从 current_task.md 移出，原文照录）

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

**2026-09-11 夜：开摄像头「画面出来又刷新一下」——本端改成和 Android 同一套（关时换隐藏新画布、开后等首帧才揭示），iOS / Android 两边加诊断日志。直接在 main 改，未提交，等真机。**

上一刀 `e2e9749`（重开时换新画布）已提交。17:10 真机：本端仍「先黑一下再出画面」，Android 看 iOS 那格也「画面已出来又刷新一下」；iOS 档位降到 720p 没减轻。

| 现象 | 根因 | 改了什么 |
|---|---|---|
| 本端格子：开摄像头先黑一下 / 旧帧一下再出画面 | Kit 按 `cameraOn` **同步**揭示格子，而上一刀的 `resetForReopen` 走 `Task`→`setMuted`→主线程，晚一拍才换画布；`CAMetalLayer` 留住最后一帧（`renderFrame(nil)` 不清），关采集前还会溜过来黑帧 | `Sources/IMCallEngineWebRTC/IMVideoViews.swift` 的 `IMVideoRegistry`：**关的时候**就换一块隐藏的新画布、挂一个不接收的首帧探针（`swapCanvas` / `armGate`）；**开的时候** `awaitFirstFrame` 让探针开始接收，首帧到了 `firstFrameArrived` 才揭示。对应 Android 的 release+init + `onFirstFrameRendered` |
| Android 看 iOS：画面出来又刷新一下 | **根因在 Android 接收端，不在本仓**（19:17 真机）：Android Kit 按 `room.track_muted` 揭示，信令比新画面早 450–900ms，复用的渲染器上留着关之前的最后一帧 | Android 已改成等新帧真上屏再揭示（见 `../im-rtc-android/current_task.md`）。本仓顺手做的两件留着：`MAINTAIN_RESOLUTION`（`IMWebRTCAdapter+Support.swift` 的 `preferResolutionOverFramerate`，与 Android `IMUplinkPolicy` 一致）、`IMUplinkVideoStats.swift` 上行采样 |

公开回调没变。日志关键词：`本端画面首帧到达`（waitMs + 帧尺寸）、`上行视频采样`、`编码降级偏好=MAINTAIN_RESOLUTION`、`画面尺寸变化`（每个视图最多 6 行）。
统计值转字符串抽成 Engine 里的 `imStatsFields`（`Sources/IMCallEngine/Observability/IMStatsFields.swift`），macOS 能单测（`StatsFieldsTests`）。

**验证到哪**：`./scripts/test.sh` 全绿（10 步，声明 215 = 执行 214 + 跳过 1，Demo iOS 编译成功）。
WebRTC 那部分 macOS 编不进来，**只有第 10 步把关，没真机验**。

**simulcast 换包方案已验证完、暂缓**（2026-09-09 拍板），结论与 checksum 全在「已知坑」第一条，不用重查。

## 下一步

- **本仓的静默失败点清单**（P0×3 / P1×7 / P2×8，2026-09-09 扫描）见
  `../im-rtc-server/docs/ops/silent-failure/ios.md`，跨端结论与修复顺序见同目录的
  `SILENT_FAILURE_AUDIT.md`。**逐条状态只在那里维护，别抄回本文件。**
  未修的头两条：麦克风推流失败被 `try?` 吞掉（接通了但一个字都没发出去）、权限卡 continuation 可永久挂起。

### 真机验收

**本轮优先**：

1. **开摄像头刷新感**：本端 19:17 真机已不再刷新。剩 Android 看 iOS 那格，随 Android 那刀一起验（**报通话时间**）。
   **19:14 另记一笔、没修**：服务端判掉线后本端卡在 `connecting`，call/cancel 被拒 2005、红键点不掉，19:15 才本地收场——疑似本端没跟上服务端结束通话。
2. 更早没验的：九宫格正方形填满、横幅接听键是听筒、群视频来电页点开摄像头看得见自己。
3. **设置页**（2026-09-11 合入 `e50752d`）用户 2026-09-11 验过：「关于」4 行、三个开关杀进程重进后保持、关详细日志后只到 info。

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
- **通话中关摄像头停的是采集、不是轨道**（2026-09-11）：重开失败（设备被占 / 选不到格式）**只记日志**，按钮是开的、画面黑。
  Kit 每点一次开一个 `Task` 调 `setMuted`，没严格排队——快速连点时落地顺序理论上可能和点击顺序不一致（没复现过）。
  **`stopCapture()` 在 async 上下文里会解析到 async 重载**，要同步停就走 `IMWebRTCAdapter.halt`。
  **本端画布关着时是隐藏的、靠首帧揭示**（`IMVideoRegistry.firstFrameArrived`）：重开失败 → 格子一直是底色；
  快速连点理论上可能被一帧迟到的黑帧揭示（没复现过）。
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
- **SDK 版本号只改 `Sources/IMCallEngine/Facade/IMCallEngineVersion.swift` 一处**（2026-09-11 五端统一 1.0.0）：握手 `sdk`、`IMCallKitVersion`、
  Demo「关于」都读它，ObjC 走 `IMCallEngine.sdkVersion`；Demo 工程的 `MARKETING_VERSION` 不跟它联动。
  「关于」里「H.264 硬编优先」依据是 libwebrtc 默认编码器工厂的注册顺序，**iOS 实际协商到哪个没实测**——看服务端 `上行 Track 已接入 … codec=`。
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
