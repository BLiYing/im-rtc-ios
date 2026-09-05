#if canImport(UIKit)
import UIKit

/*
 九宫格容器。

 # 为什么用嵌套 UIStackView 而不是自己算 frame

 第一版按 `imGridDimensions` 算出行列，再用 `gridView.bounds.width * 比例` 当约束常量——
 **那时候 `bounds` 还是 zero**（约束是在布局之前建的），于是所有格子都堆在左上角，
 缩成一个小胶囊。实测截图里就是那个样子。

 嵌套 StackView 把「等分」交给布局系统：外层竖着放每一行，每行内部横着等分。
 行列数变了只需要重建 stack 的 arrangedSubviews，不碰任何数字。
 */
final class IMCallGridView: UIView {

    private let rowsStack = UIStackView()
    /// 当前摆着的格子，按加入顺序。
    private(set) var tiles: [IMVideoTileView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowsStack.axis = .vertical
        rowsStack.distribution = .fillEqually
        rowsStack.spacing = IMKitTheme.current.tileGap
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)
        /*
         **竖直方向的两条边不能用 required 优先级钉死。**

         钉死的话，本视图的高度就被 `rowsStack` 的固有高度（= 格子里那几个 label
         加起来，几十点）**强制**决定了；外层 stack 想把剩余空间给它，
         那条低优先级的 hugging 根本抢不过一条 required 约束。
         实测症状：整页内容缩在顶部一条细带里，下面空一大片。

         降到 999 之后，外层需要拉伸时可以压过它，不需要时它仍然贴边。
        */
        let top = rowsStack.topAnchor.constraint(equalTo: topAnchor)
        let bottom = rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        top.priority = .defaultHigh
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            top, bottom,
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // 本视图愿意被拉伸：外层 stack 靠这个把剩余空间分给网格。
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /**
     layout 把给定的格子摆成尽量接近正方形的网格。

     **只在格子集合变了时重建**：每次状态更新都重建的话，媒体层挂在
     `renderView` 上的渲染视图会跟着重来，画面会闪。
     */
    func layout(_ wanted: [IMVideoTileView]) {
        guard wanted != tiles else { return }
        tiles = wanted
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let dims = imGridDimensions(wanted.count)
        let gap = IMKitTheme.current.tileGap
        for row in 0..<dims.rows {
            let slice = wanted.dropFirst(row * dims.columns).prefix(dims.columns)
            let rowStack = UIStackView(arrangedSubviews: Array(slice))
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = gap
            // 最后一行可能没排满：补一个透明占位，**否则那两个格子会被拉宽**，
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
