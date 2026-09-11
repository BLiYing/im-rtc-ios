import Foundation

/**
 imStatsFields 从一条 WebRTC 统计（`RTCStatistics.values`）里挑出要打进日志的字段，统一成字符串。

 **缺席就不写，不补 0**：没编出过帧就没有 `frameWidth`——日志里写成 0 的话，
 「真是 0」和「压根没这一项」就分不出来了，而后者本身就是线索。

 放在 Engine 里而不是 WebRTC 那个 target：统计的取值类型不定（计数是整数，
 `targetBitrate` / `totalPacketSendDelay` 是浮点，`qualityLimitationReason` 是字符串），
 这段最容易写错，而 WebRTC 那个 target 在 macOS 的 `swift test` 里编不进来，放那里就没有单测。
 */
public func imStatsFields(_ values: [String: Any], keys: [String], prefix: String = "") -> [String: String] {
    var fields: [String: String] = [:]
    for key in keys {
        guard let value = values[key], let text = imStatsText(value) else { continue }
        fields[prefix + key] = text
    }
    return fields
}

/// imStatsText 把一个统计值写成字符串。浮点最多三位小数并去掉尾零——
/// `0.30000000000000004` 这种噪声不该占满一行日志。认不出的类型返回 nil。
func imStatsText(_ value: Any) -> String? {
    if let text = value as? String { return text }
    guard let number = value as? NSNumber else { return nil }
    guard CFNumberIsFloatType(number as CFNumber) else { return number.stringValue }
    var text = String(format: "%.3f", number.doubleValue)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}
