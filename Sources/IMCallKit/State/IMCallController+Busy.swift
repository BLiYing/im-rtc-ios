import Foundation
import IMCallEngine

/*
 「已经在一场通话 / 会议里，又想开始另一场」的守门（判据见 `imNewCallAllowed`）。

 **不改界面、不发帧**：被拒的这一次不该碰正在进行的那通电话的界面状态。
 提示走 `noticeHandler`（UI 层挂的 toast），没有 UI 时退回通话界面里的 hint。
 */
extension IMCallController {

    /// 已在一场里：弹提示并返回 true，调用方直接 return。**主线程调**。
    func blockIfBusy(_ message: String = imBusyNoticeText) -> Bool {
        guard !imNewCallAllowed(from: state.phase) else { return false }
        IMRTCLog.warn("[Kit] 已在通话中，忽略新的一场", ["phase": state.phase.rawValue])
        showNotice(message)
        return true
    }

    /// 弹一句提示。**主线程调**。
    func showNotice(_ message: String) {
        if let handler = noticeHandler {
            handler(message)
        } else {
            apply(.hint(message))
        }
    }
}
