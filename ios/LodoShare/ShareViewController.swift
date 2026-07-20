import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// 系统分享面板里的"lodo"入口:不调 AI、不写数据库,只把分享内容
/// (文字/链接/图片/PDF/任意文件)落进 App Group 的收件箱
/// Memory/Inbox/<uuid>/(payload 文件 + meta.json),主 app 回前台时消费、
/// 走统一的 AI 整理管线。扩展内存上限低(~120MB)且随时可能被杀,
/// 纯拷贝毫秒级完成,收藏动作永不失败。
final class ShareViewController: UIViewController {

    /// 与主 app 的 AppGroup.id 一致;不链接 LodoCore,避免扩展拖整个包。
    private static let appGroupID = "group.com.lodo.app"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let card = UIHostingController(rootView: SavedCard())
        card.view.backgroundColor = .clear
        addChild(card)
        view.addSubview(card.view)
        card.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        card.didMove(toParent: self)

        saveAllInputs()
    }

    // MARK: - 收件箱落盘

    private func saveAllInputs() {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        for provider in providers {
            save(provider, group: group)
        }
        group.notify(queue: .main) { [weak self] in
            // 稍留一拍让"已收藏"卡片可见,再交还控制权
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    /// 单个附件按 文件 > 图片 > 链接 > 文字 的优先级落盘。
    private func save(_ provider: NSItemProvider, group: DispatchGroup) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let url = item as? URL, url.isFileURL else { return }
                Self.writeInbox(fileURL: url)
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            group.enter()
            // 相册分享的图片没有稳定文件路径,用临时文件表示(回调返回即失效,当场拷走)
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.image.identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                Self.writeInbox(fileURL: url)
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                defer { group.leave() }
                guard let url = item as? URL else { return }
                if url.isFileURL {
                    Self.writeInbox(fileURL: url)
                } else {
                    Self.writeInbox(meta: ["type": "url", "url": url.absoluteString])
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                defer { group.leave() }
                guard let text = item as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Self.writeInbox(meta: ["type": "text", "text": text])
            }
        }
    }

    private static func writeInbox(fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let dir = newInboxEntryDir() else { return }
        let target = dir.appending(path: fileURL.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: fileURL, to: target)) != nil else {
            try? FileManager.default.removeItem(at: dir)
            return
        }
        write(meta: ["type": "file", "filename": fileURL.lastPathComponent], into: dir)
    }

    private static func writeInbox(meta: [String: String]) {
        guard let dir = newInboxEntryDir() else { return }
        write(meta: meta, into: dir)
    }

    private static func write(meta: [String: String], into dir: URL) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: dir.appending(path: "meta.json"), options: .atomic)
    }

    private static func newInboxEntryDir() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let dir = container.appending(path: "Memory/Inbox/\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir
    }
}

/// "已收藏到 lodo"确认卡片。
private struct SavedCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("已收藏到 lodo")
                .font(.headline)
            Text("打开 lodo 的「记忆」查看 AI 整理结果")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
