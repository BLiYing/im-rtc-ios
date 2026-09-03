import Foundation

/*
 协议里允许出现的 JSON 值——**注意这个枚举里没有 null，也没有浮点数**。

 那不是偷懒，是把 `RTC_PROTOCOL.md` §2.4 的编码硬规则**编进类型系统**：
 解析阶段就把 null 与小数挡在门外，后面所有代码就再也不需要处理
 「缺失还是显式为空」「这个 volume 会不会是 73.5」这类分支。
 C++ 端能不能实现这套协议，靠的就是这几条约束。

 Swift 这边还有一个具体的坑：`JSONSerialization` 把 `true` 与 `1` 都变成 `NSNumber`，
 用 `is Bool` 判不出来（`NSNumber(value: 1) is Bool` 是 true）。所以下面用
 `CFBooleanGetTypeID` 判——**这条不判就等于没有「bool 不能写成 int」这条规则**。
 */
public enum IMJSON: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case array([IMJSON])
    case object([String: IMJSON])
}

// MARK: - 取值

extension IMJSON {
    /// stringValue 取字符串；类型不符返回 nil（不做隐式转换）。
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// intValue 取整数。
    public var intValue: Int64? {
        if case let .int(value) = self { return value }
        return nil
    }

    /// boolValue 取布尔。**不接受 0/1**——协议里 bool 就是 bool。
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// arrayValue 取数组。
    public var arrayValue: [IMJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// objectValue 取对象。
    public var objectValue: [String: IMJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// kindName 是这个值的类型名，报错与同构数组判定要用。
    public var kindName: String {
        switch self {
        case .string: return "string"
        case .int: return "int"
        case .bool: return "bool"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - 解析

/// maxSafeInteger 是 JS 的 Number 安全区上界。
///
/// 超了 Web 端会**静默**丢精度——那种 bug 在四端联调里几乎不可能定位，
/// 所以在协议层就拦掉（协议 §2.4 规则 7）。
public let imMaxSafeInteger: Int64 = (1 << 53) - 1

extension IMJSON {
    /// parse 把一段 JSON 文本解析成严格值模型。
    ///
    /// 失败一律是协议错误：`null` 与结构性问题算 `badEnvelope`，
    /// 浮点数与超范围整数算 `badParams`（与 Go/TS 两端同口径，向量守着）。
    public static func parse(_ data: Data) throws -> IMJSON {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw IMRTCError(.badEnvelope, "JSON 解析失败: \(error.localizedDescription)")
        }
        return try convert(raw, path: "$")
    }

    /// parse 的字符串重载。
    public static func parse(_ text: String) throws -> IMJSON {
        guard let data = text.data(using: .utf8) else {
            throw IMRTCError(.badEnvelope, "帧不是合法的 UTF-8")
        }
        return try parse(data)
    }

    private static func convert(_ raw: Any, path: String) throws -> IMJSON {
        if raw is NSNull {
            // §2.4 规则 2：协议里任何位置都不许出现 null。
            // 可选字段的表达方式是**省略**，接收方按文档默认值填——
            // 这条是为了 C++ 不必区分「缺失」与「显式为空」。
            throw IMRTCError(.badEnvelope, "\(path): 出现 null；可选字段请省略，不要写 null")
        }
        if let value = raw as? String { return .string(value) }
        if let number = raw as? NSNumber { return try convertNumber(number, path: path) }
        if let list = raw as? [Any] {
            return .array(try list.enumerated().map { try convert($1, path: "\(path)[\($0)]") })
        }
        if let dict = raw as? [String: Any] {
            var out: [String: IMJSON] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict {
                out[key] = try convert(value, path: "\(path).\(key)")
            }
            return .object(out)
        }
        throw IMRTCError(.badEnvelope, "\(path): 不认识的 JSON 值")
    }

    /// convertNumber 落实规则 1（没有浮点数）与规则 7（整数不超过 2^53-1）。
    ///
    /// **判定按「值」而不是按字面量**：`1e3` 是整数 1000，合法；`15e-1` 不是，非法。
    /// 这条是写 TS 实现时发现的漂移——Go 原本按字面量判（见到 e 就拒），
    /// 于是「TS 发得出去、Go 收不下来」。现在三端同规则，向量里有两条守着。
    private static func convertNumber(_ number: NSNumber, path: String) throws -> IMJSON {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        let value = number.doubleValue
        guard value == value.rounded(.towardZero) else {
            throw IMRTCError(.badParams,
                             "\(path): 协议里没有浮点数，得到 \(number)；音量/质量/时长/码率一律用整数")
        }
        guard value <= Double(imMaxSafeInteger), value >= -Double(imMaxSafeInteger) else {
            throw IMRTCError(.badParams, "\(path): 整数 \(number) 超出 ±(2^53-1)，Web 端会静默丢精度")
        }
        return .int(number.int64Value)
    }
}

// MARK: - 序列化

extension IMJSON {
    /// foundationValue 转回 `JSONSerialization` 认识的形状。
    public var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .int(value): return NSNumber(value: value)
        case let .bool(value): return NSNumber(value: value)
        case let .array(items): return items.map { $0.foundationValue }
        case let .object(fields): return fields.mapValues { $0.foundationValue }
        }
    }

    /// encoded 序列化成 JSON 文本。
    ///
    /// **键按字典序输出**（`.sortedKeys`）：帧内容一样时字节也一样，
    /// 日志与测试里比对帧就不必先解析。
    public func encoded() throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: foundationValue,
                                              options: [.sortedKeys, .fragmentsAllowed])
        } catch {
            throw IMRTCError(.internalError, "帧序列化失败: \(error.localizedDescription)")
        }
    }
}
