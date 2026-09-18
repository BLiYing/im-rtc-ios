import AVFoundation
import Foundation
import IMCallEngine
import ObjectiveC

/**
 抓现行：谁在写 `AVAudioSession` 的类目、谁在把它停掉。**Demo 专用的诊断钩子，不进 SDK。**

 # 为什么要它

 2026-09-18 视频通话双向无声：接通后音频会话被反复打回 `SoloAmbient`。
 能静态排除的写手已经全排完了——我们的代码只有一处设类目、这个预编译包反汇编
 后没有任何一处写 `SoloAmbient`、`AVCaptureSession` 的两个旗标也已确认留住——
 剩下的写手在 Apple 框架内部，静态看不见。三次盲修全错。

 这个钩子把 `AVAudioSession` 的几个 setter 换成先记调用栈再转发原实现：
 谁写了非通话类目，`stack` 字段里就是它。调用栈带框架名（AVFAudio / WebRTC / IMRTCDemo），
 足够分清是包里的哪条路、还是系统自己。

 # 抓不到的情形

 只能抓走 ObjC `setCategory…` / `setActive:` 这几个入口的写入。要是那一笔走的是
 C 层（`AudioSessionSetProperty` 之类）或者在 mediaserverd 那一侧，这里一条都不会有——
 那本身也是结论：写手不在本进程的 ObjC 层。

 # 怎么装

 `AppDelegate` 启动时 `install()` 一次。用 `imp_implementationWithBlock` 换实现，
 不走 Swift extension + selector 那套（`error:` 出参在 Swift 侧声明起来太别扭）。
 */
