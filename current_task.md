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

**不拦的症状是「登录失败，没有下文」**：服务端回 1004，而它那句说得很清楚的
「device_id 只允许 `[A-Za-z0-9_-]`」到不了宿主手里——宿主看到的只有一个 `bad_params`。
安卓真机上踩过一次（`Build.MODEL` 是 `Pixel 2 XL`），查了一轮才定位到是机型名。

| 决定 | 为什么 |
|---|---|
| 校验放在 `login()` 里，**不在 init** | `init(url:deviceID:media:)` 是 `@objc` 且不抛错，加 `throws` 会打断每一个宿主。`login` 本来就 `async throws`，而且校验发生在开 socket 之前，早到足以起作用 |
| **只校验不改写** | `device_id` 要求跨重启稳定，SDK 悄悄改掉，宿主自己那套设备管理就跟服务端对不上账。清洗是宿主的事——而且别用「删掉非法字符」：`MI 8` 与 `MI8` 删完撞成同一个 id，两台设备会互相顶号 |
| 抛 `IMRTCError(.badParams)` | 和服务端拒绝时**同一个 1004**，宿主不用为「本地拦的」和「服务端拒的」写两遍分支 |
| `IMDeviceID.maxBytes` 公开 | 不给常量，宿主就把 64 抄进自己代码里，协议一改两边对不上 |

**测试里踩到的坑**：校验一失灵，`login` 会去等一条永不 open 的假 socket，于是那条
用例**不是变红而是挂死**——注入 bug 验证时 xctest 一声不吭地悬在那里。挂死是最糟的红：
CI 上分不清是断言失败还是环境卡了。现在用 `expectation` + `timeout: 2.0` 限住。

**并行**：ObjC 侧的 `NSError` 桥接（`IMRTCErrorDomain` / `IMRTCErrorNameKey` /
`IMRTCErrorInfo`）由另一轮同时在做，`DeviceIDTests` 里那两条 ObjC 视角的用例来自那一轮。

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
