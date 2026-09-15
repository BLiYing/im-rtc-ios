import Foundation

/**
 帧循环状态的**只读镜像**，任何线程都能同步读。

 只给 `IMCallEngine.forceEnd()` 用：那条路必须不经过帧循环 actor（理由见它的注释），
 可「此刻在哪一场、该发哪一帧」又得看状态。镜像在帧循环每推进一步时写一次，
 读到的最多比 actor 里晚一拍——晚的那一拍由 `IMFrameLoop.forceEnd(callID:roomID:)` 的比对兜住。
 */
final class IMContextMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var current = IMEngineContext()

    var value: IMEngineContext {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func set(_ ctx: IMEngineContext) {
        lock.lock(); current = ctx; lock.unlock()
    }
}
