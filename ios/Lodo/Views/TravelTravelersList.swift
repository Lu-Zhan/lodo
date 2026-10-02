import SwiftUI
import SwiftData
import LodoCore

/// 旅行详情面板里的「人员」:这趟一起去的人。可以从人脉里挑(行上挂一枚「人脉」
/// 标签,名字随人脉走,点进去就是那位人脉的详情),也可以单独新建一个名字——
/// 一起去的同事不一定值得进人脉库。
///
/// 数据挂在 `TravelTrip.travelersData`(`TripTraveler`,见那边的注释),跟着旅行共享和备份。
struct TravelTravelersList: View {
    @Bindable var trip: TravelTrip

    @Environment(\.modelContext) private var context
    @Environment(\.lodoAccent) private var accent
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    @Query(sort: [SortDescriptor(\MemoryItem.title)]) private var memoryItems: [MemoryItem]

    @State private var newName = ""
    @FocusState private var addFocused: Bool
    @State private var pickingContacts = false
    @State private var viewingContact: MemoryItem?
    @State private var editing: TripTraveler?

    private var travelers: [TripTraveler] { trip.travelers }
    private var contacts: [MemoryItem] { memoryItems.filter(\.isContact) }

    private func contact(for traveler: TripTraveler) -> MemoryItem? {
        guard let uuid = traveler.contactUUID else { return nil }
        return contacts.first { $0.uuid == uuid }
    }

    var body: some View {
        List {
            Section {
                Button {
                    pickingContacts = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .frame(width: 22)
                        Text("从人脉添加")
                            .font(.body.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .pressableCard()
                .foregroundStyle(.tint)
                .disabled(contacts.isEmpty)
                .travelPanelRow(group: "people-controls")
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    TextField("新建同行人", text: $newName)
                        .focused($addFocused)
                        .submitLabel(.done)
                        .onSubmit(addNew)
                }
                .padding(.vertical, 1)
                .travelPanelRow(group: "people-controls")
            } footer: {
                if travelers.isEmpty {
                    Text(contacts.isEmpty
                         ? "输入名字添加一起去的人;人脉里记过的人也能直接链接过来。"
                         : "从人脉里挑一起去的人,或者直接输入名字新建。")
                }
            }

            if !travelers.isEmpty {
                Section {
                    ForEach(travelers) { traveler in row(traveler) }
                } header: {
                    Text("同行 \(travelers.count) 人")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .travelPanelGroupGlass()
        .sheet(isPresented: $pickingContacts) {
            TravelerContactPicker(contacts: contacts,
                                  linked: Set(travelers.compactMap(\.contactUUID))) { picked in
                trip.travelers = TripTraveler.linking(picked.map { ($0.uuid, $0.title) },
                                                      into: trip.travelers)
                try? context.save()
            }
        }
        .sheet(item: $viewingContact) { contact in
            NavigationStack {
                ContactDetailView(item: contact)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { viewingContact = nil }
                        }
                    }
            }
            .tint(accent.accent)
            .environment(\.lodoAccent, accent)
        }
        .sheet(item: $editing) { traveler in
            TravelerEditSheet(traveler: traveler) { updated in
                var list = trip.travelers
                if let index = list.firstIndex(where: { $0.id == updated.id }) {
                    list[index] = updated
                    trip.travelers = list
                    try? context.save()
                }
            }
        }
    }

    private func row(_ traveler: TripTraveler) -> some View {
        let linked = contact(for: traveler)
        return Button {
            if let linked {
                viewingContact = linked
            } else if !traveler.isLinkedContact {
                editing = traveler
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: traveler.isLinkedContact ? "person.crop.circle.fill" : "person.crop.circle")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(linked?.title ?? traveler.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if traveler.isLinkedContact {
                            ContactTagChip()
                        }
                    }
                    if let line = subtitle(traveler, contact: linked) {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .travelPanelRow(group: "people")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                trip.travelers = trip.travelers.filter { $0.id != traveler.id }
                try? context.save()
            } label: {
                Label("移除", systemImage: "person.badge.minus")
            }
            if !traveler.isLinkedContact {
                Button {
                    editing = traveler
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(.gray)
            }
        }
    }

    /// 第二行:单独新建的写备注;链接的人脉写昵称 · 联系方式;人脉在这台设备上找不到
    /// 时(被删了、或者是共享旅行里别人的人脉)如实说一句。
    private func subtitle(_ traveler: TripTraveler, contact: MemoryItem?) -> String? {
        guard traveler.isLinkedContact else {
            return traveler.note.isEmpty ? nil : traveler.note
        }
        guard let contact else {
            return String(localized: "这台设备的人脉里没有这个人", bundle: .appLanguage(language),
                          locale: language.locale)
        }
        let parts = [contact.contactNickname, contact.contactPhone ?? contact.contactEmail]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func addNew() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        trip.travelers = trip.travelers + [TripTraveler(name: name)]
        try? context.save()
        newName = ""
        addFocused = true
    }
}

/// 行上的「人脉」小标签:这位同行人是从人脉链接过来的。
private struct ContactTagChip: View {
    var body: some View {
        Text("人脉")
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .accessibilityLabel("来自人脉")
    }
}

/// 从人脉里挑同行人(多选)。已经链接过的显示为已选、不可再点。
private struct TravelerContactPicker: View {
    let contacts: [MemoryItem]
    let linked: Set<UUID>
    let onAdd: ([MemoryItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List(contacts) { contact in
                let already = linked.contains(contact.uuid)
                let isOn = already || selected.contains(contact.uuid)
                Button {
                    if selected.contains(contact.uuid) {
                        selected.remove(contact.uuid)
                    } else {
                        selected.insert(contact.uuid)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.title).foregroundStyle(.primary)
                            if already {
                                Text("已在同行人里")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if let nickname = contact.contactNickname, !nickname.isEmpty {
                                Text(nickname)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .pressableCard()
                .disabled(already)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            .pageTitle("从人脉添加")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("添加") {
                        onAdd(contacts.filter { selected.contains($0.uuid) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 单独新建的同行人:改名字、写一句备注。
private struct TravelerEditSheet: View {
    let traveler: TripTraveler
    let onSave: (TripTraveler) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("名字", text: $name)
                TextField("备注", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            }
            .pageTitle("同行人")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") {
                        var updated = traveler
                        updated.name = name
                        updated.note = note
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                name = traveler.name
                note = traveler.note
            }
        }
        .presentationDetents([.medium])
    }
}
