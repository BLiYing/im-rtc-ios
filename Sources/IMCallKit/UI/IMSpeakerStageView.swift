#if canImport(UIKit)
import UIKit

/**
 演讲者视图：**主画面 + 底部一条 4 格**（MEETING_ROOM_DESIGN §4.4）。

 # M2 只做「钉住」这一半

 没钉住时**不会**进这一屏——「自动跟着主讲人切主画面」移出了 M2（§2.3）。
 理由是主画面高频切 h 层、每切一次都要等关键帧，几个人抢话时主画面每隔几秒糊一下；
 而钉住是用户明确指定的，切换频率由他自己决定。右上角那个「画廊 / 演讲者」切换按钮
 也随之不做：进出这一屏的唯一途径就是双击格子与点 📌。

 # 层

 主画面报 `h`，底部条报 `l`。被换下主画面的人留在底部条里，所以换回来时先有 l 层画面、
 再升到 h，不会从黑屏开始。
 */
final class IMSpeakerStageView: UIView {

    /// 主画面的宿主。格子由调用方塞进来（它们按 uid 复用，不能重建）。
    private let mainHost = UIView()
    private let strip = UIStackView()
    /// 左上角的 📌，**点它取消钉住**。
    let unpinButton = UIButton(type: .system)

    private var mainTile: UIView?
    private var mainConstraints: [NSLayoutConstraint] = []
    /// 底部条每一格的宽度约束。换一批格子时要先撤掉，否则约束会越积越多。
    private var stripConstraints: [NSLayoutConstraint] = []

    /**
     底部条每格的边长。**正方形**，与 Android 的 `dp(84)` / Web 的 `gridAutoColumns: 84px` 同值。

     必须显式给宽：`UIStackView` 的 `fillEqually` 只管「彼此一样宽」，
     而这条 stack 自己没有宽度约束（左右是不等式 + 居中），格子又没有 intrinsic size——
     没人定宽的结果是它们被压成又窄又高的竖条，画面左右两条黑边、名字牌直接被挤没
     （2026-09-18 真机）。
     */
    private static let stripTileSide: CGFloat = 84

    override init(frame: CGRect) {
        super.init(frame: frame)
        let theme = IMKitTheme.current

        mainHost.backgroundColor = theme.tileBackground
        mainHost.layer.cornerRadius = theme.tileCornerRadius
        mainHost.clipsToBounds = true
        mainHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainHost)

        strip.axis = .horizontal
        strip.distribution = .fillEqually
        strip.spacing = theme.tileGap
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)

        unpinButton.setTitle("📌 取消钉住", for: .normal)
        unpinButton.titleLabel?.font = .systemFont(ofSize: 12)
        unpinButton.setTitleColor(theme.primaryText, for: .normal)
        unpinButton.backgroundColor = theme.pillBackground
        unpinButton.layer.cornerRadius = 14
        unpinButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        unpinButton.accessibilityLabel = "取消钉住"
        unpinButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unpinButton)

        NSLayoutConstraint.activate([
            mainHost.topAnchor.constraint(equalTo: topAnchor),
            mainHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainHost.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -theme.tileGap),
            strip.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            strip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            strip.centerXAnchor.constraint(equalTo: centerXAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.stripTileSide),
            unpinButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            unpinButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            unpinButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /// setMain 换主画面。**同一个格子不重挂**：重挂会让媒体层的渲染视图跟着重来，画面会闪。
    func setMain(_ tile: UIView) {
        guard mainTile !== tile else { return }
        NSLayoutConstraint.deactivate(mainConstraints)
        mainTile?.removeFromSuperview()
        // 先离开原来的容器（它上一刻还在画廊里）：跨层级残留的约束会被 UIKit 静默丢掉，
        // 只在控制台留一条警告，而画面已经没了。
        tile.removeFromSuperview()
        tile.translatesAutoresizingMaskIntoConstraints = false
        mainHost.addSubview(tile)
        mainConstraints = tile.imPinEdges(to: mainHost)
        mainTile = tile
        bringSubviewToFront(unpinButton)
    }

    /// setStrip 换底部条。顺序变了才重建——每次都重建同样会让画面闪。
    func setStrip(_ tiles: [UIView]) {
        guard strip.arrangedSubviews != tiles else { return }
        NSLayoutConstraint.deactivate(stripConstraints)
        stripConstraints = []
        for view in strip.arrangedSubviews {
            strip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for tile in tiles {
            tile.removeFromSuperview()
            strip.addArrangedSubview(tile)
            // 见 stripTileSide：不给宽就会被压成竖条。
            let width = tile.widthAnchor.constraint(equalToConstant: Self.stripTileSide)
            width.isActive = true
            stripConstraints.append(width)
        }
    }

    /// detach 把格子交还出去（回画廊之前调），否则它们还挂在这里，画廊摆不上。
    func detach() {
        NSLayoutConstraint.deactivate(mainConstraints)
        mainConstraints = []
        mainTile?.removeFromSuperview()
        mainTile = nil
        setStrip([])
    }
}
#endif
