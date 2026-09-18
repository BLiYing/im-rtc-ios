import Foundation

/**
 destroy —— 终态销毁（2026-09-15，四端命名对齐）。

 = `logout()`（关连接、关媒体、状态机归零、`openMicrophone`/`openCamera` 的记账清零）
 + 撤掉全部 block 观察者（`removeAllObservers`）+ 断开 delegate。

 # 之后还调方法会怎样

 这台 Engine 不会再变得可用——**没有「复活」这回事**，宿主要用就得重新创建一个实例。
 之后的调用按方法归类（server `docs/design/ACTION_RESULT_DESIGN.md` §3 与 R6，四端同一张表）：

 - **发起类与本地设备类**（`login` / `call` / `joinCall` / `accept` / `reject` / `cancel` / `hangup` /
   `inviteMore` / `joinRoom` / `leaveRoom` / `publishMicrophone` / `publishCamera` / `openMicrophone` /
   `openCamera` / `setMuted` / `probeMicrophone` / `startLocalPreview` / `switchCamera`）一律 **throw
   `2005 invalid_state`**——与平时失败同一个出口（`guardNotDestroyed()`）。
 - **提示类与清理类**（`setRemoteLayer` / `setSpeakerOn` / `updateToken` / `setAppForeground` / `notifyNetworkChanged` / `logout` / `destroy` / `forceEnd` /
   `closeMicrophone` / `closeCamera` / `stopLocalPreview` / `attachView` / `attachLocalView` /
   `addEventObserver` / `removeEventObserver`）**不 throw、不做事**：`attachView` / `attachLocalView`
   不再新建渲染视图，`delegate` 的赋值与 `addEventObserver` 被拦掉（事件本来也不会再有了）。

 逐个方法的归类由 `Tests/IMCallEngineTests/DestroyContractTests.swift` 钉住。

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
