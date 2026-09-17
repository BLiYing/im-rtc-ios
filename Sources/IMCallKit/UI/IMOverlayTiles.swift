#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 通话页的两个协作对象（CONVENTIONS §2：VC 膨胀抽协作对象，不是抽私有方法进 extension）：
 · `IMRemoteTiles`：远端格子的缓存、挂载 / 卸载、层上界上报去重；
 · `IMFullStage`：把某个格子钉成全屏、摘下来。
 两者都只管「格子在哪、收多大的流」，不认版式——版式仍由 `IMCallOverlayViewController` 决定。
 */

/// 远端格子，按 uid 复用。**不每次重建**：重建会让媒体层挂上去的渲染视图跟着重来，画面会闪。
final class IMRemoteTiles {
    private let controller: IMCallController
    private var tiles: [String: IMVideoTileView] = [:]
    private var reportedLayers: [String: String] = [:]
    /// 上一轮每个人有没有画面。**只用来判「他的轨道刚到」**，见 `report(_:layer:hasVideo:)`。
    private var lastHasVideo: [String: Bool] = [:]

    init(controller: IMCallController) {
        self.controller = controller
    }

    /// 取某人的格子，没有就建一个并挂上他的远端画面。
    func tile(for uid: String) -> IMVideoTileView {
        if let tile = tiles[uid] { return tile }
        let tile = IMVideoTileView()
        tiles[uid] = tile
        controller.attachView(uid, to: tile.renderView)
        return tile
    }

    /// retire 收掉不再需要的格子。卸载要成对：不摘的话解码器还占着（CONVENTIONS §7）。
    func retire(keeping wanted: Set<String>) {
        for (uid, tile) in tiles where !wanted.contains(uid) {
            controller.attachView(uid, to: nil)
            tile.removeFromSuperview()
            tiles[uid] = nil
            reportedLayers[uid] = nil
            lastHasVideo[uid] = nil
        }
    }

    /**
     格子大小变了就重报层上界，同一个值不重复发。**这是省带宽的关键一步**。

     `hasVideo` 不是用来决定报不报的，是用来**把去重表划掉**的：
     `setRemoteLayer` 按 uid 找他当前的视频轨道再发帧，而**人先进来、轨道后到是常态**
     （`onUserEnter` 一到就摆格子并报层，那一次引擎手里还没有他的轨道，什么都没发出去），
     可去重表已经记下「报过 l 了」——之后除非格数变化就再也不会重发，
     服务端一直按默认的 `m` 给他下发，九宫格里八个小格子每格都收半高清。
     症状只是「画面卡、掉帧」，一条报错都没有。
     `hasVideo` 从 false 翻成 true 正是「他的轨道到了」那一刻，借它重报一次。
     （Android 走 `IMCallKit.invalidateReportedLayer`，Web 把 `hasVideo` 放进 effect 依赖，同一条。）
    */
    func report(_ uid: String, layer: String, hasVideo: Bool) {
        let trackJustArrived = hasVideo && lastHasVideo[uid] != true
        lastHasVideo[uid] = hasVideo
        if trackJustArrived { reportedLayers[uid] = nil }
        guard reportedLayers[uid] != layer else { return }
        reportedLayers[uid] = layer
        controller.reportLayer(uid, layer)
    }
}

/// 全屏画面的宿主：把某个格子钉满 `host`，摘下来时恢复圆角。
final class IMFullStage {
    private let host: UIView
    private(set) var tile: IMVideoTileView?
    private var constraints: [NSLayoutConstraint] = []

    init(host: UIView) {
        self.host = host
    }

    func pin(_ tile: IMVideoTileView) {
        guard self.tile !== tile else { return }
        unpin()
        // 先离开原来的容器（互换时它正待在小窗里）：跨层级残留的约束会被 UIKit 静默丢掉，
        // 只在控制台留一条警告，而画面已经没了。
        tile.removeFromSuperview()
        tile.layer.cornerRadius = 0
        tile.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(tile)
        constraints = [
            tile.topAnchor.constraint(equalTo: host.topAnchor),
            tile.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tile.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        self.tile = tile
    }

    func unpin() {
        NSLayoutConstraint.deactivate(constraints)
        constraints = []
        if let tile, tile.superview === host { tile.removeFromSuperview() }
        tile?.layer.cornerRadius = IMKitTheme.current.tileCornerRadius
        tile = nil
    }
}
#endif
