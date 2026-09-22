import UIKit
import IMCallEngine
import IMCallKit

/*
 通话记录（草图 §02-C）：**调 SDK 的 `fetchCallHistory` 从服务端拉**，游标翻页。

 这一屏是「宿主会拿 SDK 做什么」的示范，不是要求宿主照抄——
 想自己存，就拿 `callDidEnd(reason, duration)` 落自己的库；想让换设备、重装后记录还在，就查这里。
 未接来电红字。

 - 下拉刷新；滑到倒数第 3 行自动加下一页，`nextCursor == nil` 就停。
 - 每次进页、每次通话结束都会重拉首页（通话结束由 `DemoSession` 通知）。
 - 服务端的 `reason` 不分角色，角色由 `caller == 我` 推出，再交给 `imEndReasonText`。
 */
final class HistoryViewController: UITableViewController {

    private static let pageSize = 20
    private static let prefetchDistance = 3

    private let session = DemoSession.shared
    private var changeObserverToken: UUID?

    private var records: [IMCallHistoryRecord] = []
    private var nextCursor: Int64?
    private var isLoading = false
    /// 刷新会让还在路上的旧请求作废：应答回来时代数对不上就丢掉。
    private var generation = 0

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    init() { super.init(style: .insetGrouped) }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit {
        if let changeObserverToken { session.removeChangeObserver(changeObserverToken) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = dt("demo.history.title")
        tableView.register(HistoryCell.self, forCellReuseIdentifier: "r")
        tableView.backgroundView = statusLabel
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
        changeObserverToken = session.addChangeObserver { [weak self] in self?.reload() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: - 加载

    @objc private func reload() {
        generation += 1
        isLoading = false
        nextCursor = nil
        load(first: true)
    }

    private func load(first: Bool) {
        guard !isLoading, let engine = session.engine else {
            if session.engine == nil { show(records: [], message: dt("demo.conn.loggedOut")) }
            refreshControl?.endRefreshing()
            return
        }
        isLoading = true
        let ticket = generation
        let cursor = first ? nil : nextCursor
        Task { @MainActor in
            defer { if ticket == generation { isLoading = false; refreshControl?.endRefreshing() } }
            do {
                let page = try await engine.fetchCallHistory(limit: Self.pageSize, cursor: cursor)
                guard ticket == generation else { return }
                nextCursor = page.nextCursor
                show(records: first ? page.records : records + page.records, message: nil)
            } catch {
                guard ticket == generation else { return }
                let detail = (error as? IMRTCError)?.detail ?? error.localizedDescription
                show(records: first ? [] : records, message: dt("demo.history.loadFailedIos", ["msg": detail]))
            }
        }
    }

    private func show(records: [IMCallHistoryRecord], message: String?) {
        self.records = records
        statusLabel.text = records.isEmpty ? (message ?? dt("demo.history.emptyIos")) : nil
        tableView.reloadData()
    }

    // MARK: - 列表

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                            forRowAt indexPath: IndexPath) {
        if nextCursor != nil, indexPath.row >= records.count - Self.prefetchDistance {
            load(first: false)
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "r", for: indexPath)
        guard let row = cell as? HistoryCell else { return cell }
        let record = records[indexPath.row]
        let me = session.engine?.uid ?? ""
        let role = record.caller == me ? "caller" : "callee"
        // 未接来电红字：被叫 + 没接通。
        let missed = role == "callee" && record.durationSec == 0
        row.configure(
            icon: record.isGroup ? "👥" : (record.mediaType == "video" ? "📹" : "📞"),
            name: Self.peerText(record, me: me), nameRed: missed,
            summary: Self.summary(record, role: role),
            time: Self.timeText(record))
        return row
    }

    /// 对方是谁：被叫看主叫；主叫看第一个被叫（群通话显示人数）。
    private static func peerText(_ record: IMCallHistoryRecord, me: String) -> String {
        if record.isGroup {
            let count = max(record.members.count, 1) + (record.members.contains { $0.uid == record.caller } ? 0 : 1)
            return dt("demo.history.groupCall", ["n": count])
        }
        if record.caller != me { return record.caller.isEmpty ? dt("demo.history.unknown") : record.caller }
        return record.members.first { $0.uid != me }?.uid ?? dt("demo.history.unknown")
    }

    /*
     结束原因的文案调 IMCallKit 公开的 `imEndReasonText(_:role:durationSec:)`（四端对齐的唯一权威来源），
     Demo 不自己另存一份随时间漂走的映射。
     */
    private static func summary(_ record: IMCallHistoryRecord, role: String) -> String {
        let direction = role == "callee" ? dt("demo.history.incoming") : dt("demo.history.outgoing")
        let outcome = imEndReasonText(record.reason, role: role, durationSec: record.durationSec)
        return "\(direction) · \(outcome)"
    }

    /// 今天 `HH:mm`、昨天 `昨天 HH:mm`、今年更早 `M月d日 HH:mm`、往年带年份；见 ``formatCallTime``。
    private static func timeText(_ record: IMCallHistoryRecord) -> String {
        formatCallTime(startedAtMS: record.startedAtMS,
                       nowMS: Int64(Date().timeIntervalSince1970 * 1000),
                       yesterday: { dt("demo.time.yesterday", ["time": $0]) },
                       sameYear: { dt("demo.time.sameYear", ["month": $0, "day": $1, "time": $2]) },
                       otherYear: { dt("demo.time.otherYear", ["year": $0, "month": $1, "day": $2, "time": $3]) }) {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        }
    }
}

/// 一行：左图标（36pt 宽、20pt 字）、中间两行（名字 16pt 粗体 / 「方向 · 结果」13pt 灰）、右边时间（13pt 灰）。
private final class HistoryCell: UITableViewCell {
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    private let timeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        iconLabel.font = .systemFont(ofSize: 20)
        iconLabel.textAlignment = .center
        nameLabel.font = .boldSystemFont(ofSize: 16)
        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabel
        timeLabel.font = .systemFont(ofSize: 13)
        timeLabel.textColor = .secondaryLabel
        timeLabel.textAlignment = .right
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let texts = UIStackView(arrangedSubviews: [nameLabel, summaryLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [iconLabel, texts, timeLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            iconLabel.widthAnchor.constraint(equalToConstant: 36),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func configure(icon: String, name: String, nameRed: Bool, summary: String, time: String) {
        iconLabel.text = icon
        nameLabel.text = name
        nameLabel.textColor = nameRed ? .systemRed : .label
        summaryLabel.text = summary
        timeLabel.text = time
    }
}
