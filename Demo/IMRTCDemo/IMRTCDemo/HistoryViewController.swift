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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "通话记录"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "r")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .trash, target: self, action: #selector(clear))
        let previous = session.onChange
        session.onChange = { [weak self] in previous?(); self?.tableView.reloadData() }
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

    private static func summary(_ record: DemoSession.Record) -> String {
        let direction = record.role == "callee" ? "来电" : "呼出"
        let outcome: String
        switch record.reason {
        case "hangup": outcome = imFormatDuration(record.durationSec)
        case "cancel": outcome = "已取消"
        case "reject": outcome = record.role == "callee" ? "已拒接" : "对方拒接"
        case "busy": outcome = "对方忙线"
        case "no_answer", "timeout": outcome = record.role == "callee" ? "未接来电" : "无应答"
        case "network": outcome = "网络中断"
        default: outcome = record.reason
        }
        let time = DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: Double(record.endedAtMS) / 1000),
            dateStyle: .short, timeStyle: .short)
        return "\(direction) · \(outcome) · \(time)"
    }
}
