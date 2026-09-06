# Current Task — im-rtc-ios（Swift Engine + Kit + Demo）

> **活快照**：只记当前状态，**就地覆盖、不追加**。历史见 `git log` 与
> [current_task.archive.md](current_task.archive.md)（只读归档，2026-09-06 搬入）。
> 工程规范见 [CONVENTIONS.md](CONVENTIONS.md)；方案与分期见 `im-rtc-server` 的
> `docs/design/RTC_CALL_DESIGN.md` §10；**界面以设计稿 v3 为准**：
> `../im-rtc-server/docs/design/sketches/RTC_CALL_UI_SPEC.html`（令牌 / 图标 / 组件红线）与
> `RTC_CALL_UX_FLOWS.html`（权限 / 小窗 / 互换 / 加人），两稿与 v2 草图冲突时以 v3 为准。

## 当前焦点

**Kit 按设计稿 v3 落地（2026-09-06）**，`./scripts/test.sh` 十步全绿：115 个 macOS 用例 +
Demo 为 iOS 编译通过（**Kit 的界面代码只有这一步编得到**）。**真机没验**——音视频一律真机验收，
下面每一条都是「编得过 + 纯逻辑有单测」，不是「跑起来是对的」。

| 块 | 落点 | 内容 |
|---|---|---|
| 令牌 | `UI/IMKitTheme.swift` | 与 Web `theme.ts` 逐条对应：danger #E5484D、accept #3DDC84、overlay #121418、语音页渐变、warning、九色头像板；`IMKitIcon` 是 SF Symbols 对照表，**Kit 里不再散写符号名，也不再有 emoji** |
| 头像 / 小窗算术 | `Layout/IMAvatar.swift` · `Layout/IMPipLayout.swift` | `imFNV1a32(uid) % 9`、四角吸附 / 避让 / 按容器形状选尺寸——纯函数，`KitRulesTests` 钉着与 Web 同一组向量 |
| 视图模型 | `State/IMCallViewState.swift` + `IMCallViewRules.swift` | 新增 `isSwapped` / `cameraBlocked` / `connection` / `canInvite` / 成员 `settled`；判据抽到 Rules：`imCanShowInvite`、`imPickLayout`、`imSettledText`、网络分档 |
| 权限门 | `State/IMPermissionGate.swift` + `IMCallController+Permissions.swift` | 三段式：说明卡 → 系统框 → 分支。**麦克风被拒整通取消、摄像头被拒降级为语音继续**；系统状态只决定要不要出说明卡，判失败一律靠真探 |
| 控制器 | `State/IMCallController.swift`（+Delegate / +Permissions 两个扩展） | 拨出 / 接听 / 进会议前过权限门；`inviteMore`、`setSwapped`；占位格终局 2s 后收；1202 / 1407 分支；**切后台自动 mute 摄像头、回前台恢复到用户原来的选择** |
| 通话页 | `UI/IMCallOverlayViewController.swift`（482 行，预警线上） | 三种版式 audio / video / grid；视频版式控制条 3s 自动隐藏 + 底部渐变；小窗单击互换、层上界跟着换；九宫格末位加号格（仅主叫） |
| 小窗 | `UI/IMPipView.swift` | 长按 350ms 进拖动态（放大 1.04 + 触觉 + 四角虚线框），松手吸最近的角，控制条显示时上移 88 |
| 其余 | `IMControlButton`（五态 / 三尺寸 / 按下缩放）· `IMVideoTileView`（渐变头像盘 / 绿色发言标签 / 静音角标 / 占位格）· `IMAudioStageView`（96 头像 + 呼吸光环）· `IMCallChromeViews`（头部 / 橙条 / 提示卡）· `IMInvitePickerViewController`（选人半屏）· `IMFloatingBubble`（视频形态 90×120 缩略画面）· `IMIncomingBanner`（38 圆 + 5s 升级全屏） |

