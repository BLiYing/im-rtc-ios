import Foundation

/**
 destroy —— 终态销毁（2026-09-15，四端命名对齐）。

 = `logout()`（关连接、关媒体、状态机归零、`openMicrophone`/`openCamera` 的记账清零）
 + 撤掉全部 block 观察者（`removeAllObservers`）+ 断开 delegate。

 # 之后还调方法会怎样

 这台 Engine 不会再变得可用——**没有「复活」这回事**，宿主要用就得重新创建一个实例。
 但「不可用」具体长什么样，按本仓一贯的两种之一分类，不新造第三种行为：

 - **`async throws` 的方法**（`login` / `publishMicrophone` / `startLocalPreview` /
   `publishCamera` / `probeMicrophone` / `openMicrophone` / `openCamera`）继续抛
   `invalid_state`——跟「没有媒体适配器」共用同一条错误面，宿主不用多认一种失败。
   （`login` 单独判一次；其余几个都经 `requireMedia()`，那里加了同一道门。）
 - **fire-and-forget 的方法**（`call` / `accept` / `reject` / `cancel` / `hangup` /
   `inviteMore` / `joinRoom` / `leaveRoom` / `setMuted` / `setRemoteLayer` /
   `closeMicrophone` / `closeCamera` / `setSpeakerOn` / `switchCamera` / `attachView` /
   `attachLocalView` / `updateToken`）**不额外加判断**——`logout()` 已经把连接置空、
   状态机归零，这些方法在「未登录」时本来就会被现有机制当空操作收场：
   走 `loop.dispatch` 的那几个会被 `IMFrameLoop.sendFrame` 的「没有连接」分支
   本地收成 `2007 not_logged_in` + 一次 `onCallEnd`（见该文件的说明），
   `setMuted`/`closeMicrophone`/`closeCamera` 找不到已发布的 cid 就什么都不做，
   `updateToken` 在 `currentConnection` 为 nil 时本来就是空操作。**这些行为在
   `destroy()` 之前——单纯 `logout()` 之后再调用——就已经是这样**，destroy 只是
   在此之上确保状态"不可能再恢复"，不需要再单独判一次 `isDestroyed`。

 # 可重复调用

 `logout()` 对已经是 nil 的连接是安全的；`isDestroyed` 一旦置真不会翻回去，
 `removeAllObservers()` 清空一个空表也无所谓。多调几次效果跟调一次一样。
 */
extension IMCallEngine {
    @objc public func destroy() async {
        stateQueue.sync { isDestroyed = true }
        await logout()
        dispatcher.removeAllObservers()
        delegate = nil
    }
}
