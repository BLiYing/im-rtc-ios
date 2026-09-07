import Foundation

/// `device_id` 的入参校验（协议 §2.5）。
///
/// # 为什么要在端上拦一道
///
/// **不拦的症状是「登录失败，没有下文」**：服务端回 1004，客户端握手失败，
/// 而服务端那句说得很清楚的「device_id 只允许 `[A-Za-z0-9_-]`」**到不了宿主手里**——
/// 宿主看到的只有一个 `bad_params`。安卓真机上踩过一次（`Build.MODEL` 是
/// `Pixel 2 XL`，带空格），查了一轮才定位到是机型名。
///
/// iOS 上 `UIDevice.current.name` 是最常见的坑：默认就叫「张三的 iPhone」，
/// 中文加空格，两条规则一起犯。`identifierForVendor` 的 UUID 反倒是合规的
/// （只有十六进制和连字符），推荐用它。
///
/// # 只校验，不改写
///
/// `device_id` 要求**跨重启稳定**，SDK 悄悄替宿主改掉，宿主自己那套设备管理
/// （设备列表、注销设备、顶号）就跟服务端对不上账了。清洗是宿主的事。
///
/// 真要清洗，**别用「删掉非法字符」那种做法**：`MI 8` 与 `MI8` 是两款不同的机器，
/// 删完就撞成同一个 device_id，而撞号的后果是两台设备互相顶号、轮流把对方踢下线。
/// 换成 `-` 才不会。
/// # 为什么是 `NSObject` 子类而不是 enum 命名空间
///
/// 无 case 的 Swift enum **在 ObjC 里根本不存在**——它不会出现在生成的
/// `IMCallEngine-Swift.h` 里，宿主照着上面那句「自己先调它验一遍」写
/// `[IMDeviceID checkDeviceID:d error:&err]` 会直接编不过。
/// 首批宿主 IMProgram 是 ObjC 工程，而 CONVENTIONS §4 要求公开面 ObjC 可用。
/// 调用示例在 `Demo/IMRTCDemo/IMRTCDemo/IMObjCAPICheck.m`，编译即验证。
@objc public final class IMDeviceID: NSObject {
    /// 协议 §2.5：`device_id` ≤64 **字节**（不是字符）。中文一个字三字节。
    ///
    /// 公开是因为宿主要拿它裁自己生成的 id——只给一句「上限 64」而不给常量，
    /// 宿主就会把 64 抄进自己代码里，将来协议改了两边对不上。
    @objc public static let maxBytes = 64

    /// 纯命名空间，不给实例。
    private override init() { super.init() }

    /// check 校验 `device_id`，不合规就抛 ``IMRTCError`` (`bad_params`)。
    ///
    /// 抛的码**和服务端拒绝时是同一个 1004**——宿主那套按 code 分支的错误处理
    /// 不用为「本地拦下的」和「服务端拒的」写两遍，具体哪里不对看 `detail`。
    /// （ObjC 侧靠 `IMRTCError` 的 `CustomNSError` 桥接拿到这个码，
    /// 不然 `NSError.code` 会是没有意义的 1。）
    ///
    /// 宿主也可以自己先调它验一遍生成的 id，不必等到 `login()`。
    @objc(checkDeviceID:error:)
    public static func check(_ deviceID: String) throws {
        guard !deviceID.isEmpty else {
            throw IMRTCError(.badParams, "device_id 不能为空（协议 §2.5）")
        }
        let bytes = deviceID.utf8.count
        guard bytes <= maxBytes else {
            throw IMRTCError(.badParams, "device_id 长 \(bytes) 字节，上限 \(maxBytes)（协议 §2.5）")
        }
        if let bad = deviceID.first(where: { !isAllowed($0) }) {
            throw IMRTCError(.badParams,
                             "device_id 只允许 [A-Za-z0-9_-]，出现了 '\(bad)'（协议 §2.5）。"
                                + "拿 UIDevice.current.name 当 id 的话记得先清洗——"
                                + "「张三的 iPhone」里空格和中文都不合规")
        }
    }

    private static func isAllowed(_ ch: Character) -> Bool {
        ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
    }
}
