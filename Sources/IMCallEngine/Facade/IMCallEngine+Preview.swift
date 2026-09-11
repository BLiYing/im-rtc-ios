import Foundation

/*
 本端预览的「停」。和 `startLocalPreview` 分文件放只是因为 IMCallEngine.swift 已经顶到 600 行。
 */
extension IMCallEngine {
    /**
     stopLocalPreview 停掉进房前起的本端预览，**连摄像头一起关**（设计文档 §7.5，v3.7）。

     来电页 / 拨出中关掉摄像头时调：原先只是不挂画面，采集一直开着，指示灯要等通话结束才灭。
     已经发布出去的摄像头不受影响——通话中关摄像头用 `setMuted`。

     **同步方法、不发任何帧**：它和随后的 `startLocalPreview` 的先后顺序就是调用顺序，
     做成 async 的话两个 Task 谁先跑说不准，「关了又开」可能被执行成「开了又关」。
     没有媒体适配器时静默忽略。
     */
    @objc public func stopLocalPreview() {
        media?.stopLocalPreview()
    }
}
