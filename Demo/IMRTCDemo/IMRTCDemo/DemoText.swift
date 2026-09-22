import Foundation
import IMCallKit

/**
 取 Demo 页面自己的文案（登录、拨号、记录、设置那些）。
 语言跟 Kit 走同一个开关（`IMText.locale`），缺译回落中文；表与 SDK 的分开，Demo 文案不打进 SDK 包。
 */
func dt(_ key: String, _ params: [String: Any] = [:]) -> String {
    let table = IMText.locale == .en ? DemoMessages.en : DemoMessages.zhCN
    var out = table[key] ?? DemoMessages.zhCN[key] ?? key
    for (name, value) in params { out = out.replacingOccurrences(of: "{\(name)}", with: "\(value)") }
    return out
}