enum AudioSessionTracer {

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swizzleSetCategory()
        swizzleSetCategoryWithOptions()
        swizzleSetCategoryModeOptions()
        swizzleSetCategoryModePolicyOptions()
        swizzleSetActive()
        IMRTCLog.info("[Demo] 音频会话写入追踪已装上", [:])
    }

    // MARK: - 记录

    private static func note(_ what: String, category: String?, extra: [String: String] = [:]) {
        var fields = extra
        fields["via"] = what
        if let category { fields["category"] = category }
        fields["stack"] = callers()
        // 通话态是我们自己写的，只记一条 info 看时序；别的类目都是嫌疑，警告 + 全栈。
        if let category, category != AVAudioSession.Category.playAndRecord.rawValue {
            IMRTCLog.warn("[Demo] 有人把音频会话写成非通话类目", fields)
        } else {
            IMRTCLog.info("[Demo] 音频会话被写入", fields)
        }
    }

    /// callers 取调用栈，跳过本文件自己的那几帧，压成一行。
    static func callers() -> String {
        let symbols = Thread.callStackSymbols
        // 前几帧是 Thread.callStackSymbols / 本函数 / note / swizzle 块，从第 4 帧起取。
        let interesting = symbols.dropFirst(4).prefix(14)
        return interesting.map { frame -> String in
            // "3   AVFAudio   0x00000001 -[AVAudioSession setCategory:error:] + 123" → "AVFAudio -[AVAudioSession setCategory:error:]"
            let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { return String(frame) }
            let module = parts[1]
            let symbol = parts[3...].joined(separator: " ")
            let trimmed = symbol.replacingOccurrences(of: #" \+ \d+$"#, with: "", options: .regularExpression)
            return "\(module) \(trimmed)"
        }.joined(separator: " | ")
    }

    // MARK: - 换实现

    private static func replace(_ selector: Selector, with block: Any) -> IMP? {
        guard let method = class_getInstanceMethod(AVAudioSession.self, selector) else {
            IMRTCLog.warn("[Demo] 找不到要追踪的方法", ["selector": NSStringFromSelector(selector)])
            return nil
        }
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(block))
        return original
    }

    private typealias SetCategoryIMP = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> Bool
    private static func swizzleSetCategory() {
        let sel = NSSelectorFromString("setCategory:error:")
        var original: IMP?
        let block: @convention(block) (AnyObject, NSString, UnsafeMutablePointer<NSError?>?) -> Bool = { obj, category, error in
            note("setCategory:", category: category as String)
            guard let original else { return false }
            return unsafeBitCast(original, to: SetCategoryIMP.self)(obj, sel, category, error)
        }
        original = replace(sel, with: block)
    }

    private typealias SetCategoryOptionsIMP = @convention(c) (AnyObject, Selector, NSString, UInt, UnsafeMutablePointer<NSError?>?) -> Bool
    private static func swizzleSetCategoryWithOptions() {
        let sel = NSSelectorFromString("setCategory:withOptions:error:")
        var original: IMP?
        let block: @convention(block) (AnyObject, NSString, UInt, UnsafeMutablePointer<NSError?>?) -> Bool = { obj, category, options, error in
            note("setCategory:withOptions:", category: category as String, extra: ["options": String(options)])
            guard let original else { return false }
            return unsafeBitCast(original, to: SetCategoryOptionsIMP.self)(obj, sel, category, options, error)
        }
        original = replace(sel, with: block)
    }

    private typealias SetCategoryModeOptionsIMP = @convention(c) (AnyObject, Selector, NSString, NSString, UInt, UnsafeMutablePointer<NSError?>?) -> Bool
    private static func swizzleSetCategoryModeOptions() {
        let sel = NSSelectorFromString("setCategory:mode:options:error:")
        var original: IMP?
        let block: @convention(block) (AnyObject, NSString, NSString, UInt, UnsafeMutablePointer<NSError?>?) -> Bool = { obj, category, mode, options, error in
            note("setCategory:mode:options:", category: category as String,
                 extra: ["mode": mode as String, "options": String(options)])
            guard let original else { return false }
            return unsafeBitCast(original, to: SetCategoryModeOptionsIMP.self)(obj, sel, category, mode, options, error)
        }
        original = replace(sel, with: block)
    }

    private typealias SetCategoryModePolicyOptionsIMP = @convention(c) (AnyObject, Selector, NSString, NSString, Int, UInt, UnsafeMutablePointer<NSError?>?) -> Bool
    private static func swizzleSetCategoryModePolicyOptions() {
        let sel = NSSelectorFromString("setCategory:mode:routeSharingPolicy:options:error:")
        var original: IMP?
        let block: @convention(block) (AnyObject, NSString, NSString, Int, UInt, UnsafeMutablePointer<NSError?>?) -> Bool = { obj, category, mode, policy, options, error in
            note("setCategory:mode:routeSharingPolicy:options:", category: category as String,
                 extra: ["mode": mode as String, "policy": String(policy), "options": String(options)])
            guard let original else { return false }
            return unsafeBitCast(original, to: SetCategoryModePolicyOptionsIMP.self)(obj, sel, category, mode, policy, options, error)
        }
        original = replace(sel, with: block)
    }

    private typealias SetActiveIMP = @convention(c) (AnyObject, Selector, Bool, UInt, UnsafeMutablePointer<NSError?>?) -> Bool
    private static func swizzleSetActive() {
        let sel = NSSelectorFromString("setActive:withOptions:error:")
        var original: IMP?
        let block: @convention(block) (AnyObject, Bool, UInt, UnsafeMutablePointer<NSError?>?) -> Bool = { obj, active, options, error in
            // 停掉会话本身不改类目，但"谁停的、什么时候停的"是拉锯时序里缺的那一半。
            if active {
                note("setActive:true", category: nil, extra: ["options": String(options)])
            } else {
                IMRTCLog.warn("[Demo] 有人把音频会话停掉了", ["options": String(options), "stack": callers()])
            }
            guard let original else { return false }
            return unsafeBitCast(original, to: SetActiveIMP.self)(obj, sel, active, options, error)
        }
        original = replace(sel, with: block)
    }
}