Engine 新增两个公开方法（五端同名，设计文档 §7.5 已同步）：`inviteMore(_:)`、`probeMicrophone()`
（`IMMediaAdapter.probeMicrophone`：只探权限、拿到即放；`IMWebRTCAdapter` 走 `AVCaptureDevice.requestAccess`，
`startLocalPreview` 也先问摄像头权限、被拒映射成 2001）。

`IMCallKitConfig.inviteCandidates` 是「添加成员」的候选名单，**由宿主给**；Demo 传的是与选人页同一份九人名单。

**`/code-review`（Web 那一轮）连带修的三条**：`toggleCamera` 的 `try?` 吞掉发布失败
（现在按钮弹回去并标「无权限」）、加人被 1407 / 1202 拒时用 `revokeLastInvite()` 收回占位格、
提示 3s 自撤（`IMHintHoldSeconds`，不撤的话它在 `statusLine` 里永久顶掉计时器）。

## 下一步

- **真机验收本轮的每一条**（清单见交互稿 §09 的 16 条）：权限说明卡与被拒降级、小窗互换 / 长按拖动 / 吸角、
  加号格与选人半屏、占位格终局、控制条自动隐藏、切后台恢复、悬浮球视频缩略。
- 悬浮球拖到底部 = 挂断（交互稿 M2）**没做**，留给下一刀。
- 「只引 Engine 自画 UI」的 iOS Demo 示范仍未做。
- `IMCallOverlayViewController` 482 行已过预警线（600 上限）：下次动它先拆版式（audio / video / grid 各一个协作对象）。
- Swift 6 语言模式下的 Sendable 警告（`IMSignalConnection` 的 `Task {}` 捕获）仍是欠账。

## 已知坑 / 限制

- **Kit 的界面代码 macOS 上编不到**（全在 `#if canImport(UIKit)`），`swift test` 绿不算数；`test.sh` 第 10 步为 iOS 编 Demo 才是闸门。
  Controller 那些在 macOS 上也要编的文件**不能引用 `IMKitTheme`**（它是 UIKit-only）——时长常量放 `IMCallViewRules.swift`。
- **权限状态查询只决定要不要出说明卡**，判失败靠真探：Web 端在合成媒体源上撞过「查询说被拒、其实拿得到」。
- **`UIStackView` 没有固有尺寸**，三段式要把两头钉死高度（64 / 96），中间那段才被完全确定。为此错过三轮。
- **公开 API 必须 ObjC 友好**；`IMMediaAdapter` 刻意不是 `@objc` 协议。加了公开 API 就往 `IMObjCAPICheck.m` 补一行。
- **MVP 不覆盖锁屏来电**（PushKit + CallKit 属后续期）；每次交付都要明说。
- **iOS 切后台视频会被系统暂停**：现在由 controller 自动 mute 摄像头轨道，对端看到头像而不是黑屏；回前台不替用户打开他本来关着的摄像头。
- **`RTCPeerConnectionFactory` 全进程一份、永不销毁**，否则挂断即闪退；挂载登记表只在主线程上动；远端轨道要「认领」（`claimRemoteTracks`）。
- **图标一律 SF Symbols**（`IMKitIcon`）：emoji 在设备上会变成方框问号。
- **格子恒为正方形、行列跟容器形状走**（`imGridDimensions(_:aspect:)`），五端同一个算法，改一边要改五边。
- **还在响铃的来电结束时不进 ended**；主叫那一侧要停一下说明原因（`imEndReasonText`，与 Web 逐字对齐）。
- **`JSONSerialization` 分不清 true 与 1**，本仓用 `CFBooleanGetTypeID` 判；**Swift 块注释可嵌套**，注释里别写 `/*`。
- **4401 重试上限 3**（五端同一个数）；**日志回传要给请求设超时**（已设 5 秒）。
- **画质是宿主策略**（`IMVideoProfile`），改档位要同步服务端 `bwe.go` 的 `bitrateHigh`。

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
