import Foundation
import XCTest

@testable import IMCallEngine

/*
 一致性向量的加载。

 向量文件在 `im-rtc-server/docs/conformance/`，**本仓只读引用、绝不拷贝一份过来**——
 一拷贝就会漏同步，而「四端跑同一份向量」正是这套东西唯一的价值。

 找不到目录时**直接失败**，不跳过。被静默跳过的一致性测试比没有测试更糟：
 它会让人以为协议对齐了。
 */
enum Vectors {
    static func directory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RTC_CONFORMANCE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // 相对包根目录找同级仓库。`swift test` 的工作目录就是包根。
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("im-rtc-server/docs/conformance", isDirectory: true)
    }

    /// load 读一个向量文件。
    static func load(_ name: String) throws -> [String: Any] {
        let url = try directory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("""
                找不到一致性向量 \(url.path)。
                把 im-rtc-server 克隆到本仓同级，或设 RTC_CONFORMANCE_DIR。
                **不要拷贝一份向量到本仓**——一拷贝就会漏同步。
                """)
            throw NSError(domain: "Vectors", code: 1)
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Vectors", code: 2)
        }
        return object
    }

    /// array 取一个数组字段，缺了就失败——向量结构变了要立刻知道。
    static func array(_ vector: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let items = vector[key] as? [[String: Any]] else {
            XCTFail("向量里缺少数组字段 \(key)")
            throw NSError(domain: "Vectors", code: 3)
        }
        return items
    }
}

/// expectSubset 做**子集比对**：向量写了哪些键就只比哪些键。
///
/// 全量比对会把「向量没提到的默认字段」也拉进断言，那样每加一个可选字段
/// 都要改一遍所有向量——协议就没法演进了。
func expectSubset(_ actual: IMJSON?, _ want: Any, path: String,
                  file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else {
        XCTFail("\(path) 应当存在", file: file, line: line)
        return
    }
    if let wantList = want as? [Any] {
        guard let items = actual.arrayValue else {
            XCTFail("\(path) 应当是数组，得到 \(actual.kindName)", file: file, line: line)
            return
        }
        XCTAssertEqual(items.count, wantList.count, "\(path) 长度", file: file, line: line)
        for (index, item) in wantList.enumerated() where index < items.count {
            expectSubset(items[index], item, path: "\(path)[\(index)]", file: file, line: line)
        }
        return
    }
    if let wantObject = want as? [String: Any] {
        guard let fields = actual.objectValue else {
            XCTFail("\(path) 应当是对象，得到 \(actual.kindName)", file: file, line: line)
            return
        }
        for (key, value) in wantObject {
            expectSubset(fields[key], value, path: "\(path).\(key)", file: file, line: line)
        }
        return
    }
    if let text = want as? String {
        XCTAssertEqual(actual.stringValue, text, path, file: file, line: line)
        return
    }
    if let number = want as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            XCTAssertEqual(actual.boolValue, number.boolValue, path, file: file, line: line)
        } else {
            XCTAssertEqual(actual.intValue, number.int64Value, path, file: file, line: line)
        }
        return
    }
    XCTFail("\(path): 向量里出现了没法比对的期望值 \(want)", file: file, line: line)
}
