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

**上行 ICE 断了自己重连 + 补上「轨道后到要重报层上界」那个洞（2026-09-06 夜）**，
`./scripts/test.sh` 十步全绿。

| 改动 | 为什么 |
|---|---|
| **`pub` PC failed → `restartPubICE()` + 新 act `restart_pub_ice`**（`IMCallEngine.mediaEvents` / `RoomStateMachine` / `IMWebRTCAdapter`） | 那条 PC 的 offerer 是本端，**只能自己救**；`sub` 那条由服务端救（协议 §3.3 已补规则）。不救的后果：切网 / 进电梯 / 锁屏久了，人就**永久掉出这通通话**，对端格子从此是一块黑，而界面上一切正常、谁也不挂断——真机日志里抓到过两条 PC 从某一刻起五分钟一轮地失败、再没回到 connected。做成「置一位、下一个 offer 生效」而不是「立刻发帧」：发帧是 Engine 的事，媒体层不认识信令。`restart_pub_ice` **不进 `bufferableOps`** |
| **`report(_:layer:hasVideo:)`：轨道刚到就把去重表划掉重报一次** | `setRemoteLayer` 按 uid 找他当前的视频轨道再发帧，而**人先进来、轨道后到是常态**：`onUserEnter` 一到就摆格子并报层，那一次什么都没发出去，可去重表已经记下「报过了」——之后除非格数变化就再也不重发，服务端一直按默认的 `m` 下发。症状只是「画面卡」，一条报错都没有。（Android 走 `invalidateReportedLayer`、Web 把 `hasVideo` 放进 effect 依赖，同一条） |

**没做**：这两条都只有编译 + macOS 单测，**Kit 的界面代码在本仓只编得到**，
`report(...)` 是 VC 的私有方法，没法单测；ICE 重启更要真机断网才验得了。

## 上一轮

**合成画面：模拟器上终于能验视频了（2026-09-06 傍晚）**，`./scripts/test.sh` 十步全绿
（119 个 macOS 用例 + Demo 为 iOS 编译通过）。

**模拟器没有摄像头**（`RTCCameraVideoCapturer.captureDevices()` 恒为空），
于是模拟器上一切视频联调只能看头像——九宫格版式、画面通没通、层上界对不对，一条都验不了，
非插真机不可。新增 `IMSyntheticVideoCapturer`（`RTCVideoCapturer` 子类，定时把自己画的
`CVPixelBuffer` 推给 `RTCVideoSource`）：深色底 + 走动的秒针 + 用户名 + 墙上时钟，
**与 Web 的 `demo/src/syntheticMedia.ts` 同一套画面语言**——画面必须是活的，
静态图看不出「卡住了」和「通了」的区别。

| 落点 | 说明 |
|---|---|
| `Sources/IMCallEngineWebRTC/IMSyntheticVideoCapturer.swift`（新） | 走 `CVPixelBufferPool`（每帧新建在模拟器上就是稳定的一串卡顿）；帧率上限压到 15 |
| `IMWebRTCAdapter(videoProfile:syntheticVideo:label:)` | 多两个默认参数，`startLocalPreview` 分叉。**合成时不问摄像头权限**——模拟器上那个框毫无意义，真机上问了又不用 |
| `DemoSession.syntheticVideo` + 拨号页身份卡的开关 | 与画质档位同一条规矩：**换了要重登才生效**（适配器是登录时造的），所以登录后开关就锁上。**模拟器默认开、真机默认关** |

**「合成音视频」在 iOS 上实际是「合成视频 + 真麦克风」**：模拟器的麦克风是通的
（转发宿主 Mac 的），而 WebRTC 的 ObjC SDK **没有注入音频采样的公开口子**——
那要自己写 `AudioDeviceModule`（C++），而且没必要。

**没做**：模拟器实测。只有编译过；这一条按老规矩等明确通知再上设备。

**九宫格三端拉齐（2026-09-06）**，`./scripts/test.sh` 十步全绿（118 个 macOS 用例 + Demo 为 iOS 编译通过）。
起因是用户在三端并排看九宫格报了五条，落点分给四个仓；本仓这一份是最轻的——iOS 的容器与刷新本来就是对的。

| 改动 | 为什么 |
|---|---|
| **撤掉网格里的加号格**（`IMCallOverlayViewController.renderGrid`） | 加人入口只留标题栏右上角那一颗（`imCanShowInvite` 同一条判据）。同一个动作两个入口，而且加号格**占掉一个格位**——三个人的通话看起来像四个人，行列跟着多排一格。设计稿 `RTC_CALL_UI_SPEC` 差异 8 与 `UX_FLOWS §05` 已同步改（v3.3） |
| **3~4 格在竖屏容器恒为两列**（`imGridDimensions`） | 原判据「正方形格子最大」的翻转压在手机常见比例上（3 格 ≈0.662、4 格 ≈0.495），而舞台区算出来 **iPhone 15 Pro 是 0.682（2×2）、16 Pro Max 是 0.648（一竖条）**——同一通电话换台手机就是另一种版式，而差的那点边长（2%）根本看不出来。这条是产品决定不是尺寸最优解，所以写成一句明规则；横屏不受约束 |
| **远端格子截到 8**（`IMMaxRemoteTiles`） | **本端恒占一格**。原先 `imVisibleTiles` 按 9 截远端，会议房（服务端 `UnlimitedParticipants`，不设上限）进到第 10 个人时 iOS 会**悄悄丢掉**多出来的、Web 的 CSS grid 溢出、Android 越过 `rowCount`——同一个房间三端三种样子 |

