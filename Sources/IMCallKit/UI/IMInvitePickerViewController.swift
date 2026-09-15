#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 「添加成员」的选人页（交互稿 §05 G2，HOST_INTEGRATION_DESIGN §3.4）。

 **取名单优先级**：宿主接管选人页（`presentInvitePicker`，由 `IMCallOverlayViewController.onInvite`
 判断，走不到这个类）> `IMCallKitConfig.inviteMemberProvider` > 静态 `inviteCandidates`
 （保留兼容）> 空态「没有可邀请的成员」。

 有 provider 时走网络分页：停止输入 300ms 才发请求（新请求作废旧结果）、滚到底且有
 `nextCursor` 时取下一页、加载中 / 失败（带重试）/ 超时（10 秒未回调算失败）三态。
 没有 provider 时退回旧的静态名单 + 本地过滤，行为与之前一致。

 已在通话里的人**置灰 + 勾选禁用**，不是隐藏：用户要能看到「他已经在里面了」。
 `selectable == false` 的候选人同样置灰，并显示 `unselectableReason`。
 顶部实时算「还能加 N 人」= 9 − 当前人数 − 已选。
 */
final class IMInvitePickerViewController: UITableViewController, UISearchBarDelegate {

    /// provider 未在 10 秒内回调就按失败处理（§3.4：容信 iOS 现有实现账号全无效时不回调，页面永远转圈）。
    private static let requestTimeoutSeconds: TimeInterval = 10
    /// 停止输入这么久才发请求（§3.4）。
    private static let searchDebounceMS = 300

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private let controller: IMCallController
    private let provider: IMInviteMemberProvider?
    /// 上下文在打开选人页那一刻快照一次——通话中途群号不会变（协议 §4.1）。
    private let context: IMInviteContext

    private let searchBar = UISearchBar()
    private let inviteButton = UIButton(type: .system)
    private var picked: [String] = []
    private var query = ""

    /// provider 累计取到的候选人（跨页）。没有 provider 时不用这个字段，走 `controller.inviteCandidates`。
    private var pages: [IMInviteCandidate] = []
    private var nextCursor: String?
    private var loadState: LoadState = .loading
    private var isLoadingMore = false
    /// **新请求作废旧结果**的代际计数：迟到的旧请求回来时代际对不上就整个丢弃。
    private var requestGeneration = 0
    private var searchDebounce: DispatchWorkItem?
    private var requestTimeout: DispatchWorkItem?

