import Foundation

/*
 头像取色（规范 §02）：没有头像图时用**首字母 + 渐变底**，取哪一个渐变由
 `fnv1a32(uid) % 9` 决定。**四端共用这一个哈希**——同一个 uid 在你手机上是紫的、
 在对方电脑上是绿的，那就是 bug。Web 端的向量在 `packages/call-uikit-react/test/avatar.test.ts`，
 本仓的 `AvatarTests` 钉的是同一组数。

 纯算术，不 import UIKit，所以能在 macOS 上 `swift test`。
 */

/// imFNV1a32 是 32 位 FNV-1a，按 UTF-8 字节算（不是 UTF-16 码元）。
public func imFNV1a32(_ text: String) -> UInt32 {
    var hash: UInt32 = 0x811c9dc5
    for byte in text.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16777619
    }
    return hash
}

/// 九色板的项数。
public let IMAvatarPaletteCount = 9

/// imAvatarIndex 把 uid 映射到九色板的下标。
public func imAvatarIndex(_ uid: String) -> Int {
    Int(imFNV1a32(uid) % UInt32(IMAvatarPaletteCount))
}

/// imAvatarInitial 取首字母（大写）；空的给问号。
public func imAvatarInitial(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
}
