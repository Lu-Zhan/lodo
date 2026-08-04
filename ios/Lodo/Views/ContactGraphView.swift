import SwiftUI
import SwiftData
import LodoCore

/// 人脉关系的节点连线可视化——记忆 tab 筛选出"联系人"后左上角的入口。
/// 这是仓库里唯一一处经用户确认的自绘 UI 例外(Canvas):项目铁律是 iOS UI
/// 只用 SwiftUI 系统控件、不自绘,但真正的节点连线图没有系统控件能做。
/// 不做力导向仿真,用确定性的圆形布局(ContactGraphLayout.circlePositions,
/// LodoCore 的纯逻辑,可单测)——节点数量在这个 app 的真实场景下不会很大,
/// 圆形布局每次打开位置一致,不需要引入物理仿真的收敛/调参成本。
struct ContactGraphView: View {
    @Query private var allItems: [MemoryItem]
    @Query private var edges: [ContactRelationship]

    @State private var avatarImages: [UUID: Image] = [:]
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var zoomScale: CGFloat = 1
    @State private var baseZoomScale: CGFloat = 1
    @State private var selectedContact: MemoryItem?

    private let nodeRadius: CGFloat = 28
    /// 点击命中判定比节点视觉半径稍大一点,手指点不准也能点中。
    private let tapTolerance: CGFloat = 10

    private var contacts: [MemoryItem] {
        allItems.filter { $0.isContact }
    }

    var body: some View {
        Group {
            if contacts.isEmpty {
                ContentUnavailableView(
                    "还没有联系人", systemImage: "person.2",
                    description: Text("记忆列表里点右上角「+」记一位联系人。"))
            } else {
                GeometryReader { geo in
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let radius = min(geo.size.width, geo.size.height) / 2 - nodeRadius - 24
                    let positions = nodePositions(center: center, radius: radius)

                    Canvas { context, _ in
                        drawEdges(in: &context, positions: positions, center: center)
                        drawNodes(in: &context, positions: positions, center: center)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            handleTap(at: value.location, positions: positions, center: center)
                        }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                panOffset = CGSize(
                                    width: dragStartOffset.width + value.translation.width,
                                    height: dragStartOffset.height + value.translation.height)
                            }
                            .onEnded { _ in dragStartOffset = panOffset }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in zoomScale = max(0.5, min(3, baseZoomScale * value)) }
                            .onEnded { _ in baseZoomScale = zoomScale }
                    )
                }
            }
        }
        .navigationTitle("关系图谱")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $selectedContact) { contact in
            ContactDetailView(item: contact)
        }
        .onAppear(perform: loadAvatars)
    }

    // MARK: - 坐标变换(以画布中心为锚点缩放,再叠加拖拽平移;只在这一处转换,
    // 绘制与命中测试共用,避免两边算法不一致导致"画的和能点的对不上"。)

    private func nodePositions(center: CGPoint, radius: CGFloat) -> [UUID: CGPoint] {
        let logical = ContactGraphLayout.circlePositions(
            count: contacts.count, radius: radius,
            center: (x: center.x, y: center.y))
        var result: [UUID: CGPoint] = [:]
        for (contact, point) in zip(contacts, logical) {
            result[contact.uuid] = CGPoint(x: point.x, y: point.y)
        }
        return result
    }

    private func screenPoint(_ logical: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + (logical.x - center.x) * zoomScale + panOffset.width,
            y: center.y + (logical.y - center.y) * zoomScale + panOffset.height)
    }

    private func handleTap(at location: CGPoint, positions: [UUID: CGPoint], center: CGPoint) {
        for contact in contacts {
            guard let logical = positions[contact.uuid] else { continue }
            let screen = screenPoint(logical, center: center)
            if hypot(screen.x - location.x, screen.y - location.y) <= nodeRadius + tapTolerance {
                selectedContact = contact
                return
            }
        }
    }

    // MARK: - 绘制

    private func drawEdges(in context: inout GraphicsContext, positions: [UUID: CGPoint], center: CGPoint) {
        for edge in edges {
            guard let a = positions[edge.memoryUUIDA], let b = positions[edge.memoryUUIDB] else { continue }
            var path = Path()
            path.move(to: screenPoint(a, center: center))
            path.addLine(to: screenPoint(b, center: center))
            context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1.5)
        }
    }

    private func drawNodes(in context: inout GraphicsContext, positions: [UUID: CGPoint], center: CGPoint) {
        for contact in contacts {
            guard let logical = positions[contact.uuid] else { continue }
            let point = screenPoint(logical, center: center)
            let rect = CGRect(
                x: point.x - nodeRadius, y: point.y - nodeRadius,
                width: nodeRadius * 2, height: nodeRadius * 2)

            if let avatar = avatarImages[contact.uuid] {
                // drawLayer 开一个独立子上下文,裁剪只影响这一次绘制,不会
                // "泄漏"到下一个节点或下面的文字标签。
                context.drawLayer { layer in
                    layer.clip(to: Path(ellipseIn: rect))
                    layer.draw(avatar, in: rect)
                }
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(.accentColor.opacity(0.85)))
                context.draw(
                    Text(initials(for: contact)).font(.footnote.bold()).foregroundStyle(.white),
                    at: point)
            }

            let label = contact.title.isEmpty ? "(未命名)" : contact.title
            context.draw(
                Text(label).font(.caption2),
                at: CGPoint(x: point.x, y: point.y + nodeRadius + 12))
        }
    }

    private func initials(for contact: MemoryItem) -> String {
        let source = contact.title.isEmpty ? (contact.contactNickname ?? "") : contact.title
        guard let first = source.first else { return "?" }
        return String(first).uppercased()
    }

    private func loadAvatars() {
        for contact in contacts where avatarImages[contact.uuid] == nil {
            guard let url = MemoryPipeline.contactAvatarURL(of: contact),
                  let data = try? Data(contentsOf: url),
                  let image = platformImage(from: data) else { continue }
            avatarImages[contact.uuid] = image
        }
    }
}
