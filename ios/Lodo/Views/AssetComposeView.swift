import SwiftUI
import SwiftData
import LodoCore

/// 记一笔资产(记忆 tab → "+" → 记一笔资产):名称+金额是结构化字段,直接落库
/// 不用等 AI 整理;分类/备注可选。资产本质是打了保留标签的记忆条目,见
/// MemoryItem.assetTagName 与 MemoryPipeline.saveAsset。
struct AssetComposeView: View {
    /// 保存成功后回调(记忆列表页用来把"显示资产"筛选打开,不然刚记的这笔
    /// 资产因为默认隐藏规则,保存完立刻从列表里"消失",像是没保存成功)。
    var onSaved: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var valueText = ""
    @State private var currency = AppSettings.assetDisplayCurrency
    @State private var category = ""
    @State private var note = ""

    private var trimmedValueText: String {
        valueText.trimmingCharacters(in: .whitespaces)
    }

    private var value: Double? {
        Double(trimmedValueText)
    }

    /// 金额框非空但解析不出数字(比如手滑打了几个字母),不能既不提示、
    /// 又悄悄当空值存掉——挡住保存,逼用户改成数字或者清空这一栏。
    private var hasInvalidValue: Bool {
        !trimmedValueText.isEmpty && value == nil
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasInvalidValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称,如 招商银行储蓄卡", text: $title)
                    HStack {
                        Picker("币种", selection: $currency) {
                            ForEach(CurrencyCatalog.common, id: \.code) { entry in
                                Text(entry.code).tag(entry.code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("金额(可选)", text: $valueText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    if hasInvalidValue {
                        Text("金额无法识别为数字,改成数字或清空这一栏才能保存。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextField("分类(可选),如 银行卡、房产、保险", text: $category)
                } footer: {
                    Text("会自动打上「资产」标签,记忆列表默认不显示,筛选里选中「资产」才会看到,并在顶部汇总总额。")
                }
                Section("备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("记一笔资产")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        MemoryPipeline.saveAsset(
                            title: title, value: value, currency: currency, category: category,
                            note: note, context: context)
                        onSaved()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}