**没做**：真机实测。这三条只有 macOS 单测 + Demo 编译过，**版式的事没在设备上看过一眼**。

**上一轮（2026-09-06 早）：按三端真机联调日志修根因**，`./scripts/test.sh` 十步全绿
（115 个 macOS 用例 + Demo 为 iOS 编译通过——**Kit 的界面代码只有这一步编得到**）。
**真机仍未验**：下面每一条都是「编得过 + 纯逻辑有单测」。

| 症状（用户报的） | 根因 | 落点 |
|---|---|---|
| 通话中第三个人打进来，**这边的通话被拆掉**（媒体面全关、通话页收起），而对面还显示着通话中 | 状态机**不看 call_id**：忙线那条 `call.ended` 的 call_id 是**新来那通**的 | `CallStateMachine+Recv.isForAnotherCall`；新增便利事件 `onCallMissed` |
| 群通话里被叫只看到两格，主叫却是四格 | `call.incoming` 的 `callee_ids` 一直在发，只是没人往上抛 | `handleIncoming` + `didReceiveCall(...calleeIDs:...)` |
| **居中头像没有首字母** | 渐变是 `label.layer.insertSublayer(gradient, at: 0)` 加的，而 CALayer 的绘制顺序是「背景 → 自身内容 → 子层」——`at: 0` 只在子层之间排序，渐变照样盖在字上 | 新的 `IMAvatarDiscView`（头像盘与格子共用） |
| 点小窗互换后**大窗一片空白** | 互换是「先钉全屏、再塞小窗」，而 `IMPipView.setContent` 无条件摘旧内容——那一刻它已经被全屏容器领养走了 | `setContent` 只摘还挂在自己身上的那个 |
| 两端都关摄像头时**小窗整个消失** | `imPickLayout` 会退回语音版式 | 接通后的 1v1 视频恒为视频版式（没画面是格子的事，不是版式的事） |
| 小窗入口两处、悬浮球没法挂断、呼叫页标题重复 | —— | 入口只留标题栏左上角；悬浮球加红色挂断（走 `controller.end()` 四向分派）；呼叫 / 来电页标题栏留空 |
| **1v1 视频没有真的全屏**（上下各一条黑边） | 全屏画面钉在 `stage` 里，而 stage 是「头部下方、控制条上方」那一块 | 新的 `videoFull` 挂在整个 view 最底下一层，头部与控制条浮在它上面 |
| 全屏画面上有一圈绿色描边 | 发言高亮 | **1v1 不做发言高亮**（绿描边 + 绿名牌），九宫格保留 |
| 悬浮球上的挂断点不中 | 22 的圆探出球体、又贴着屏幕边缘，球吸到右边时有一半在屏幕外 | 挪到**底部居中**、放大到 28、命中区再放宽 6 |

`imPickLayout` 的 `hasLocalVideo` 参数随之作废，已删。

**这一轮（2026-09-06 下午）修的是 Demo 侧的两条**（都是真机才看得见的）：

| 症状 | 根因 | 落点 |
|---|---|---|
| **点「登录」没有任何反应** | 两条路都会长成这样：① 地址或用户名为空时 `onLogin` 直接 `return`，界面一个字不变（**真机首次装机地址就是空的**）；② 请求要等（超时 10s）期间无反馈，而失败那句话落在整页最下面的 `errorLabel` 上，小屏上在折叠线以下 | 身份卡里加一行 `loginHint`：空值当场说清楚，发请求前写「登录中…」并禁用按钮，失败也写同一行 |
| 设置里选了 1080p，**杀掉 app 再进来又回到 720p** | `DemoSession.videoProfile` 只在内存里 | 按**档位名**存 UserDefaults（档位表会改参数，存名字才认得回来）；档位表收口到 Engine 的 `IMVideoProfile.presets`，与 Android 的 `PRESETS` 同名同序 |

`IMVideoProfile.presets` 是本轮唯一的公开 API 新增（`VideoProfileTests` 钉着顺序与唯一性）。

`/code-review` 在同一批改动里又抓出四条，都已修：**结束画面没把全屏格子摘掉**
（1v1 视频挂断后版式仍是 `.video`，结束原因那行字压在对方最后一帧上——Android 一直是摘的）、
**WS 登录失败却留在「已登录」态**（`engine` 在 `engine.login` 之前就赋了值，且自动重登标记也已写下，
现在失败走 `rollbackFailedLogin()`、标记改到成功之后才写）、
`IMCallWindow` 里那条「横幅 5s 升级全屏」的过期注释、`IMVideoTileView` 里空的 `layoutSubviews`。

**上一轮（2026-09-05）**：Kit 按设计稿 v3 落地——令牌、SF Symbols、头像 / 小窗算术、
权限门三段式、`IMPipView` 长按拖动、九宫格与选人半屏、切后台自动 mute 摄像头。
Engine 的 `inviteMore(_:)` / `probeMicrophone()` 也是那一轮加的。

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

- **层上界可能一次都没真发出去**（2026-09-06 发现，**未修**）：`reportLayer` 的去重表在
  `onUserEnter` 那一刻就记下了「报过 l」，而 `setRemoteLayer` 要按 uid 找**当前的**远端视频轨道
  才发得出帧——**人先进来、轨道后到**是常态，那一次是空转。之后除非格子数变了就不再重发，
  轨道自动订阅用的还是默认 `m`。Android 当天补了（轨道到了就划掉记账再报一次），
  Web 的 `VideoTile` `useEffect` 是同一个洞。

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
