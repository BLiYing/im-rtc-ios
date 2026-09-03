import Foundation

/*
 §2.4「七条编码硬规则」里能**脱离帧定义**判定的那几条。

 它们是「C++ 端能实现」这句话的落点：不放浮点、不放 null、数组同构、嵌套不超过两层，
 三端的解码器就都不需要处理 optional<optional<T>>、undefined/null 之分、异构数组这些坑。

 另外两条（字段类型恒定、枚举封闭带兜底）没法脱离帧定义判，由 `FrameSpec` 负责。

 浮点与 null 在 `IMJSON.parse` 里就被挡掉了（那两条编进了类型系统），
 所以这里只剩「同构数组」与「嵌套深度」两件事。
 */
enum Discipline {
    /// maxObjectDepth：data 本身算第 1 层，data 里再嵌一层对象算第 2 层，第 3 层非法。
    ///
    /// 例：`data.limits.max_callees` 合法；`data.a.b.c`（c 是对象）非法。
    /// **数组不增加深度**——`speakers:[{uid,volume}]` 里的元素对象仍是第 2 层。
    static let maxObjectDepth = 2

    /// check 检查 data 是否满足编码硬规则。
    static func check(_ data: [String: IMJSON]) throws {
        try walkObject(data, depth: 1, path: "data")
    }

    private static func walk(_ value: IMJSON, depth: Int, path: String) throws {
        switch value {
        case .string, .int, .bool:
            return
        case let .object(fields):
            try walkObject(fields, depth: depth + 1, path: path)
        case let .array(items):
            try walkArray(items, depth: depth, path: path)
        }
    }

    private static func walkObject(_ fields: [String: IMJSON], depth: Int, path: String) throws {
        guard depth <= maxObjectDepth else {
            throw IMRTCError(.badParams,
                             "\(path): 对象嵌套 \(depth) 层 > 上限 \(maxObjectDepth)；"
                                 + "要塞任意结构请用 user_data（opaque 字符串）")
        }
        // 键序不影响判定，但排一下能让报错稳定可复现。
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            try walk(value, depth: depth, path: "\(path).\(key)")
        }
    }

    /// walkArray 除了递归检查元素，还要确认数组是**同构**的（§2.4 规则 4）。
    ///
    /// 异构数组在 Swift/TS 里勉强能表达，在 C++ 里就得上 variant——所以协议层直接禁掉。
    private static func walkArray(_ items: [IMJSON], depth: Int, path: String) throws {
        var firstKind: String?
        for (index, item) in items.enumerated() {
            if let expected = firstKind {
                guard item.kindName == expected else {
                    throw IMRTCError(.badParams,
                                     "\(path): 数组必须同构，第 0 个是 \(expected)、"
                                         + "第 \(index) 个是 \(item.kindName)；要成对请用对象数组")
                }
            } else {
                firstKind = item.kindName
            }
            try walk(item, depth: depth, path: "\(path)[\(index)]")
        }
    }
}
