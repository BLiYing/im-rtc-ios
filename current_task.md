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

**握手被拒就一次放弃（2026-09-07）**，`./scripts/test.sh` 10 步全绿（136 用例）。

补的是 Android 那条五端契约（`CLIENT_PARITY.md` v1.17）。原先 `handleClose` 的放弃逻辑
**只认关闭码 4401**，不认 `sys.hello` 应答里的错误码：`device_id` 不合规回的是 1004 错误帧，
于是握手抛错 → 连接断 → 普通关闭码 → 无限退避重连。真机上的样子是界面写着「登录失败」，
日志刷满同一条错误，真正的原因被埋在里面。

| 改动 | 为什么 |
|---|---|
| `SignalConnection.handshake` 的 `.failure` 分支先走 `abortIfHandshakeRejected` | 判据是 `IMErrorCode.isRetryable`（四端共用的一致性向量），不另立名单。超时 2004 / 断线 2003 都是可重试，照常重连 |
| 闩是 `state = .closed` | 重连定时器的处理块只在 `.reconnecting` 时动手，随后到来的 `handleClose` 也会因此把 `willReconnect` 判成 false |
| `IMKickedOutReason` 加 `case configRejected = 2` | `takenOver` 是回登录页、`authExpired` 是换票重来，都救不了 `device_id` 里的空格。`@objc` 枚举加 case 会打断宿主的穷尽 `switch`——那正是想要的 |

**测试里踩到一个空断言**：假服务端只回错误帧、不关连接，于是没有任何东西会去排下一次
重连，`box.count` 那条**永远为真、注入 bug 也不红**。补上 `closeFromServer` 才载重
（注入后立刻红：`("3") is not equal to ("2")`）。两个方向都验过红。

## 上一轮

**会话恢复之后重新协商上行（2026-09-07）**。真机断网抓到实证：`动作被状态机本地拒绝
op=restart_pub_ice room_state=reconnecting`——网一断信令也断，房间立刻 `reconnecting`，
而 PC 要约 30 秒才判 `failed`，那时动作被拒且**不进 bufferedOps**，永远丢失。
改法是把触发点搬到会话恢复之后（协议 §1.4 本来就写着，只是没实现），
`onConnected` 里 `resumed==true` → 无条件 `restartPubICE()` + dispatch。**没有真机复验。**

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
