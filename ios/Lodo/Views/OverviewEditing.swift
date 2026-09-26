import SwiftUI
import UniformTypeIdentifiers
import LodoCore

// 总览页的就地编辑,参考 iOS 主屏幕编辑小组件:右上角「编辑」进入后卡片轻轻
// 抖动,左上角「−」移除,拖动卡片调整位置,拖右下角的手柄(或点一下)放大/缩小,
// 「+」把移除掉的小组件加回来。改动即时写进 `AppSettings.overviewLayoutKey`。
//
// 抖动/拖动/手柄都以**叠加层**的形式挂上去,卡片本体的视图身份不变——进出编辑态
// 不会让卡片里的状态(时钟、倒计时)重建。

/// 编辑态下包在每张卡外面的一层。
struct OverviewEditableWidget<Content: View>: View {
    let item: OverviewWidgetItem
    /// 抖动相位错开用,相邻两张不同步才像主屏幕。
    let seed: Int
    let isEditing: Bool
    @Binding var dragging: OverviewWidgetKind?
    let onRemove: () -> Void
    let onResize: (OverviewWidgetSize) -> Void
    let onMove: (OverviewWidgetKind, OverviewWidgetKind) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .overlay {
                // 编辑态盖一层透明板:吃掉卡片内的点击(不误完成任务、不跳页),
                // 同时是拖动的起点。
                if isEditing {
                    RoundedRectangle(cornerRadius: DesignMetrics.widgetRadius, style: .continuous)
                        .fill(Color.white.opacity(0.001))
                        .onDrag {
                            dragging = item.kind
                            Haptics.impact(.light)
                            return NSItemProvider(object: item.kind.rawValue as NSString)
                        } preview: {
                            content()
                                .frame(width: item.size == .small ? 170 : 340)
                                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.widgetRadius,
                                                            style: .continuous))
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if isEditing {
                    removeBadge
                        .offset(x: -8, y: -8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditing, item.kind.allowedSizes.count > 1 {
                    OverviewResizeHandle(size: item.size, onResize: onResize)
                        .offset(x: 6, y: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .modifier(OverviewJiggle(active: isEditing && dragging != item.kind, seed: seed,
                                     amplitude: item.size == .small ? 1.2 : 0.5))
            .opacity(dragging == item.kind ? 0.35 : 1)
            .onDrop(of: [.text], delegate: OverviewReorderDrop(
                target: item.kind, dragging: $dragging, onMove: onMove))
            .accessibilityAction(named: "移除") { if isEditing { onRemove() } }
    }

    private var removeBadge: some View {
        Button(action: onRemove) {
            Image(systemName: "minus")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .glassBackground(Circle())
        }
        .pressable()
        .hitTarget(visualSize: 28)
        .accessibilityLabel(Text("移除") + Text(" ") + Text(LocalizedStringKey(item.kind.title)))
    }
}

/// 右下角的缩放手柄:往外(右)拖放大、往里(左)拖缩小,点一下在两档之间切换。
/// 跨过阈值就立刻换尺寸,手指还没松开卡片已经变了,和主屏幕一样所见即所得。
struct OverviewResizeHandle: View {
    let size: OverviewWidgetSize
    let onResize: (OverviewWidgetSize) -> Void
    @State private var changedDuringDrag = false

    private static let threshold: CGFloat = 36

    var body: some View {
        Image(systemName: size == .small ? "arrow.up.left.and.arrow.down.right"
                                         : "arrow.down.right.and.arrow.up.left")
            .font(.footnote.weight(.bold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .glassBackground(Circle())
            .hitTarget(visualSize: 30)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.translation.width
                        if dx > Self.threshold, size == .small { resize(.large) }
                        else if dx < -Self.threshold, size == .large { resize(.small) }
                    }
                    .onEnded { value in
                        let moved = abs(value.translation.width) + abs(value.translation.height)
                        if !changedDuringDrag, moved < 8 { resize(size == .small ? .large : .small) }
                        changedDuringDrag = false
                    })
            .accessibilityElement()
            .accessibilityLabel(size == .small ? "放大" : "缩小")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onResize(size == .small ? .large : .small) }
    }

    private func resize(_ target: OverviewWidgetSize) {
        changedDuringDrag = true
        Haptics.tick()
        onResize(target)
    }
}

/// 主屏幕式的抖动。TimelineView 一直在,只是不抖时暂停——进出编辑态不换视图身份。
struct OverviewJiggle: ViewModifier {
    let active: Bool
    let seed: Int
    let amplitude: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let running = active && !reduceMotion
        TimelineView(.animation(paused: !running)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = running ? sin(t * 2 * .pi * 3.4 + Double(seed) * 1.7) * amplitude : 0
            content.rotationEffect(.degrees(angle))
        }
    }
}

/// 拖着一张卡经过另一张时就地换位(实时让位,不用等松手)。
struct OverviewReorderDrop: DropDelegate {
    let target: OverviewWidgetKind
    @Binding var dragging: OverviewWidgetKind?
    let onMove: (OverviewWidgetKind, OverviewWidgetKind) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        Haptics.tick()
        withAnimation(.lodoAware(.snappy)) { onMove(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// 挂在整页上兜底:拖到卡片之间的缝里松手时也要把"正在拖"清掉。
struct OverviewDragReset: DropDelegate {
    @Binding var dragging: OverviewWidgetKind?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// 「+」:移除掉的小组件在这里加回来(加到最后面),以及恢复默认布局。
struct OverviewWidgetGallery: View {
    @Binding var layout: OverviewLayout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lodoAccent) private var accent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if layout.hiddenKinds.isEmpty {
                        Text("所有小组件都已在总览里")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(layout.hiddenKinds, id: \.self) { kind in
                        Button {
                            withAnimation(.lodoAware(.snappy)) { layout.add(kind) }
                            Haptics.success()
                        } label: {
                            HStack(spacing: 10) {
                                Label(LocalizedStringKey(kind.title), systemImage: kind.systemImage)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 4)
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(accent.accent)
                            }
                        }
                    }
                } footer: {
                    Text("在总览里点「编辑」:拖动卡片调整位置,拖右下角的手柄放大或缩小。")
                }
                Section {
                    Button("恢复默认布局") {
                        withAnimation(.lodoAware(.snappy)) { layout = .default }
                    }
                    .disabled(layout == .default)
                }
            }
            .navigationTitle("添加小组件")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // sheet 是独立呈现宿主,不继承根上的 tint(同 SettingsView)。
        .tint(accent.accent)
    }
}
