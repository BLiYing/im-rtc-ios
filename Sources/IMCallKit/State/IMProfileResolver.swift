import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 宿主身份解析：把 uid 翻成**这台设备上该显示的**名字与头像。
///
/// # 为什么这件事必须交给宿主
///
/// Kit 只认识 uid。而宿主的显示名往往是一条链——备注 > 群昵称 > 昵称——其中
/// **备注是查看者私有的**：同一个 uid 在五个人的九宫格里可能要显示五个不同的名字。
/// 服务端只有一份房间状态、一条广播通道，它在物理上就发不出五个不同的值；
/// 硬塞进协议的结果是「我给某人起的私房备注被广播给了全房间」。
///
/// 所以这条链整个留在宿主，Kit 只开一个口子问它。
/// 详见 im-rtc-server/docs/design/HOST_PROFILE_DISPLAY_DESIGN.md §1、§3。
///
/// # 两条形状约束
///
/// 1. **同步返回**。宿主的解析器（IMProgram 的 `IMUserProfileCache` 一类）都是
///    「命中就返回，没命中返回 nil 并在后台攒一批去拉」。Kit 在绘制路径上调用它，
///    解析不到时先画兜底，等宿主调 `IMCallKit.reloadProfiles(_:)` 再重画。
/// 2. **头像给已经加载好的 `UIImage`，不给 URL**。Kit 不知道宿主的 base host、
///    不知道要不要带鉴权头，也不该把某个图片库强加给宿主。
///    **Kit 不发任何指向宿主域的请求。**
///
/// # 不实现会怎样
///
/// 退化成显示 uid。作为通用 SDK 这是合理默认——「内部 ID 不该上屏」是某个宿主的
/// 产品纪律，不是本产品的。
@objc public protocol IMProfileResolving: AnyObject {

    /// 这个 uid 在本机该显示成什么名字。
    ///
    /// 返回 `nil` 或空白 = 还没解析到（或查到了但没名字），Kit 会用兜底（默认 uid）。
    /// **空白也算没有**：「查到了但名字是空的」直接用会让格子上什么都没有。
    @objc func displayName(forUID uid: String) -> String?

    #if canImport(UIKit)
    /// 这个 uid 的头像，**已经加载好的 `UIImage`**。返回 `nil` = 退化成首字母色块。
    ///
    /// 只在有 UIKit 的平台上存在：本包为跑单测会在 macOS 上编一遍，那里没有 `UIImage`。
    /// **显示名那一半刻意不依赖 UIKit**——它才是有分支的逻辑（空白兜底、空 uid、
    /// 各机各名），必须能在 macOS 的单测里跑到。
    @objc optional func avatarImage(forUID uid: String) -> UIImage?
    #endif
}

/// 取本机该显示的名字。解析不到（或名字是空白）时返回 `fallback`，调用方通常传 uid。
///
/// 本端那格 uid 是空串——不解析，直接用 fallback（那就是「我」）。
func imResolvedName(_ resolver: IMProfileResolving?, uid: String, fallback: String) -> String {
    guard !uid.isEmpty, let resolver else { return fallback }
    let name = resolver.displayName(forUID: uid)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? fallback : name
}

#if canImport(UIKit)
/// 取本机该显示的头像；没有就返回 nil，调用方退化成首字母色块。
func imResolvedAvatar(_ resolver: IMProfileResolving?, uid: String) -> UIImage? {
    guard !uid.isEmpty, let resolver else { return nil }
    return resolver.avatarImage?(forUID: uid)
}
#endif
