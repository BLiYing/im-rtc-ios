import Foundation

/*
 帧字段的**声明式定义**。

 这套声明负责 §2.4 里必须**结合帧定义**才能判的两条：
 规则 3（字段类型恒定）与规则 6（枚举封闭且带兜底）。
 与帧无关的四条在 `Discipline`。

 与 Web 端不同的是，这里的键**直接用线路上的 snake_case 名**，
 解出来的也还是 `[String: IMJSON]`。理由是 Swift 没有条件类型，
 硬要生成一套 camelCase 的强类型结构就得逐帧手写 struct——
 那是「同一份协议写两遍」，迟早漂。强类型留给门面层按需要包。
 */

/// IMFieldKind 是一个字段的契约。
public indirect enum IMFieldKind: Sendable {
    case string(defaultValue: String = "")
    /// int 的越界处理**不能一刀切**：`timeout_sec` 越界钳到边界（§2.6），
    /// 而质量 `level` 越界折成 0 = unknown。给了 `outOfRange` 就折成它，否则钳边界。
    case int(defaultValue: Int64 = 0, min: Int64? = nil, max: Int64? = nil, outOfRange: Int64? = nil)
    case bool(defaultValue: Bool = false)
    /// 收到集合外的值折成 `fallback`——**禁止崩溃、禁止透传给 UI**。
    /// 这是「新增枚举值不算破坏兼容」（§10）成立的前提。
    case enumeration(values: [String], fallback: String, defaultValue: String? = nil)
    case stringArray
    case enumArray(values: [String], fallback: String)
    case objectArray(fields: IMFrameFields)
    case object(fields: IMFrameFields)
}

/// IMFrameFields 把线路字段名映射到契约。
public typealias IMFrameFields = [String: IMFieldKind]

enum FieldCodec {
    /// decode 把线路上的 data 解成**补齐默认值**的 data。
    ///
    /// 「可选字段用省略表达，接收方按默认值填」（§2.4 规则 2）就落在这里：
    /// 字段缺席 → 取默认值；出现了 → 校验类型、归一化枚举、钳制数值。
    /// **未知字段直接忽略**（§10 的前向兼容要求）。
    static func decode(_ fields: IMFrameFields,
                       _ raw: [String: IMJSON],
                       path: String = "data") throws -> [String: IMJSON] {
        var out: [String: IMJSON] = [:]
        out.reserveCapacity(fields.count)
        for (wire, kind) in fields {
            out[wire] = try decodeField(kind, raw[wire], path: "\(path).\(wire)")
        }
        return out
    }

    /// defaults 返回一帧的全默认值 data。
    ///
    /// **发送侧一定要从它起手**：直接发零值结构体会把 `auto_subscribe` 写成 false，
    /// 人进了房却收不到任何流——这是三端都踩过的「发送侧默认值陷阱」（§2.4）。
    static func defaults(_ fields: IMFrameFields) -> [String: IMJSON] {
        var out: [String: IMJSON] = [:]
        out.reserveCapacity(fields.count)
        for (wire, kind) in fields {
            out[wire] = defaultValue(of: kind)
        }
        return out
    }

    private static func decodeField(_ kind: IMFieldKind,
                                    _ value: IMJSON?,
                                    path: String) throws -> IMJSON {
        guard let value else { return defaultValue(of: kind) }

        switch kind {
        case .string:
            return .string(try expectString(value, path: path))

        case .bool:
            // 布尔必须是真布尔：0/1/"true" 一律拒（§2.4「禁止用 0/1 代替」）。
            guard let flag = value.boolValue else {
                throw IMRTCError(.badParams, "\(path) 必须是布尔，得到 \(value.kindName)")
            }
            return .bool(flag)

        case let .int(_, min, max, outOfRange):
            guard let number = value.intValue else {
                throw IMRTCError(.badParams, "\(path) 必须是整数，得到 \(value.kindName)")
            }
            return .int(coerce(number, min: min, max: max, outOfRange: outOfRange))

        case let .enumeration(values, fallback, _):
            let text = try expectString(value, path: path)
            return .string(values.contains(text) ? text : fallback)

        case .stringArray:
            let items = try expectArray(value, path: path)
            return .array(try items.enumerated().map {
                .string(try expectString($1, path: "\(path)[\($0)]"))
            })

        case let .enumArray(values, fallback):
            let items = try expectArray(value, path: path)
            return .array(try items.enumerated().map { index, item in
                let text = try expectString(item, path: "\(path)[\(index)]")
                return .string(values.contains(text) ? text : fallback)
            })

        case let .objectArray(fields):
            let items = try expectArray(value, path: path)
            return .array(try items.enumerated().map { index, item in
                let elementPath = "\(path)[\(index)]"
                let object = try expectObject(item, path: elementPath)
                return .object(try decode(fields, object, path: elementPath))
            })

        case let .object(fields):
            let object = try expectObject(value, path: path)
            return .object(try decode(fields, object, path: path))
        }
    }

    /// defaultValue 给出字段的协议默认值。
    ///
    /// **数组的默认值恒为空数组，绝不是缺席**——协议里没有 null，
    /// 而「字段整个不见了」与「空数组」在接收端是两种代码分支。
    private static func defaultValue(of kind: IMFieldKind) -> IMJSON {
        switch kind {
        case let .string(defaultValue):
            return .string(defaultValue)
        case let .int(defaultValue, _, _, _):
            return .int(defaultValue)
        case let .bool(defaultValue):
            return .bool(defaultValue)
        case let .enumeration(_, fallback, defaultValue):
            return .string(defaultValue ?? fallback)
        case .stringArray, .enumArray, .objectArray:
            return .array([])
        case let .object(fields):
            return .object(defaults(fields))
        }
    }

    private static func coerce(_ value: Int64, min: Int64?, max: Int64?, outOfRange: Int64?) -> Int64 {
        let belowMin = min.map { value < $0 } ?? false
        let aboveMax = max.map { value > $0 } ?? false
        if !belowMin && !aboveMax { return value }
        if let outOfRange { return outOfRange }
        return belowMin ? (min ?? value) : (max ?? value)
    }

    private static func expectString(_ value: IMJSON, path: String) throws -> String {
        guard let text = value.stringValue else {
            throw IMRTCError(.badParams, "\(path) 必须是字符串，得到 \(value.kindName)")
        }
        return text
    }

    private static func expectArray(_ value: IMJSON, path: String) throws -> [IMJSON] {
        guard let items = value.arrayValue else {
            throw IMRTCError(.badParams, "\(path) 必须是数组，得到 \(value.kindName)")
        }
        return items
    }

    private static func expectObject(_ value: IMJSON, path: String) throws -> [String: IMJSON] {
        guard let object = value.objectValue else {
            throw IMRTCError(.badParams, "\(path) 必须是对象，得到 \(value.kindName)")
        }
        return object
    }
}