    init(controller: IMCallController) {
        self.controller = controller
        self.provider = controller.inviteMemberProvider
        self.context = controller.inviteContext
        super.init(style: .insetGrouped)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController { sheet.detents = [.medium(), .large()] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    deinit {
        searchDebounce?.cancel()
        requestTimeout?.cancel()
    }

    private var inCall: Set<String> { Set(controller.state.participants.map(\.uid)) }

    /// candidates 是**这一屏此刻该展示的候选人**：provider 有数据就用它的累计页，
    /// 没有 provider 时退回静态名单本地过滤。两条路都要去掉自己与发起人
    /// （发起人不在服务端成员表里，离场后拉不回来，回 bad_params）。
    private var candidates: [IMInviteCandidate] {
        let base: [IMInviteCandidate]
        if provider != nil {
            base = pages
        } else {
            let q = query.trimmingCharacters(in: .whitespaces)
            let all = controller.inviteCandidates
            base = q.isEmpty ? all : all.filter { $0.uid.contains(q) || $0.name.contains(q) }
        }
        return base.filter { $0.uid != controller.engine.uid && $0.uid != context.callerUID }
    }

    private var typedUID: String? {
        guard controller.allowsManualUIDInput, candidates.isEmpty else { return nil }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !inCall.contains(q), !picked.contains(q), q != context.callerUID else { return nil }
        return q
    }

    /// 还能再选几个。**每次现算**：选人页开着的时候别人可能进来了，打开那一刻的快照会让人多选。
    private var slotsLeft: Int { imInviteSlotsLeft(for: controller.state) - picked.count }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = IMKitTheme.current
        title = "添加成员"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = theme.banner
        tableView.backgroundColor = theme.banner
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: IMKitIcon.xmark.image(pointSize: 15), style: .plain, target: self, action: #selector(close))
        searchBar.placeholder = provider != nil ? "搜索联系人" : (controller.inviteCandidates.isEmpty ? "输入对方 uid" : "搜索联系人")
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        tableView.tableHeaderView = searchBar
        searchBar.sizeToFit()

        inviteButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        inviteButton.layer.cornerRadius = 12
        inviteButton.addTarget(self, action: #selector(invite), for: .touchUpInside)
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 76))
        inviteButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(inviteButton)
        NSLayoutConstraint.activate([
            inviteButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            inviteButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            inviteButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            inviteButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        tableView.tableFooterView = footer
        refreshChrome()

        if provider != nil {
            loadPage(reset: true)
        } else {
            loadState = .loaded
        }
    }

    private func refreshChrome() {
        let theme = IMKitTheme.current
        navigationItem.prompt = "还能加 \(max(slotsLeft, 0)) 人"
        inviteButton.setTitle(picked.isEmpty ? "邀请" : "邀请 \(picked.count) 人", for: .normal)
        inviteButton.backgroundColor = picked.isEmpty ? theme.controlBackground : theme.accept
        inviteButton.setTitleColor(picked.isEmpty ? theme.secondaryText : theme.acceptText, for: .normal)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func invite() {
        guard !picked.isEmpty else { return }
        controller.inviteMore(picked)
        dismiss(animated: true)
    }

    private func toggle(_ uid: String) {
        if let index = picked.firstIndex(of: uid) {
            picked.remove(at: index)
        } else if slotsLeft > 0 {
            picked.append(uid)
        }
        refreshChrome()
        tableView.reloadData()
    }

    // MARK: - 取数据（provider 路径）

    /// loadPage 取一页。`reset == true`：新搜索或首次加载，替换 `pages`；
    /// `reset == false`：滚到底追加，保留已有的 `pages`。
    private func loadPage(reset: Bool) {
        guard let provider else { return }
        requestGeneration += 1
        let generation = requestGeneration
        if reset {
            loadState = .loading
            pages = []
            nextCursor = nil
        } else {
            guard !isLoadingMore, nextCursor != nil else { return }
            isLoadingMore = true
        }
        tableView.reloadData()

        requestTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.handleResult(generation: generation, items: [],
                                                                            nextCursor: nil, error: Self.timeoutError()) }
        requestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeoutSeconds, execute: timeout)

        let cursor = reset ? nil : nextCursor
        provider.inviteCandidates(for: context, query: query, cursor: cursor) { [weak self] items, next, error in
            DispatchQueue.main.async { self?.handleResult(generation: generation, items: items,
                                                           nextCursor: next, error: error) }
        }
    }

    private static func timeoutError() -> NSError {
        NSError(domain: IMRTCErrorDomain, code: IMErrorCode.signalingTimeout.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "provider 10 秒未回调"])
    }

    /// handleResult 落地一次 provider 回调。**代际对不上就整个丢弃**——旧请求作废后
    /// 才回来的结果不许覆盖新请求已经画出来的东西。
    private func handleResult(generation: Int, items: [IMInviteCandidate], nextCursor: String?, error: NSError?) {
        guard generation == requestGeneration else { return }
        requestTimeout?.cancel()
        isLoadingMore = false
        if let error {
            // 首次加载失败：整页失败态；翻页失败：保留已有数据，只是不再往下翻（下一次滚到底重试）。
            loadState = pages.isEmpty ? .failed(error.localizedDescription) : .loaded
            IMRTCLog.warn("[Kit] 选人页取候选人失败", ["err": error.localizedDescription])
        } else {
            pages += items
            self.nextCursor = (nextCursor?.isEmpty ?? true) ? nil : nextCursor
            loadState = .loaded
        }
        tableView.reloadData()
    }

    @objc private func retry() { loadPage(reset: pages.isEmpty) }

