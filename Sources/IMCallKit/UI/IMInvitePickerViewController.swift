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
final class IMInvitePickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {

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
    private let tableView = UITableView()
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
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController { sheet.detents = [.medium(), .large()] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    deinit {
        searchDebounce?.cancel()
        requestTimeout?.cancel()
    }

    /**
     `candidates` / `inCall` 原是计算属性，`cellForRowAt` 每一行都要重算一遍——
     `candidates` 要过滤整个候选名单，`inCall` 要重新拼一个 Set，n 行就是 O(n²)。
     现在只在 `reloadData()` 前调一次 `refreshListCache()`，行内只读缓存。
     */
    private var candidatesCache: [IMInviteCandidate] = []
    private var inCallCache: Set<String> = []

    /// 在通话里的人（含自己）。`state.participants` 不含自己，不补上的话自己会被当成可邀请。
    private func computeInCall() -> Set<String> {
        Set([controller.engine.uid] + controller.state.participants.map(\.uid))
    }

    /// candidates 是**这一屏此刻该展示的候选人**：provider 有数据就用它的累计页，
    /// 没有 provider 时退回静态名单本地过滤。宿主给什么列什么（含自己与发起人），在通话里的人置灰。
    private func computeCandidates() -> [IMInviteCandidate] {
        let base: [IMInviteCandidate]
        if provider != nil {
            base = pages
        } else {
            let q = query.trimmingCharacters(in: .whitespaces)
            let all = controller.inviteCandidates
            base = q.isEmpty ? all : all.filter { $0.uid.contains(q) || $0.name.contains(q) }
        }
        return base
    }

    /// refreshListCache 在每次 `tableView.reloadData()` 之前调一次：定住这一轮渲染要用的
    /// `candidates` / `inCall`，行内不再各自重算。
    private func refreshListCache() {
        inCallCache = computeInCall()
        candidatesCache = computeCandidates()
    }

    private var typedUID: String? {
        guard controller.allowsManualUIDInput, candidatesCache.isEmpty else { return nil }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !inCallCache.contains(q), !picked.contains(q) else { return nil }
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

        // 搜索框：固定在顶部
        searchBar.placeholder = provider != nil ? "搜索联系人" : (controller.inviteCandidates.isEmpty ? "输入对方 uid" : "搜索联系人")
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        // 列表：在搜索框和邀请按钮之间
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = theme.banner
        tableView.register(IMInviteCandidateCell.self, forCellReuseIdentifier: IMInviteCandidateCell.reuseID)
        tableView.rowHeight = 56
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        // 邀请按钮：固定在底部
        inviteButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        inviteButton.layer.cornerRadius = 12
        inviteButton.addTarget(self, action: #selector(invite), for: .touchUpInside)
        inviteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inviteButton)

        // 导航栏右上角关闭按钮
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: IMKitIcon.xmark.image(pointSize: 15), style: .plain, target: self, action: #selector(close))

        // Auto Layout 约束：固定搜索框 - 中间列表 - 固定按钮
        NSLayoutConstraint.activate([
            // 搜索框：顶部对齐，左右各 14
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            searchBar.heightAnchor.constraint(equalToConstant: 36),

            // 列表：搜索框下面，邀请按钮上面
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inviteButton.topAnchor, constant: -8),

            // 邀请按钮：底部固定
            inviteButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            inviteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            inviteButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            inviteButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        refreshChrome()

        if provider != nil {
            loadPage(reset: true)
        } else {
            loadState = .loaded
            // 没有 provider 时 `loadPage` 不会走，缓存要在这里现算一次——否则
            // `tableView` 第一次自动布局时 `candidatesCache` 还是空数组，页面开出来空空如也。
            refreshListCache()
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
        refreshListCache()
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
        refreshListCache()
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
        refreshListCache()
        tableView.reloadData()
    }

    @objc private func retry() { loadPage(reset: pages.isEmpty) }

    // MARK: - 搜索（300ms 防抖；新请求作废旧结果）

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        guard provider != nil else {
            refreshListCache()
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
        let outside = picked.filter { uid in !candidatesCache.contains { $0.uid == uid } }
        return outside + (typedUID.map { [$0] } ?? [])
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return extraRows.count }
        switch loadState {
        case .loading, .failed:
            tableView.backgroundView = statusView(for: loadState)
            return 0
        case .loaded:
            tableView.backgroundView = candidatesCache.isEmpty ? statusView(for: .loaded) : nil
            return candidatesCache.count
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

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = IMKitTheme.current
        let cell = tableView.dequeueReusableCell(withIdentifier: IMInviteCandidateCell.reuseID, for: indexPath)
        guard let row = cell as? IMInviteCandidateCell else { return cell }
        row.backgroundColor = theme.hairlineFill
        if indexPath.section == 0 {
            let uid = extraRows[indexPath.row]
            let isPicked = picked.contains(uid)
            row.configure(uid: uid, name: isPicked ? uid : "邀请 \(uid)", subtitle: nil, dimmed: false)
            row.accessoryType = isPicked ? .checkmark : .none
            row.tintColor = theme.accept
            row.selectionStyle = .default
            return row
        }
        let candidate = candidatesCache[indexPath.row]
        let already = inCallCache.contains(candidate.uid)
        let blocked = already || !candidate.selectable
        let subtitle: String?
        if already {
            subtitle = "已在通话中"
        } else if !candidate.selectable {
            subtitle = candidate.unselectableReason
        } else {
            subtitle = candidate.subtitle
        }
        row.configure(uid: candidate.uid, name: candidate.name, subtitle: subtitle, dimmed: blocked)
        row.accessoryType = already || (!blocked && picked.contains(candidate.uid)) ? .checkmark : .none
        row.tintColor = blocked ? theme.secondaryText : theme.accept
        row.selectionStyle = blocked ? .none : .default
        return row
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let uid = extraRows[indexPath.row]
            toggle(uid)
            if !candidatesCache.contains(where: { $0.uid == uid }) { query = ""; searchBar.text = "" }
            return
        }
        let candidate = candidatesCache[indexPath.row]
        guard !inCallCache.contains(candidate.uid), candidate.selectable else { return }
        toggle(candidate.uid)
    }

    /// 滚到底且还有下一页时追加取（§3.4）。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                   forRowAt indexPath: IndexPath) {
        guard provider != nil, indexPath.section == 1, nextCursor != nil, !isLoadingMore,
              indexPath.row >= candidatesCache.count - 3 else { return }
        loadPage(reset: false)
    }
}
/// 选人页的一行：头像 + 名字 / 副标题两行 + 系统勾选标记（与 Web / Android 同形）。
private final class IMInviteCandidateCell: UITableViewCell {
    static let reuseID = "invite-candidate"
    private static let avatarSize: CGFloat = 32

    private let avatar = IMAvatarDiscView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let theme = IMKitTheme.current
        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = theme.primaryText
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = theme.secondaryText
        let texts = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 2
        avatar.translatesAutoresizingMaskIntoConstraints = false
        texts.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatar)
        contentView.addSubview(texts)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            texts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            texts.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    func configure(uid: String, name: String, subtitle: String?, dimmed: Bool) {
        avatar.apply(key: uid, name: name, size: Self.avatarSize)
        nameLabel.text = name
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        contentView.alpha = dimmed ? 0.45 : 1
    }
}
#endif
