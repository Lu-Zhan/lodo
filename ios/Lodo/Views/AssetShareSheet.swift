#if os(iOS)
import SwiftUI
import SwiftData
import CloudKit
import LodoCore

/// 资产页右上角「共享」点开的确认页:总开关 + 当前状态(身份、同步、成员)+ 逐条勾选
/// 共享哪些条目。**条目一条一条手动勾**,新记的默认不共享(见 `SharedAssetPlanner`);
/// 确认之后才真正建共享 / 改勾选 / 停止共享,第一次开启时接着弹系统邀请界面。
struct AssetShareSheet: View {
    let assets: [MemoryItem]
    let entries: [FinanceEntry]

    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var selected: Set<UUID> = []
    @State private var locked: Set<UUID> = []
    @State private var members: [SharedTripSync.AssetShareMember]?
    @State private var working = false
    @State private var errorText: String?
    @State private var confirmingStop = false
    @State private var confirmingRemove = false
    @State private var didLoad = false

    private var sync: SharedTripSync { SharedTripSync.shared }
    private var share: SharedTripSync.AssetShareState? { sync.assetShare }
    private var isShared: Bool { share != nil }
    private var isParticipant: Bool { share?.role == .participant }

    /// 现在已经在共享台账里的条目。
    private var current: Set<UUID> {
        guard let ledger = share?.ledgerUUID else { return [] }
        return Set(assets.filter { $0.assetLedgerUUID == ledger }.map(\.uuid)
                   + entries.filter { $0.ledgerUUID == ledger }.map(\.uuid))
    }

    private var changes: (add: Set<UUID>, remove: Set<UUID>) {
        SharedAssetPlanner.selectionChanges(current: current, selected: selected, locked: locked)
    }

    private var hasChanges: Bool {
        if enabled != isShared { return true }
        let c = changes
        return enabled && !(c.add.isEmpty && c.remove.isEmpty)
    }