    // MARK: - 搜索（300ms 防抖；新请求作废旧结果）

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        guard provider != nil else {
            tableView.reloadData()
            return
        }
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.loadPage(reset: true) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.searchDebounceMS), execute: work)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchDebounce?.cancel()
        if let typedUID { toggle(typedUID); query = ""; searchBar.text = "" }
        if provider != nil { loadPage(reset: true) }
        searchBar.resignFirstResponder()
    }

    // MARK: - 列表
    //
    // 第 0 节：已选但不在当前候选页里的 uid + 手输的 uid（都只在空态里出现，见 `typedUID`）。
    // 第 1 节：加载中 → 空行 + `tableView.backgroundView` 转圈；失败 → 空行 + 失败态 + 重试；
    //          正常 → 候选人列表，滚到底且有下一页时追加取。

    private var extraRows: [String] {
        let outside = picked.filter { uid in !candidates.contains { $0.uid == uid } }
        return outside + (typedUID.map { [$0] } ?? [])
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return extraRows.count }
        switch loadState {
        case .loading, .failed:
            tableView.backgroundView = statusView(for: loadState)
            return 0
        case .loaded:
            tableView.backgroundView = candidates.isEmpty ? statusView(for: .loaded) : nil
            return candidates.count
        }
    }

    /// statusView 画加载中 / 失败 / 空态三选一的整页占位（Kit 没有单独的空表格样式，借 backgroundView）。
    private func statusView(for state: LoadState) -> UIView? {
        let theme = IMKitTheme.current
        let container = UIView()
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = theme.secondaryText
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        switch state {
        case .loading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = theme.secondaryText
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            container.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                spinner.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -12),
            ])
            label.text = "正在加载…"
        case let .failed(message):
            label.text = "加载失败：\(message)"
            let retryButton = UIButton(type: .system)
            retryButton.setTitle("重试", for: .normal)
            retryButton.setTitleColor(theme.accept, for: .normal)
            retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(retryButton)
            NSLayoutConstraint.activate([
                retryButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                retryButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            ])
        case .loaded:
            label.text = "没有可邀请的成员"
        }
        return container
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = IMKitTheme.current
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        cell.backgroundColor = UIColor(white: 1, alpha: 0.05)
        cell.textLabel?.textColor = theme.primaryText
        cell.detailTextLabel?.textColor = theme.secondaryText
        if indexPath.section == 0 {
            let uid = extraRows[indexPath.row]
            let isPicked = picked.contains(uid)
            cell.textLabel?.text = isPicked ? uid : "邀请 \(uid)"
            cell.accessoryType = isPicked ? .checkmark : .none
            cell.tintColor = theme.accept
            cell.selectionStyle = .default
            cell.textLabel?.alpha = 1
            return cell
        }
        let candidate = candidates[indexPath.row]
        let already = inCall.contains(candidate.uid)
        let blocked = already || !candidate.selectable
        var text = candidate.name
        if already {
            text += "（已在通话中）"
        } else if !candidate.selectable, let reason = candidate.unselectableReason, !reason.isEmpty {
            text += "（\(reason)）"
        } else if let subtitle = candidate.subtitle, !subtitle.isEmpty {
            cell.detailTextLabel?.text = subtitle
        }
        cell.textLabel?.text = text
        cell.textLabel?.alpha = blocked ? 0.45 : 1
        cell.accessoryType = blocked ? (already ? .checkmark : .none) : (picked.contains(candidate.uid) ? .checkmark : .none)
        cell.tintColor = blocked ? theme.secondaryText : theme.accept
        cell.selectionStyle = blocked ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let uid = extraRows[indexPath.row]
            toggle(uid)
            if !candidates.contains(where: { $0.uid == uid }) { query = ""; searchBar.text = "" }
            return
        }
        let candidate = candidates[indexPath.row]
        guard !inCall.contains(candidate.uid), candidate.selectable else { return }
        toggle(candidate.uid)
    }

    /// 滚到底且还有下一页时追加取（§3.4）。
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                            forRowAt indexPath: IndexPath) {
        guard provider != nil, indexPath.section == 1, nextCursor != nil, !isLoadingMore,
              indexPath.row >= candidates.count - 3 else { return }
        loadPage(reset: false)
    }
}
#endif
