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
