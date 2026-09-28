import SwiftUI
import SwiftData
import LodoCore

/// 新建/更新一项资产(房产、车辆、存款……)。资产是打了「资产」标签的记忆条目,
/// 分类是它的另一个标签(`AssetCategory`)。**每次保存都记下更新时间**——资产页的
/// 定位是隔几个月回来核对一次,点开、看一眼、保存,就算"这个月核对过了"。
struct AssetEditView: View {
    var existing: MemoryItem?
    var presetCategory: String = "其他"

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category = "其他"
    @State private var currency = AppSettings.assetDisplayCurrency
    @State private var valueText = ""
    @State private var liabilityText = ""
    @State private var rateText = ""
    @State private var note = ""
    @State private var didLoad = false
    @State private var confirmingDelete = false

    private func number(_ text: String) -> Double?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        return Double(trimmed).map { .some($0) } ?? nil
    }

    /// 金额框填了却解析不出数字时挡住保存(同 AssetComposeView)。
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && number(valueText) != nil && number(liabilityText) != nil && number(rateText) != nil
    }

    /// 分类选项:预设 + 这一项自己原来的自定义分类。
    private var categories: [String] {
        AssetCategory.presets.contains(category) ? AssetCategory.presets
            : AssetCategory.presets.dropLast() + [category, "其他"]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称,如 望京的房子", text: $title)
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { item in
                            Label(LocalizedStringKey(item), systemImage: AssetCategory.symbol(for: item))
                                .tag(item)
                        }
                    }
                }
                Section {
                    HStack {
                        Picker("币种", selection: $currency) {
                            ForEach(CurrencyCatalog.common, id: \.code) { entry in
                                Text(entry.code).tag(entry.code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("现在值多少", text: $valueText)
                            .decimalKeyboard()
                    }
                    TextField("负债(可选),如房贷/车贷还欠多少", text: $liabilityText)
                        .decimalKeyboard()
                    TextField("利率(可选),年化百分比,如 3.85", text: $rateText)
                        .decimalKeyboard()
                } header: {
                    Text("金额")
                } footer: {
                    if let existing {
                        Text("上次更新:\(existing.assetUpdatedAtOrCreated.formatted(date: .long, time: .omitted))。保存一次就算核对过了。")
                    } else {
                        Text("负债按同一个币种填。每月的月供记在「固定支出」里。")
                    }
                }
                Section("备注") {
                    TextField("备注(可选)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                if existing != nil {
                    Section {
                        Button("删除这项资产", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(existing == nil ? "记一项资产" : "更新资产"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("删除这项资产?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let existing { MemoryPipeline.delete(existing, context: context) }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else {
            category = presetCategory
            return
        }
        title = existing.title
        category = AssetCategory.category(of: existing.tags, reserved: MemoryItem.reservedTagNames)
        currency = existing.assetCurrencyOrDefault
        valueText = existing.assetValue.map(Self.plain) ?? ""
        liabilityText = existing.assetLiability.map(Self.plain) ?? ""
        rateText = existing.assetInterestRate.map(Self.plain) ?? ""
        note = existing.summary
    }

    /// 3000000.0 显示成 3000000,不带尾巴上的 .0。
    static func plain(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func save() {
        let value = number(valueText) ?? nil
        let liability = number(liabilityText) ?? nil
        let rate = number(rateText) ?? nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing else {
            MemoryPipeline.saveAsset(title: trimmedTitle, value: value, currency: currency,
                                     liability: liability, interestRate: rate,
                                     category: category == "其他" ? "" : category,
                                     note: note, context: context)
            dismiss()
            return
        }
        let oldCategory = AssetCategory.category(of: existing.tags, reserved: MemoryItem.reservedTagNames)
        var tags = existing.tags.filter { $0 != oldCategory }
        if category != "其他", !tags.contains(category) {
            // 分类紧跟在保留标签后面,`AssetCategory.category(of:)` 取的就是第一个非保留标签。
            let index = tags.lastIndex { MemoryItem.reservedTagNames.contains($0) }.map { $0 + 1 } ?? 0
            tags.insert(category, at: index)
        }
        existing.title = trimmedTitle
        existing.tags = tags
        existing.assetValue = value
        existing.assetCurrency = value != nil || liability != nil ? currency : nil
        existing.assetLiability = liability
        existing.assetInterestRate = rate
        existing.summary = note
        existing.assetUpdatedAt = Date()
        MemoryPipeline.finishStructuredSave(existing, context: context)
        dismiss()
    }
}

/// 新建/更新一项收入、固定支出或信用卡。
struct FinanceEntryEditView: View {
    let kind: FinanceKind
    var existing: FinanceEntry?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allEntries: [FinanceEntry]

    @State private var title = ""
    @State private var institution = ""
    @State private var currency = AppSettings.assetDisplayCurrency
    @State private var amountText = ""
    @State private var cadence: FinanceCadence = .monthly
    @State private var dayOfMonth: Int?
    @State private var statementDay: Int?
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 10, to: .now) ?? .now
    @State private var remindEnabled = true
    @State private var notes = ""
    @State private var didLoad = false
    @State private var confirmingDelete = false

    private var amount: Double?? {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        return Double(trimmed).map { .some($0) } ?? nil
    }

    private var canSave: Bool {
        let named = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (kind == .creditCard && !institution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return named && amount != nil
    }

    private var navigationTitle: LocalizedStringKey {
        switch kind {
        case .income: return existing == nil ? "添加收入" : "收入"
        case .expense: return existing == nil ? "添加固定支出" : "固定支出"
        case .creditCard: return existing == nil ? "添加信用卡" : "信用卡"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if kind == .creditCard {
                    cardSections
                } else {
                    flowSections
                }
                Section("备注") {
                    TextField("备注(可选)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if existing != nil {
                    Section {
                        Button("删除", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(kind == .creditCard ? "删除这张信用卡?还没完成的还款提醒也会一起删掉。" : "删除这一项?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete() }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - 收入 / 支出

    @ViewBuilder
    private var flowSections: some View {
        Section {
            TextField(kind == .income ? "名称,如 工资、年终奖" : "名称,如 房贷月供、房租", text: $title)
            amountField(kind == .income ? "金额" : "每期金额")
            Picker("周期", selection: $cadence) {
                Text("每月").tag(FinanceCadence.monthly)
                Text("每季度").tag(FinanceCadence.quarterly)
                Text("每年").tag(FinanceCadence.yearly)
                Text("不定期").tag(FinanceCadence.irregular)
            }
            if cadence == .monthly {
                dayPicker(kind == .income ? "发放日" : "扣款日", selection: $dayOfMonth)
            }
            TextField(kind == .income ? "来源(可选),如 公司名" : "付给谁(可选),如 建设银行",
                      text: $institution)
        } footer: {
            if cadence == .irregular {
                Text("不定期的不折算进每月收支,只在列表里记着。")
            } else if cadence != .monthly {
                Text("按月折算进总览里的每月收支(每年的 ÷12、每季度的 ÷3)。")
            }
        }
        if kind == .expense {
            Section {
                Toggle("有截止日期", isOn: $hasEndDate.animation(.lodoAware(.snappy)))
                if hasEndDate {
                    DatePicker("还到", selection: $endDate, displayedComponents: .date)
                }
            } footer: {
                Text("房贷车贷这类会还完的,过了截止日期就不再算进每月支出。")
            }
        }
    }

    // MARK: - 信用卡

    @ViewBuilder
    private var cardSections: some View {
        Section {
            TextField("银行,如 招商银行", text: $institution)
            TextField("卡片名称(可选),如 经典白", text: $title)
            amountField("额度")
        }
        Section {
            dayPicker("账单日", selection: $statementDay)
            dayPicker("还款日", selection: $dayOfMonth)
            Toggle("还款日前一天提醒", isOn: $remindEnabled)
        } header: {
            Text("日期")
        } footer: {
            Text("开着时,每期还款日的前一天会自动生成一条「还信用卡」任务,在全天提醒的时刻响,没点完成会一直提醒。遇到小月,31 号落在月末那天。")
        }
    }

    // MARK: - 共用控件

    private func amountField(_ placeholder: LocalizedStringKey) -> some View {
        HStack {
            Picker("币种", selection: $currency) {
                ForEach(CurrencyCatalog.common, id: \.code) { entry in
                    Text(entry.code).tag(entry.code)
                }
            }
            .labelsHidden()
            .fixedSize()
            TextField(placeholder, text: $amountText)
                .decimalKeyboard()
        }
    }

    private func dayPicker(_ title: LocalizedStringKey, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("不填").tag(Int?.none)
            ForEach(1...31, id: \.self) { day in
                Text("\(day) 号").tag(Int?.some(day))
            }
        }
    }

    // MARK: - 读写

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else { return }
        title = existing.title
        institution = existing.institution
        currency = existing.currency
        amountText = existing.amount.map(AssetEditView.plain) ?? ""
        cadence = existing.cadence
        dayOfMonth = existing.dayOfMonth
        statementDay = existing.statementDay
        if let end = existing.endDate {
            hasEndDate = true
            endDate = end
        }
        remindEnabled = existing.remindEnabled
        notes = existing.notes
    }

    private func save() {
        let entry = existing ?? {
            let next = (allEntries.map(\.sortIndex).max() ?? -1) + 1
            let created = FinanceEntry(kind: kind, title: "", sortIndex: next)
            context.insert(created)
            return created
        }()
        entry.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.institution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.currency = currency
        entry.amount = amount ?? nil
        entry.notes = notes
        if kind == .creditCard {
            entry.dayOfMonth = dayOfMonth
            entry.statementDay = statementDay
            entry.remindEnabled = remindEnabled
        } else {
            entry.cadence = cadence
            entry.dayOfMonth = cadence == .monthly ? dayOfMonth : nil
            entry.endDate = kind == .expense && hasEndDate ? endDate : nil
        }
        // 保存一次就算核对过(资产页"上次更新"的口径)。
        entry.updatedAt = Date()
        try? context.save()
        if kind == .creditCard { FinanceReminders.sync(context: context) }
        dismiss()
    }

    private func delete() {
        guard let existing else { return }
        FinanceReminders.removeReminder(for: existing, context: context)
        context.delete(existing)
        try? context.save()
        dismiss()
    }
}

private extension View {
    /// 金额栏弹数字键盘(只有 iOS 有这个概念)。
    @ViewBuilder
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