    private var allIDs: [UUID] { assets.map(\.uuid) + entries.map(\.uuid) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isParticipant ? "加入的共享台账" : "共享资产台账", isOn: $enabled)
                        .disabled(working || (!sync.isAvailable && !isShared))
                } footer: {
                    if !sync.isAvailable && !isShared {
                        Text("请先在系统设置里登录 iCloud")
                    } else if isParticipant {
                        Text("关掉就是退出这本共享台账:别人加的条目会留一份在本机,不再同步。")
                    } else {
                        Text("经 iCloud 共享给你邀请的人,双方都能查看和修改勾选的条目。没勾的只在你自己的设备上。")
                    }
                }

                if isShared { statusSection }

                if enabled { selectionSection }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(LodoColor.critical) }
                }
            }
            .navigationTitle("共享资产")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        confirmButton("确认", action: confirm)
                            .disabled(!hasChanges)
                    }
                }
            }
            .confirmationDialog(isParticipant ? "退出共享台账?" : "停止共享资产台账?",
                                isPresented: $confirmingStop, titleVisibility: .visible) {
                Button(isParticipant ? "退出" : "停止共享", role: .destructive) { stopSharing() }
            } message: {
                Text(isParticipant
                     ? "别人加的条目会留一份在本机,之后不再同步。"
                     : "成员那边会留一份当前的副本,之后不再同步。")
            }
            .confirmationDialog("移出共享?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("移出 \(changes.remove.count) 项", role: .destructive) { applySelection() }
            } message: {
                Text("这些条目会从共享成员那边删掉,你这边保留。")
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                enabled = isShared
                selected = current
                locked = sync.assetUUIDsAddedByOthers()
                #if DEBUG
                // 截图用:模拟器没登 iCloud,开关是锁着的,直接摆成打开看勾选清单。
                if ProcessInfo.processInfo.arguments.contains("--demo-assets-share-on") {
                    enabled = true
                    selected = Set(assets.prefix(2).map(\.uuid))
                }
                #endif
                if isShared { members = await sync.assetShareMembers() }
            }
        }
    }

    // MARK: - 当前状态

    private var statusSection: some View {
        Section("当前状态") {
            LabeledContent("身份", value: isParticipant
                           ? String(localized: "成员(别人分享给我)", bundle: .appLanguage())
                           : String(localized: "发起人", bundle: .appLanguage()))
            LabeledContent("已共享", value: String(localized: "\(current.count) 项", bundle: .appLanguage()))
            if let ledger = share?.ledgerUUID, let pending = sync.pendingCounts[ledger], pending > 0 {
                LabeledContent("同步", value: String(localized: "正在同步 \(pending) 项", bundle: .appLanguage()))
            } else {
                LabeledContent("同步", value: String(localized: "已同步", bundle: .appLanguage()))
            }
            if let members {
                ForEach(members) { member in
                    HStack {
                        Image(systemName: member.isOwner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .foregroundStyle(.tint)
                        Text(member.isMe ? String(localized: "\(member.name)(我)", bundle: .appLanguage()) : member.name)
                        Spacer()
                        Text(member.isOwner ? "发起人" : member.accepted ? "已加入" : "待接受")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在读取共享成员…").foregroundStyle(.secondary)
                }
            }
            Button(isParticipant ? "查看成员" : "邀请 / 管理成员") { manageMembers() }
                .disabled(working)
        }
    }

    // MARK: - 勾选条目

    private var selectionSection: some View {
        Section {
            ForEach(assets) { item in
                row(id: item.uuid, title: item.title,
                    detail: item.assetValue.map { AssetFormat.currency($0, code: item.assetCurrencyOrDefault) },
                    symbol: AssetCategory.symbol(for: AssetCategory.category(
                        of: item.tags, reserved: MemoryItem.reservedTagNames)))
            }
            ForEach(entries) { entry in
                row(id: entry.uuid, title: FinanceText.displayTitle(entry),
                    detail: entry.amount.map { AssetFormat.currency($0, code: entry.currency) },
                    symbol: entry.kind == .creditCard ? "creditcard"
                        : entry.kind == .income ? "arrow.down.circle" : "arrow.up.circle")
            }
        } header: {
            HStack {
                Text("共享哪些条目")
                Spacer()
                Button(selected.isSuperset(of: allIDs) ? "全不选" : "全选") {
                    selected = selected.isSuperset(of: allIDs) ? locked.intersection(current) : Set(allIDs)
                }
                .font(.footnote)
                .textCase(nil)
            }
        } footer: {
            Text("已选 \(selected.count) 项。之后新记的条目默认不共享,回到这里勾上才会共享。")
        }
    }

    private func row(id: UUID, title: String, detail: String?, symbol: String) -> some View {
        let isLocked = locked.contains(id) && current.contains(id)
        let isOn = selected.contains(id) || isLocked
        return Button {
            guard !isLocked else { return }
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if isLocked {
                        Text("别人加的,不能在这里移出").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let detail {
                    Text(detail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .pressableCard()
        .opacity(isLocked ? 0.6 : 1)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - 动作

    private func confirm() {
        errorText = nil
        if !enabled && isShared {
            confirmingStop = true
        } else if enabled && !isShared {
            startSharing()
        } else if !changes.remove.isEmpty {
            confirmingRemove = true
        } else {
            applySelection()
        }
    }

    private func startSharing() {
        working = true
        let picked = selected
        Task {
            defer { working = false }
            do {
                let ckShare = try await sync.prepareAssetShare()
                sync.applyAssetSelection(add: picked, remove: [])
                dismiss()
                // 等确认页收起再弹系统邀请界面(同一时间只能有一个模态)。
                try? await Task.sleep(for: .milliseconds(450))
                CloudSharingPresenter.presentAssets(share: ckShare)
            } catch {
                errorText = error.localizedDescription
                sync.lastError = nil
            }
        }
    }

    private func applySelection() {
        let c = changes
        sync.applyAssetSelection(add: c.add, remove: c.remove)
        dismiss()
    }

    private func stopSharing() {
        sync.didStopSharingAssets()
        dismiss()
    }

    private func manageMembers() {
        working = true
        Task {
            defer { working = false }
            do {
                let ckShare = try await sync.prepareAssetShare()
                dismiss()
                try? await Task.sleep(for: .milliseconds(450))
                CloudSharingPresenter.presentAssets(share: ckShare)
            } catch {
                errorText = error.localizedDescription
                sync.lastError = nil
            }
        }
    }
}
#endif
