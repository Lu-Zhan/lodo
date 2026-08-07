import SwiftUI
import SwiftData
import LodoCore

/// 并行时间线:参考日历当日视图,一个项目一列、按时间比例摆色块,不同项目用
/// 浅色透明色区分。同项目内部时间理论上不重叠(产品假设,不做校验),跨项目
/// 可以并行,所以并排成列。用 GeometryReader 只算列宽(不用来自绘,内容仍是
/// 原生 Divider/Text/RoundedRectangle 摆放)——这是继 ContactGraphView 之后第二个
/// 被明确批准的"非纯标准控件直接拼装"例外。
///
/// 竖直定位不用 `.offset(y:)`:ScrollView 按子视图"变换前"的自身 frame 判断要不要
/// 渲染,offset 偏得远的内容会被当成"不在可视区域"直接不渲染(不是位置错、是
/// 整个消失)。改用 `PositionedContent`——用一个跟偏移量等高的占位空间把内容
/// 真正"推"下去,ScrollView 看到的是内容自身的真实 frame,不存在这个问题。
private struct PositionedContent<Content: View>: View {
    let y: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(y, 0))
            content()
        }
    }
}

struct ProjectTimelineView: View {
    private static let unclassifiedKey = "未分类"
    private static let gutterWidth: CGFloat = 44
    private static let minColumnWidth: CGFloat = 64
    private static let pointsPerMinute: CGFloat = 1.2

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TaskItem.remindAt) private var allTasks: [TaskItem]

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var showDatePicker = false
    @State private var editTask: TaskItem?

    private var dayTasks: [TaskItem] {
        allTasks.filter { Calendar.current.isDate($0.remindAt, inSameDayAs: day) && !$0.allDay }
    }

    private var allDayTasks: [TaskItem] {
        allTasks.filter { Calendar.current.isDate($0.remindAt, inSameDayAs: day) && $0.allDay }
    }

    /// 06:00–24:00 默认窗口,实际事项(含时长)超出时按整点向外扩展,不裁剪数据。
    private var range: (start: Date, end: Date) {
        let cal = Calendar.current
        var start = cal.date(bySettingHour: 6, minute: 0, second: 0, of: day) ?? day
        var end = day.addingTimeInterval(86400)  // 次日 00:00,即当天 24:00
        for task in dayTasks {
            start = min(start, task.remindAt)
            let taskEnd = task.remindAt.addingTimeInterval(
                TimeInterval(max(task.durationMinutes, 15) * 60))
            end = max(end, taskEnd)
        }
        start = cal.date(bySettingHour: cal.component(.hour, from: start), minute: 0, second: 0,
                          of: start) ?? start
        if end > day.addingTimeInterval(86400) {
            // 只有真的超出默认窗口才向外扩到整点(否则 end 就精确停在次日 00:00,
            // 不需要再多加一小时)。
            let endHourStart = cal.date(bySettingHour: cal.component(.hour, from: end), minute: 0,
                                         second: 0, of: end) ?? end
            end = cal.date(byAdding: .hour, value: 1, to: endHourStart) ?? end
        }
        return (start, end)
    }

    /// 不同项目各一列(含"未分类"),按名称排序,"未分类"殿后,和 ProjectListView 一致。
    private var columns: [(name: String, tasks: [TaskItem])] {
        let dict = Dictionary(grouping: dayTasks) { task -> String in
            let trimmed = task.project?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? Self.unclassifiedKey : trimmed
        }
        var named = dict.filter { $0.key != Self.unclassifiedKey }
            .map { (name: $0.key, tasks: $0.value) }
            .sorted { $0.name < $1.name }
        if let bucket = dict[Self.unclassifiedKey], !bucket.isEmpty {
            named.append((Self.unclassifiedKey, bucket))
        }
        return named
    }

    private var contentHeight: CGFloat {
        CGFloat(minutes(range.start, range.end)) * Self.pointsPerMinute
    }

    private var hours: [Date] {
        var result: [Date] = []
        var cursor = range.start
        while cursor <= range.end {
            result.append(cursor)
            cursor = Calendar.current.date(byAdding: .hour, value: 1, to: cursor) ?? range.end
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dayNavBar
                if !allDayTasks.isEmpty {
                    allDayStrip
                }
                Divider()
                if dayTasks.isEmpty && allDayTasks.isEmpty {
                    ContentUnavailableView("这天没有安排", systemImage: "calendar")
                        .frame(maxHeight: .infinity)
                } else {
                    timelineBody
                }
            }
            .navigationTitle("并行时间线")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $editTask) { task in
                TaskEditView(existing: task, parsed: nil, attachment: task.attachment) { parsed in
                    TaskActions.apply(parsed, to: task, context: context)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }

    // MARK: - 顶部日期导航

    private var dayNavBar: some View {
        HStack {
            Button {
                day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Button(TaskItem.format(day).components(separatedBy: " ").first ?? "今天") {
                showDatePicker = true
            }
            .popover(isPresented: $showDatePicker) {
                DatePicker("选择日期", selection: Binding(
                    get: { day },
                    set: { day = Calendar.current.startOfDay(for: $0) }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .frame(minWidth: 300)
            }
            Spacer()
            Button {
                day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 全天事项:横向 chip 带,不参与竖直定位(全天没有真正的时间区间)。
    private var allDayStrip: some View {
        HorizontalChipRow {
            ForEach(allDayTasks) { task in
                Button(task.title) { editTask = task }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(ProjectColor.color(for: task.project))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - 时间线主体

    private var timelineBody: some View {
        GeometryReader { geo in
            let columnWidth = max(
                Self.minColumnWidth,
                (geo.size.width - Self.gutterWidth) / CGFloat(max(columns.count, 1)))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.gutterWidth)
                    ForEach(columns, id: \.name) { column in
                        columnHeader(column.name).frame(width: columnWidth)
                    }
                }
                Divider()
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter.frame(width: Self.gutterWidth, height: contentHeight)
                        ForEach(columns, id: \.name) { column in
                            columnBody(column).frame(width: columnWidth, height: contentHeight)
                        }
                    }
                }
            }
        }
    }

    private func columnHeader(_ project: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ProjectColor.color(for: project == Self.unclassifiedKey ? nil : project))
                .frame(width: 6, height: 6)
            Text(project).font(.caption.bold()).lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private var hourGutter: some View {
        ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.self) { hour in
                PositionedContent(y: CGFloat(minutes(range.start, hour)) * Self.pointsPerMinute - 6) {
                    Text(hour.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func columnBody(_ column: (name: String, tasks: [TaskItem])) -> some View {
        let color = ProjectColor.color(for: column.name == Self.unclassifiedKey ? nil : column.name)
        return ZStack(alignment: .topLeading) {
            color.opacity(0.06)
            ForEach(hours, id: \.self) { hour in
                PositionedContent(y: CGFloat(minutes(range.start, hour)) * Self.pointsPerMinute) {
                    Divider()
                }
            }
            ForEach(column.tasks) { task in
                taskBlock(task, color: color)
            }
        }
    }

    @ViewBuilder
    private func taskBlock(_ task: TaskItem, color: Color) -> some View {
        let y = CGFloat(minutes(range.start, task.remindAt)) * Self.pointsPerMinute
        if task.durationMinutes > 0 {
            let h = max(CGFloat(task.durationMinutes) * Self.pointsPerMinute, 22)
            PositionedContent(y: y) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.caption.bold()).lineLimit(h > 34 ? 2 : 1)
                    if h > 34 {
                        Text(TaskItem.format(task.remindAt))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: h, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: DesignMetrics.chipRadius)
                        .fill(color.opacity(task.status == .done ? 0.15 : 0.35)))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignMetrics.chipRadius)
                        .strokeBorder(color.opacity(0.6)))
                .opacity(task.status == .done ? 0.55 : 1)
                .strikethrough(task.status == .done)
                .onTapGesture { editTask = task }
            }
        } else {
            // 零时长事项(纯时间点提醒)没有真正的处理区间,画成一个小圆点标记
            // 而不是高度为 0 的色块。
            PositionedContent(y: y - 6) {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(task.title).font(.caption2).lineLimit(1)
                        .strikethrough(task.status == .done)
                        .opacity(task.status == .done ? 0.55 : 1)
                }
                .onTapGesture { editTask = task }
            }
        }
    }

    private func minutes(_ from: Date, _ to: Date) -> Int {
        Int(to.timeIntervalSince(from) / 60)
    }
}
