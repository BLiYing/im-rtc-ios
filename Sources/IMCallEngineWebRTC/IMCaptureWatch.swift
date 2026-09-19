#if canImport(WebRTC) && canImport(UIKit)
import AVFoundation
import Foundation
import IMCallEngine
import WebRTC

/**
 采集会话看门狗：把 `AVCaptureSession` 的**静默失败**变成日志。

 # 为什么需要它

 `AVCaptureSession.startRunning()` **失败时不抛错、不返回值**，只发通知。
 libwebrtc 的 `RTCCameraVideoCapturer.startCapture` 也就跟着一起沉默——
 它的 completionHandler 照样以 `nil` 错误回调，于是上层看到的是「起成功了」，
 真机上的表现却是**本端预览恒为 0x0、上行 0 帧、没有任何报错**。

 2026-09-18 换 libwebrtc 预编译包之后就撞上了这个：日志里
 `摄像头采集已启动 inputs=1 outputs=1 session_running=false`——
 输入输出都接好了，会话就是不跑，而当时没有任何一处告诉我们**为什么**。

 # 它听两件事

 - `AVCaptureSessionWasInterrupted` / `...InterruptionEnded`：被别的进程抢走摄像头、
   多任务分屏、后台等。`reason` 是 `AVCaptureSession.InterruptionReason`。
 - `AVCaptureSessionRuntimeError`：会话起来之后崩掉。

 另外在起采集后延时复查一次 `isRunning`——`startRunning` 是异步生效的，
 紧接着读到 `false` 有可能只是还没轮到，**复查一次才能区分「慢」和「根本没起」**。
 */
final class IMCaptureWatch {

    /// lock 管 tokens / recheck：`watch` 在起采集的异步路径上调，`stop` 在 `close()` /
    /// `stopLocalPreview()` 调，两边不在同一个线程。
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var recheck: DispatchWorkItem?

    /// watch 开始盯一个采集会话。重复调用先停掉上一轮。
    func watch(_ session: AVCaptureSession) {
        stop()
        let center = NotificationCenter.default
        let added: [NSObjectProtocol] = [
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
            ) { note in
                let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                IMRTCLog.warn("采集会话被中断", [
                    "reason": raw.map(Self.reasonText) ?? "未知",
                    "raw": raw.map(String.init) ?? "-",
                ])
            },
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
            ) { _ in
                IMRTCLog.info("采集会话中断结束", [:])
            },
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
            ) { note in
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                IMRTCLog.warn("采集会话运行时出错", [
                    "code": err.map { String($0.code) } ?? "-",
                    "err": err?.localizedDescription ?? "未知",
                ])
            },
        ]
        // 延时复查：区分「startRunning 还在路上」和「根本没起来」。
        let item = DispatchWorkItem { [weak session] in
            guard let session else { return }
            IMRTCLog.info("采集会话复查", [
                "running": String(session.isRunning),
                "interrupted": String(session.isInterrupted),
            ])
        }
        lock.lock()
        tokens = added
        recheck = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    /// stop 摘掉观察者。**不停会话**——会话的生死归采集器管。
    ///
    /// 摄像头关掉时（`close()` / `stopLocalPreview()`）就要调，不能等下一次 `watch` 或 deinit：
    /// adapter 跨通话复用，纯语音的几通里这组观察者会一直挂着。
    func stop() {
        lock.lock()
        let item = recheck
        let old = tokens
        recheck = nil
        tokens = []
        lock.unlock()
        item?.cancel()
        let center = NotificationCenter.default
        for token in old { center.removeObserver(token) }
    }

    deinit { stop() }

    /// reasonText 把 `AVCaptureSession.InterruptionReason` 翻成能直接读的字。
    /// 只翻不判断——哪个原因该怎么办是调用方的事。
    private static func reasonText(_ raw: Int) -> String {
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: return "后台不给用摄像头"
        case .audioDeviceInUseByAnotherClient: return "麦克风被别的进程占着"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "分屏/多前台应用下不给用"
        case .videoDeviceNotAvailableDueToSystemPressure: return "系统压力（过热等）"
        case .videoDeviceInUseByAnotherClient: return "摄像头被别的进程占着"
        default: return "其他"
        }
    }
}
#endif
