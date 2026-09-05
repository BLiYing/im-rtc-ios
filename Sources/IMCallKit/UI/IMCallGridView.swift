#if canImport(UIKit)
import UIKit

/*
 九宫格容器。

 # 格子恒为正方形

 原先外层竖 stack + 内层横 stack 都是 `fillEqually`，格子于是**吃满整块区域**——
 竖屏手机上两个人就是两条又高又窄的长条，画面被拉伸得很难看（真机实测反馈）。

 现在改成：先按容器形状与人数算出行列（`imGridDimensions`），再算出
 **正方形格子的边长** `min(按列分到的宽, 按行分到的高)`，把 stack 整体钉成
 `列×边长 × 行×边长` 并**居中**。stack 内部仍然 `fillEqually`，
 于是每格拿到的正好是那个正方形。

 # 为什么用嵌套 UIStackView 而不是自己算 frame

 第一版按行列算出比例再乘 `gridView.bounds.width` 当约束常量——
 **那时候 `bounds` 还是 zero**（约束是在布局之前建的），于是所有格子都堆在左上角，
 缩成一个小胶囊。现在的尺寸计算放在 `layoutSubviews` 里，那时 `bounds` 才是真的。
 */
final class IMCallGridView: UIView {

    private let rowsStack = UIStackView()
    /// 当前摆着的格子，按加入顺序。
    private(set) var tiles: [IMVideoTileView] = []

    /// 当前已经摆出来的行列。变了才重建 arrangedSubviews。
    private var arranged = IMGridDimensions(columns: 0, rows: 0)
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowsStack.axis = .vertical
        rowsStack.distribution = .fillEqually
        rowsStack.spacing = IMKitTheme.current.tileGap
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

        widthConstraint = rowsStack.widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = rowsStack.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            rowsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            rowsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint, heightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /**
     layout 换一批格子。

     **只在格子集合变了时记账**：每次状态更新都重建的话，媒体层挂在
     `renderView` 上的渲染视图会跟着重来，画面会闪。
     真正的摆放在 `layoutSubviews` 里做——那时才知道容器多大。
     */
    func layout(_ wanted: [IMVideoTileView]) {
        guard wanted != tiles else { return }
        tiles = wanted
        arranged = IMGridDimensions(columns: 0, rows: 0) // 强制重建
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, !tiles.isEmpty else {
            applySize(width: 0, height: 0)
            return
        }

        let gap = IMKitTheme.current.tileGap
        let dims = imGridDimensions(tiles.count, aspect: bounds.width / bounds.height)
        if dims != arranged {
            arranged = dims
            rebuild(dims, gap: gap)
        }

        /*
         **只有一格时铺满，不做正方形。**

         1v1 是「对端满屏 + 本端小窗」（草图 §03），把唯一那一格缩成正方形
         等于在上下留两条黑边——正方形是为了「多格之间不互相拉伸」，
         一格的时候没有别人可比。
        */
        guard tiles.count > 1 else {
            applySize(width: bounds.width, height: bounds.height)
            return
        }

        // 正方形边长：宽高两边都要放得下，取小的那个。
        let cellWidth = (bounds.width - CGFloat(dims.columns - 1) * gap) / CGFloat(dims.columns)
        let cellHeight = (bounds.height - CGFloat(dims.rows - 1) * gap) / CGFloat(dims.rows)
        let side = max(min(cellWidth, cellHeight), 0)
        applySize(width: side * CGFloat(dims.columns) + CGFloat(dims.columns - 1) * gap,
                  height: side * CGFloat(dims.rows) + CGFloat(dims.rows - 1) * gap)
    }

    /// applySize 改约束常量。**只在真的变了时改**——否则每改一次都会再触发一轮布局，
    /// 变成死循环。
    private func applySize(width: CGFloat, height: CGFloat) {
        let changed = abs(widthConstraint.constant - width) > 0.5
            || abs(heightConstraint.constant - height) > 0.5
        guard changed else { return }
        widthConstraint.constant = width
        heightConstraint.constant = height
    }

    private func rebuild(_ dims: IMGridDimensions, gap: CGFloat) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in 0..<dims.rows {
            let slice = tiles.dropFirst(row * dims.columns).prefix(dims.columns)
            let rowStack = UIStackView(arrangedSubviews: Array(slice))
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = gap
            // 最后一行可能没排满：补一个透明占位，**否则那几个格子会被拉宽**，
            // 3 个人时第二行那一个会横跨整行，看着像出了 bug。
            let missing = dims.columns - slice.count
            if missing > 0 && !slice.isEmpty {
                for _ in 0..<missing { rowStack.addArrangedSubview(UIView()) }
            }
            rowsStack.addArrangedSubview(rowStack)
        }
    }
}
#endif
