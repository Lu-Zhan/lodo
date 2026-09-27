import SwiftUI
import LodoCore

/// 选时区:可搜索的系统时区列表(城市名、地区名、GMT 偏移都能搜),最上面一项
/// 是"跟随手机"(= 不填)。交通行程项的出发地/到达地时区用。
struct TimeZonePickerView: View {
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    @State private var query = ""

    private struct Zone: Identifiable {
        let id: String
        let name: String
    }

    private var zones: [Zone] {
        TimeZone.knownTimeZoneIdentifiers.compactMap { id in
            TimeZone(identifier: id).map {
                Zone(id: id, name: LocalizedContent.timeZoneName($0, language: language))
            }
        }
    }

    private var filtered: [Zone] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return zones }
        return zones.filter {
            $0.id.lowercased().replacingOccurrences(of: "_", with: " ").contains(text)
                || $0.name.lowercased().contains(text)
        }
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    row(id: nil, title: String(localized: "跟随手机", locale: language.locale),
                        detail: LocalizedContent.timeZoneName(.current, language: language))
                }
            }
            Section {
                ForEach(filtered) { zone in
                    row(id: zone.id, title: zone.name, detail: zone.id)
                }
            }
        }
        .searchable(text: $query, prompt: Text("搜索城市或 GMT+9"))
        .navigationTitle("时区")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(id: String?, title: String, detail: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}
