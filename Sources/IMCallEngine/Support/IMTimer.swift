import Foundation

/*
 可取消定时器的样板（`makeTimerSource` → `schedule` → `setEventHandler` → `resume`）。

 原先 Engine / Kit / WebRTC 三个 target 里各手写了十几份，四行一模一样，只有延时和回调不同；
 漏写 `resume()` 定时器就永远不响，而且没有任何报错。收成这几个函数之后每处只剩「多久、在哪条队列、做什么」。

 **访问级别是 `package`**：同一个包里的三个 target 共用，宿主看不见——这不是 SDK 的公开能力，
 不扩 API 面，也不进 `IMObjCAPICheck.m`。

 **返回的定时器已经 `resume()` 过**。调用方照旧自己持有、自己 `cancel()`。
 回调总是异步投到 `queue` 上，所以只要调用方本来就在这条串行队列上，
 「先起定时器、再把它记到属性上」与原先「先记再 resume」没有区别：回调不可能插在这两步中间。
 */

/// imAfter 在 `delay` 之后于 `queue` 上执行一次 `handler`。
package func imAfter(_ delay: DispatchTimeInterval, on queue: DispatchQueue,
                     _ handler: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + delay)
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
}

/// imAfter 的秒数版本（Kit 里的延时常量都是 `TimeInterval`）。
package func imAfter(_ seconds: TimeInterval, on queue: DispatchQueue,
                     _ handler: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + seconds)
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
}

/// imEvery 每隔 `interval` 于 `queue` 上执行一次 `handler`，第一次在一个间隔之后。
package func imEvery(_ interval: DispatchTimeInterval, on queue: DispatchQueue,
                     _ handler: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
}

/// imEvery 的秒数版本。`fireNow` 为 true 时第一次立刻执行（来电振动、合成视频帧泵），否则等一个间隔。
package func imEvery(_ seconds: TimeInterval, fireNow: Bool = false, on queue: DispatchQueue,
                     _ handler: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: fireNow ? .now() : .now() + seconds, repeating: seconds)
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
}
