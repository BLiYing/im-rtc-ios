import Foundation

/*
 通话记录的时间文案（四端统一的规则，用例表也四端一致）：

 | 发起于 | 显示 |
 |---|---|
 | 今天 | `HH:mm` |
 | 昨天 | `昨天 HH:mm` |
 | 今年更早 | `M月d日 HH:mm` |
 | 往年 | `yyyy年M月d日 HH:mm` |

 - **按自然日**判断今天 / 昨天（本地时区的零点），不按 24 小时：昨天 23:50 的通话今天 00:10 看仍是「昨天」。
 - 用**发起时间**，跨零点的通话归到发起那天。
 - 记录时间比 `nowMS` 还晚（设备与服务端时钟有偏差）按今天处理，不显示「明天」。
 - 时分部分由 `hourMinute` 出（Demo 传系统的 12 / 24 小时制格式），本函数只管日期档位。

 与 Android `HistoryTime.kt` 逐行对应；`Tests/DemoLogicTests/HistoryTimeTests.swift` 是同一张用例表。
 （本文件同时被 Demo 工程与 `DemoLogicTests` 编进去，所以只依赖 Foundation。）
 */
func formatCallTime(startedAtMS: Int64, nowMS: Int64,
                    calendar: Calendar = .current,
                    // 三档默认就是中文——不传就是原来的行为，`HistoryTimeTests` 不用改。
                    // Demo 工程按语言传本地化版本（见 `DemoText.swift` 的 `dt("demo.time.*")`）。
                    yesterday: (String) -> String = { "昨天 \($0)" },
                    sameYear: (Int, Int, String) -> String = { m, d, t in "\(m)月\(d)日 \(t)" },
                    otherYear: (Int, Int, Int, String) -> String = { y, m, d, t in "\(y)年\(m)月\(d)日 \(t)" },
                    hourMinute: (Date) -> String) -> String {
    let started = Date(timeIntervalSince1970: Double(startedAtMS) / 1000)
    let now = Date(timeIntervalSince1970: Double(nowMS) / 1000)
    let time = hourMinute(started)

    if startedAtMS >= nowMS || calendar.isDate(started, inSameDayAs: now) { return time }
    if let dayBefore = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(started, inSameDayAs: dayBefore) {
        return yesterday(time)
    }
    let parts = calendar.dateComponents([.year, .month, .day], from: started)
    let year = parts.year ?? 0, month = parts.month ?? 0, day = parts.day ?? 0
    if year == calendar.component(.year, from: now) { return sameYear(month, day, time) }
    return otherYear(year, month, day, time)
}
