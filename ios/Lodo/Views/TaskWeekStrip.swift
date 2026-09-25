import SwiftUI
import LodoCore

/// 任务页顶部常驻的一周视图:一行七天,点某天把下面的列表切成那天的日程,
/// 再点一下取消。左右滑(或点两端的箭头)翻周。
///
/// 周计算、抬头文案都在 `LodoCore/CalendarWeek`(可离线单测),这里只管画。
/// 每天下面那颗小点表示"这天有事":实心=有任务,空心描边=只有系统日历事件。
struct TaskWeekStrip: View {
    /// 当前显示的那一周(周一零点)。
    @Binding var weekStart: Date
    /// 选中的那天;nil = 没选,下面的列表按筛选胶囊走。
    @Binding var selectedDay: Date?
    /// 某天有没有 lodo 任务 / 系统日历事件,由任务页算好传进来(它手里才有数据)。
    let hasTask: (Date) -> Bool
    let hasEvent: (Date) -> Bool

    @Environment(\.lodoAccent) private var accent
    @Environment(\.sectionIsActive) private var sectionIsActive

    private let calendar = Calendar.current
    private var days: [Date] { CalendarWeek.days(containing: weekStart, calendar: calendar) }

    var body: some View {
        VStack(spacing: 6) {
            header
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        // 整条周条都能横向拖来翻周,所以要向外层抽屉申报"这块别接管"——
        // 理由同 HorizontalChipRow(往右滑看上一周会顺手把抽屉拖出来)。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarDragExclusionKey.self,
                    value: sectionIsActive
                        ? [proxy.frame(in: .named(SidebarDragExclusion.spaceName))]
                        : [])
            }
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    shift(by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var header: some View {
        HStack {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                    .hitTarget(visualSize: 24)
            }
            .pressable()
            .accessibilityLabel("上一周")

            Spacer()
            Button {
                // 抬头文字本身是"回到本周并取消选中"的快捷入口——翻远了之后
                // 不用一周一周点回来。
                withAnimation(.lodoAware(.lodoQuickFade)) {
                    weekStart = CalendarWeek.start(of: Date(), calendar: calendar)
                    selectedDay = nil
                }
            } label: {
                Text(CalendarWeek.label(for: weekStart, calendar: calendar))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .pressable()
            Spacer()

            Button {
                shift(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .hitTarget(visualSize: 24)
            }
            .pressable()
            .accessibilityLabel("下一周")
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDateInToday(day)
        return Button {
            withAnimation(.lodoAware(.lodoQuickFade)) {
                selectedDay = isSelected ? nil : day
            }
        } label: {
            VStack(spacing: 3) {
                Text(weekdayNames[(calendar.component(.weekday, from: day) + 5) % 7])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? accent.onFill : (isToday ? accent.accent : .primary))
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected {
                            Circle().fill(accent.fill)
                        } else if isToday {
                            Circle().stroke(accent.accent.opacity(0.5), lineWidth: 1)
                        }
                    }
                marker(for: day)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityLabel(Text(day, format: .dateTime.month().day().weekday()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 有任务实心、只有日历事件空心、都没有留一个等高的透明占位——不占位的话
    /// 有没有小点的两列高度不一样,整行会上下错开。
    @ViewBuilder
    private func marker(for day: Date) -> some View {
        if hasTask(day) {
            Circle().fill(accent.accent).frame(width: 5, height: 5)
        } else if hasEvent(day) {
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 5, height: 5)
        } else {
            Color.clear.frame(width: 5, height: 5)
        }
    }

    private func shift(by weeks: Int) {
        withAnimation(.lodoAware(.lodoQuickFade)) {
            weekStart = CalendarWeek.shift(weekStart, byWeeks: weeks, calendar: calendar)
        }
    }
}

/// 周条选中某天后,列表里那条系统日历事件的行。**不可完成、不可滑、点不动**:
/// 这一版系统事件是只读的(见 CalendarBridge 的注释)。
struct CalendarEventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(timeLabel)
                    if !event.calendarTitle.isEmpty {
                        Text("·")
                        Text(event.calendarTitle)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var timeLabel: String {
        if event.isAllDay { return "全天" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
