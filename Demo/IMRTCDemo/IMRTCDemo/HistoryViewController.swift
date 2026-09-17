import UIKit
import IMCallKit

/*
 通话记录（草图 §02-C）：**完全由 `callDidEnd(reason, duration)` 拼出来**，Demo 自己存本地。

 这一屏是「宿主会拿回调做什么」的示范，不是要求宿主照抄——
 换成消息气泡、换成后台查 `/v1/calls`，都是同一份数据。
 未接来电红字。
 */
final class HistoryViewController: UITableViewController {

    private let session = DemoSession.shared
    /// `session.addChangeObserver` 的退订 token。
    private var changeObserverToken: UUID?

    deinit {
        if let changeObserverToken { session.removeChangeObserver(changeObserverToken) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "通话记录"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "r")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .trash, target: self, action: #selector(clear))
        changeObserverToken = session.addChangeObserver { [weak self] in self?.tableView.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc private func clear() { session.clearRecords() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        session.records.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "r", for: indexPath)
        let record = session.records[indexPath.row]
        var content = cell.defaultContentConfiguration()
        let icon = record.isGroup ? "👥" : (record.mediaType == "video" ? "📹" : "📞")
        content.text = "\(icon) \(record.peer.isEmpty ? "（未知）" : record.peer)"
        content.secondaryText = Self.summary(record)
        // 未接来电红字：被叫 + 没接通。
        let missed = record.role == "callee" && record.durationSec == 0
        content.secondaryTextProperties.color = missed ? .systemRed : .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    /*
     结束原因的文案**改调 IMCallKit 公开的 `imEndReasonText(_:role:durationSec:)`**（2026-09-17）。

     原先这里自己手拼了一份 switch，漏了 offline / answered_elsewhere / rejected_elsewhere /
     room_closed / kicked 这几种——这些原因发生时会掉进 `default: outcome = record.reason`，
     直接把线路上的 snake_case 原样显示给用户（比如一行「呼出 · offline · 10:32」）。
     SDK 那份是四端对齐维护的唯一权威来源，Demo 不该自己另存一份随时间漂走的映射。

     **行为变化**：hangup 分支的文案从纯时长（如 "12:34"）变成 "通话结束 · 12:34"
     （无时长时 "通话结束"），与 Kit 结束页、Android/Web Demo 的措辞一致；
     去掉了本地独有的 "timeout" 分支——它不在协议的结束原因表里，
     真实场景不会收到，SDK 那份也没有对应分支。
     */
    private static func summary(_ record: DemoSession.Record) -> String {
        let direction = record.role == "callee" ? "来电" : "呼出"
        let outcome = imEndReasonText(record.reason, role: record.role, durationSec: record.durationSec)
        let time = DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: Double(record.endedAtMS) / 1000),
            dateStyle: .short, timeStyle: .short)
        return "\(direction) · \(outcome) · \(time)"
    }
}
