import Foundation

/*
 SDK 版本号，**本端唯一的来源**。握手帧的 `sdk` 字段（`IMConnectionOptions.sdk`）、
 Kit 的 `IMCallKitVersion`、Demo 设置页都从这里取，别再各写一份字面量——
 以前 Engine 门面、信令默认值、Kit、设置页四处各写一份版本字面量，改一处漏三处。

 **五端统一 1.0.0**（2026-09-11 定），协议不兼容才升大版本。
 握手帧里的 `sdk` 只用于日志与灰度，不驱动逻辑（RTC_PROTOCOL.md）。
 */
public let IMCallEngineVersion = "1.0.0"

extension IMCallEngine {
    /// SDK 版本号（= `IMCallEngineVersion`）。全局常量 ObjC 看不见，所以门面上再挂一个。
    @objc public static var sdkVersion: String { IMCallEngineVersion }
}
