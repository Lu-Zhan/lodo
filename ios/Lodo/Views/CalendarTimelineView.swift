import SwiftUI
import LodoCore

/// 日历页的时间轴视图(当日/三日/本周共用):顶部列头 + 全天行,下面是可纵向
/// 滚动的 24 小时网格,定时事件按 `CalendarTimelineLayout` 算好的位置摆成色块。
///
/// 这里**没有 Canvas、没有自绘路径**——网格线是 `Divider`/`Rectangle`,色块是
/// 圆角矩形 + Text,位置全靠 frame/offset。重叠分列等判断全在 LodoCore
/// (`CalendarTimelineLayout`,有单测),这里只按算好的列号摆放。
struct CalendarTimelineView: View {
    let days: [Date]
    let events: [CalendarEvent]
    /// 当日视图顶部额外给一条周条(点某天切到那天),同系统日历。
    var weekStripAnchor: Date?
    var onSelectDay: (Date) -> Void = { _ in }
    let onOpen: (CalendarEvent) -> Void
    let convertToTask: ((CalendarEvent) -> Void)?

    @Environment(\.lodoAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let calendar = Calendar.current
    private let gutterWidth: CGFloat = 44
    private var hourHeight: CGFloat { days.count >= 7 ? 48 : 56 }

    var body: some View {
        VStack(spacing: 0) {
            if let anchor = weekStripAnchor {
                weekStrip(anchor)
            } else {
                columnHeaders
            }
            allDayRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    grid
                        .padding(.vertical, 8)
                }
                .onAppear { scrollToWorkingHours(proxy) }
                .onChange(of: days) { _, _ in scrollToWorkingHours(proxy) }
            }
        }
    }

    // MARK: - 列头

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    dayNumber(day, selected: false)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 6)
    }

    /// 当日视图顶部的一周七天,选中那天实心。
    private func weekStrip(_ anchor: Date) -> some View {
        HStack(spacing: 0) {
            ForEach(CalendarWeek.days(containing: anchor, calendar: calendar), id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: anchor)
                Button {
                    onSelectDay(day)
                } label: {
                    VStack(spacing: 2) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        dayNumber(day, selected: selected)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .pressableCard()
                .accessibilityLabel(Text(day, format: .dateTime.month().day().weekday()))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func dayNumber(_ day: Date, selected: Bool) -> some View {
        let isToday = calendar.isDateInToday(day)
        return Text("\(calendar.component(.day, from: day))")
            .font(.body.weight(isToday || selected ? .semibold : .regular))
            .foregroundStyle(selected ? accent.onFill : (isToday ? accent.accent : .primary))
            .frame(width: 32, height: 32)
            .background {
                if selected {
                    Circle().fill(accent.fill)
                } else if isToday && weekStripAnchor == nil {
                    Circle().stroke(accent.accent.opacity(0.5), lineWidth: 1)
                }
            }
    }

    // MARK: - 全天行

    /// 每列最多摆两条,多出来的收成「+N」——全天行要是跟着事件数长高,
    /// 下面的时间轴就被挤没了。
    @ViewBuilder
    private var allDayRow: some View {
        let perDay = days.map { day in
            events.filter { $0.occurs(on: day, calendar: calendar) && $0.showsInAllDayRow(on: day, calendar: calendar) }
        }
        if perDay.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("全天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.trailing, 4)
                    .padding(.top, 3)
                ForEach(Array(days.enumerated()), id: \.element) { index, _ in
                    VStack(spacing: 2) {
                        ForEach(perDay[index].prefix(2), id: \.occurrenceKey) { event in
                            eventChip(event)
                        }
                        if perDay[index].count > 2 {
                            Text("+\(perDay[index].count - 2)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 1)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func eventChip(_ event: CalendarEvent) -> some View {
        Button {
            onOpen(event)
        } label: {
            Text(event.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(event.displayColor(accent).opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .pressableCard()
        .eventContextMenu(event, convertToTask: convertToTask)
    }

    // MARK: - 时间网格

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            hourLabels
            GeometryReader { proxy in
                let columnWidth = proxy.size.width / CGFloat(max(days.count, 1))
                ZStack(alignment: .topLeading) {
                    hourLines
                    // 列分隔线:一天一列时不画。
                    if days.count > 1 {
                        ForEach(1..<days.count, id: \.self) { index in
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 0.5, height: hourHeight * 24)
                                .offset(x: CGFloat(index) * columnWidth)
                        }
                    }
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        ForEach(CalendarTimelineLayout.layout(events, on: day, calendar: calendar),
                                id: \.event.occurrenceKey) { slot in
                            block(slot, columnWidth: columnWidth)
                                .offset(x: CGFloat(index) * columnWidth
                                            + columnWidth * CGFloat(slot.column) / CGFloat(slot.columnCount),
                                        y: y(minute: slot.startMinute))
                        }
                        if calendar.isDateInToday(day) {
                            nowLine(width: columnWidth)
                                .offset(x: CGFloat(index) * columnWidth)
                        }
                    }
                }
            }
            .frame(height: hourHeight * 24)
            .padding(.trailing, 6)
        }
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<25, id: \.self) { hour in
                Text(verbatim: String(format: "%02d:00", hour % 24))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: gutterWidth - 4, height: hour == 24 ? 0 : hourHeight, alignment: .topTrailing)
                    // 让文字竖直居中在整点线上。
                    .offset(y: -8)
                    .id(hour)
            }
        }
        .padding(.trailing, 4)
        .frame(height: hourHeight * 24, alignment: .top)
        .accessibilityHidden(true)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
            }
        }
    }

    private func block(_ slot: CalendarTimelineSlot, columnWidth: CGFloat) -> some View {
        let event = slot.event
        let color = event.displayColor(accent)
        let minutes = max(slot.endMinute - slot.startMinute, CalendarTimelineLayout.minimumDisplayMinutes)
        let height = max(y(minute: minutes) - 1, 16)
        let width = columnWidth / CGFloat(slot.columnCount) - 2
        return Button {
            onOpen(event)
        } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(height > 40 ? 2 : 1)
                    if height > 40 {
                        Text(event.start, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(width: max(width, 8), height: height, alignment: .topLeading)
            .background(color.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .pressableCard()
        .eventContextMenu(event, convertToTask: convertToTask)
        .accessibilityLabel(Text(event.accessibilityDescription))
    }

    /// 当前时刻那根红线。只在今天那一列画。
    private func nowLine(width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let minute = calendar.component(.hour, from: context.date) * 60
                + calendar.component(.minute, from: context.date)
            HStack(spacing: 0) {
                Circle().fill(LodoColor.critical).frame(width: 7, height: 7)
                Rectangle().fill(LodoColor.critical).frame(height: 1.5)
            }
            .frame(width: width)
            .offset(x: -3.5, y: y(minute: minute) - 3.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func y(minute: Int) -> CGFloat {
        CGFloat(minute) / 60 * hourHeight
    }

    /// 打开时滚到当前时刻前一小时附近(不是今天就滚到早上八点),
    /// 同系统日历——停在零点的话一屏全是空白的凌晨。
    private func scrollToWorkingHours(_ proxy: ScrollViewProxy) {
        let showsToday = days.contains { calendar.isDateInToday($0) }
        let hour = showsToday ? max(0, calendar.component(.hour, from: Date()) - 1) : 8
        DispatchQueue.main.async {
            proxy.scrollTo(min(hour, 20), anchor: .top)
        }
    }
}

// MARK: - 共用小件

extension CalendarEvent {
    /// 所属日历的颜色;取不到时退回强调色。
    func displayColor(_ accent: AccentPalette) -> Color {
        guard let color = calendarColor else { return accent.accent }
        return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    /// 给旁白读的一句:标题、时间、所属日历。
    var accessibilityDescription: String {
        let time = isAllDay
            ? String(localized: "全天")
            : "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        return [title, time, calendarTitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension View {
    /// 长按一条事件:「转为任务」(认领成 lodo 任务,见 CalendarSync.importEvent)。
    /// 只在写开关开着时给(convertToTask 非 nil),双向整套都由那个开关门控。
    @ViewBuilder
    func eventContextMenu(_ event: CalendarEvent, convertToTask: ((CalendarEvent) -> Void)?) -> some View {
        if let convertToTask {
            contextMenu {
                Button {
                    convertToTask(event)
                } label: {
                    Label("转为任务", systemImage: "checklist")
                }
            }
        } else {
            self
        }
    }
}
