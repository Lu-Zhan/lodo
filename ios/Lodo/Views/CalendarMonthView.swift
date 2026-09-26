import SwiftUI
import LodoCore

/// 本月视图:上面一张 7 列月格(每格日期 + 最多三颗所属日历颜色的小点),
/// 下面是选中那天的日程列表——和 iPhone 系统日历月视图的"格子 + 列表"一致。
/// 点已选中的那天再点一下进当日视图。
struct CalendarMonthView: View {
    let month: Date
    let events: [CalendarEvent]
    @Binding var selectedDay: Date
    let onOpenDay: (Date) -> Void
    let onOpen: (CalendarEvent) -> Void
    let convertToTask: ((CalendarEvent) -> Void)?

    @Environment(\.lodoAccent) private var accent
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(CalendarViewPlan.monthGrid(for: month, calendar: calendar), id: \.self) { day in
                    cell(day)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            Divider()
            dayList
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(CalendarWeek.days(containing: month, calendar: calendar), id: \.self) { day in
                Text(day, format: .dateTime.weekday(.narrow))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func cell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let dayEvents = CalendarViewPlan.events(events, on: day, calendar: calendar)
        return Button {
            if selected {
                onOpenDay(day)
            } else {
                withAnimation(.lodoAware(.lodoQuickFade)) { selectedDay = day }
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.body.weight(isToday || selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent.onFill
                                     : isToday ? accent.accent
                                     : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: 34, height: 34)
                    .background {
                        if selected { Circle().fill(accent.fill) }
                    }
                HStack(spacing: 3) {
                    ForEach(dayEvents.prefix(3), id: \.occurrenceKey) { event in
                        Circle().fill(event.displayColor(accent)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityLabel(Text(day, format: .dateTime.month().day().weekday()))
        .accessibilityValue(dayEvents.isEmpty ? Text("") : Text("\(dayEvents.count) 个日程"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dayList: some View {
        let dayEvents = CalendarViewPlan.events(events, on: selectedDay, calendar: calendar)
        return List {
            Section {
                if dayEvents.isEmpty {
                    Text("这天没有日程").foregroundStyle(.secondary)
                }
                ForEach(dayEvents, id: \.occurrenceKey) { event in
                    CalendarEventRow(event: event, day: selectedDay, onOpen: onOpen,
                                     convertToTask: convertToTask)
                }
            } header: {
                Text(selectedDay, format: .dateTime.month().day().weekday())
            }
        }
        .listStyle(.plain)
    }
}

/// 全年视图:十二个小月历,点某个月进本月视图。和系统日历一样**不画事件**
/// ——一格只有几个点大,画上去也看不清;有日程的日子只把数字加粗。
struct CalendarYearView: View {
    let year: Date
    let events: [CalendarEvent]
    let onOpenMonth: (Date) -> Void

    @Environment(\.lodoAccent) private var accent
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let calendar = Calendar.current

    var body: some View {
        let busyDays = Set(events.flatMap { event -> [Date] in
            var days: [Date] = []
            var day = calendar.startOfDay(for: event.start)
            repeat {
                days.append(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < event.end && days.count < 366
            return days
        })
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                                     count: sizeClass == .regular ? 4 : 3),
                      alignment: .leading, spacing: 20) {
                ForEach(CalendarViewPlan.months(ofYear: year, calendar: calendar), id: \.self) { month in
                    Button {
                        onOpenMonth(month)
                    } label: {
                        miniMonth(month, busyDays: busyDays)
                    }
                    .pressableCard()
                    .accessibilityLabel(Text(month, format: .dateTime.year().month(.wide)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func miniMonth(_ month: Date, busyDays: Set<Date>) -> some View {
        let isCurrentMonth = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
        return VStack(alignment: .leading, spacing: 4) {
            Text(month, format: .dateTime.month(.abbreviated))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isCurrentMonth ? accent.accent : .primary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(CalendarViewPlan.monthGrid(for: month, calendar: calendar), id: \.self) { day in
                    if calendar.isDate(day, equalTo: month, toGranularity: .month) {
                        let isToday = calendar.isDateInToday(day)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 9, weight: isToday || busyDays.contains(day) ? .bold : .regular))
                            .foregroundStyle(isToday ? accent.onFill : .primary)
                            .frame(width: 14, height: 14)
                            .background {
                                if isToday { Circle().fill(accent.fill) }
                            }
                    } else {
                        Color.clear.frame(height: 14)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// 所有列表 / 月视图下方列表里的一行系统事件:左边一根所属日历颜色的竖条,
/// 标题 + 「时间 · 地点 · 日历名」。点开进系统的详情/编辑界面;写开关开着时
/// 左滑可「转为任务」。
struct CalendarEventRow: View {
    let event: CalendarEvent
    let day: Date
    let onOpen: (CalendarEvent) -> Void
    let convertToTask: ((CalendarEvent) -> Void)?

    @Environment(\.lodoAccent) private var accent

    var body: some View {
        Button {
            onOpen(event)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(event.displayColor(accent))
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .swipeActions(edge: .trailing) {
            if let convertToTask {
                Button {
                    convertToTask(event)
                } label: {
                    Label("转为任务", systemImage: "checklist")
                }
                .tint(.accentColor)
            }
        }
        .accessibilityLabel(Text(event.accessibilityDescription))
    }

    private var detail: String {
        [timeLabel, event.location ?? "", event.calendarTitle]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 跨天事件在中间几天写「全天」,首尾两天只写开始/结束那一端。
    private var timeLabel: String {
        let calendar = Calendar.current
        if event.showsInAllDayRow(on: day, calendar: calendar) { return String(localized: "全天") }
        let startsToday = calendar.isDate(event.start, inSameDayAs: day)
        let endsToday = calendar.isDate(event.end, inSameDayAs: day)
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        switch (startsToday, endsToday) {
        case (true, true): return "\(start) – \(end)"
        case (true, false): return "\(start) –"
        case (false, true): return "– \(end)"
        case (false, false): return String(localized: "全天")
        }
    }
}
