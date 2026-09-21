import Foundation

/// Kit 支持的界面语言。与 Web / Android 的 `locale` 同名同义；源语言是简体中文。
@objc public enum IMLocale: Int, Sendable {
    case zhCN = 0
    case en = 1

    var tag: String { self == .en ? "en" : "zh-CN" }

    /**
     跟随系统：按语言主码归类（`en-US`、`en-GB` 都归 `.en`；`zh-*` 归 `.zhCN`），不认识的回落中文。
     SDK **默认不跟系统**（默认 `.zhCN`），想跟随的宿主自己传 `IMLocale.system()`——
     默认变了会让宿主原本全中文的界面突然出英文。
     */
    public static func system(languages: [String] = Locale.preferredLanguages) -> IMLocale {
        for lang in languages {
            let primary = lang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if primary == "zh" { return .zhCN }
            if primary == "en" { return .en }
        }
        return .zhCN
    }
}

/**
 Kit 的文案入口。**是全局状态、不依赖 bundle**：状态类 / 格式化函数这些纯逻辑
 （macOS 上 `swift test` 直接跑）也要出人话，没法都走 `NSLocalizedString`。文案表由
 `scripts/gen-i18n.py` 从跨端的 `strings.json` 生成，禁止手抄。

 查找顺序：宿主覆盖 → 当前语言 → 中文 → key 本身（漏了一眼看得出）。
 已经画在屏幕上的提示不会回译，下一条才用新语言。
 */
public enum IMText {
    private static let lock = NSLock()
    private static var _locale: IMLocale = .zhCN
    private static var _overrides: [IMLocale: [String: String]] = [:]

    public static var locale: IMLocale {
        get { lock.lock(); defer { lock.unlock() }; return _locale }
        set { lock.lock(); defer { lock.unlock() }; _locale = newValue }
    }

    /// 宿主按语言覆盖个别文案（只写要改的 key）。
    public static var overrides: [IMLocale: [String: String]] {
        get { lock.lock(); defer { lock.unlock() }; return _overrides }
        set { lock.lock(); defer { lock.unlock() }; _overrides = newValue }
    }

    /// 取文案，`{name}` 占位符用 `params` 替换。
    public static func t(_ key: String, _ params: [String: Any] = [:]) -> String {
        lock.lock()
        let loc = _locale, custom = _overrides[_locale]?[key]
        lock.unlock()
        let table = loc == .en ? IMMessages.en : IMMessages.zhCN
        var out = custom ?? table[key] ?? IMMessages.zhCN[key] ?? key
        for (name, value) in params { out = out.replacingOccurrences(of: "{\(name)}", with: "\(value)") }
        return out
    }
}

/// `IMText.t` 的简写，Kit 内部用。
func imT(_ key: String, _ params: [String: Any] = [:]) -> String { IMText.t(key, params) }
