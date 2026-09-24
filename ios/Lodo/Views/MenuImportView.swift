import SwiftUI
import SwiftData
import PhotosUI
import LodoCore

/// 新建一张菜单:拍照 / 从相册选截图 / 贴文字,三种可以混着给,点「整理」后
/// 端上 OCR → AI 拆成菜品并翻译 → 落成一条菜单条目,直接 push 进点菜页。
///
/// 没有确认页,理由见 `DeepSeekClient.parseMenu` 的注释。
struct MenuImportView: View {
    /// 整理成功后把新菜单交出去(列表页拿它直接 push 进详情)。
    var onCreated: (MemoryItem) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var photos: [Photo] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var text = ""
    @State private var showCamera = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?

    /// 一张待识别的图。拍照的和相册选的混在一个列表里,按加进来的顺序排。
    private struct Photo: Identifiable {
        let id = UUID()
        let data: Data
        #if os(iOS)
        var thumbnail: UIImage? { UIImage(data: data) }
        #endif
    }

    /// 同一张菜单最多几页。菜单再长也就正反面加酒水单;再多 OCR 出来的文字会被
    /// `MemorySearch.truncate` 截掉,拍了也白拍。
    private static let maxPhotos = 6

    private var hasInput: Bool {
        !photos.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 100)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("也可以把菜单文字直接贴进来。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("文字")
                }

                if working {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在识别并整理菜品…")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("菜品多的菜单要整理一会儿,外文会一并翻译好。")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                }
            }
            .disabled(working)
            .navigationTitle("新建菜单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("整理") { startImport() }
                        .disabled(working || !hasInput)
                }
            }
            .onChange(of: photoItems) { _, items in loadPicked(items) }
            .onDisappear { importTask?.cancel() }
            #if os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in
                    photos.append(Photo(data: data))
                }
                .ignoresSafeArea()
            }
            #endif
            .interactiveDismissDisabled(working)
        }
    }

    // MARK: - 照片

    private var photoSection: some View {
        Section {
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("拍照", systemImage: "camera")
                }
                .disabled(photos.count >= Self.maxPhotos)
            }
            #endif
            PhotosPicker(selection: $photoItems,
                         maxSelectionCount: max(1, Self.maxPhotos - photos.count),
                         matching: .images) {
                Label("从相册选择截图", systemImage: "photo.on.rectangle")
            }
            .disabled(photos.count >= Self.maxPhotos)

            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                HStack(spacing: 12) {
                    #if os(iOS)
                    if let image = photo.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    #endif
                    Text("第 \(index + 1) 页")
                }
            }
            .onDelete { photos.remove(atOffsets: $0) }
        } header: {
            Text("照片")
        } footer: {
            Text("菜单有好几页的,每页拍一张。照片只在本机识别文字,发给 AI 的只有识别出来的文字。")
        }
    }

    /// 相册选好后读成数据追加进列表。PhotosPicker 的选择是全量的,读完就清空,
    /// 下次再点是"再加几张",不会把之前拍的照片替换掉。
    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard photos.count < Self.maxPhotos,
                      let data = try? await item.loadTransferable(type: Data.self) else { continue }
                photos.append(Photo(data: Self.normalized(data)))
            }
            photoItems = []
        }
    }

    /// 相册里的照片可能是 HEIC、分辨率很高;转成 JPEG 再存,附件不至于一张十几 MB。
    /// Vision 两种都认,转换只是为了存储。
    private static func normalized(_ data: Data) -> Data {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.8) ?? data
        #else
        return data
        #endif
    }

    // MARK: - 整理

    private func startImport() {
        errorMessage = nil
        working = true
        let images = photos.map(\.data)
        importTask = Task {
            defer { working = false }
            do {
                let item = try await MenuStore.importMenu(
                    images: images, text: text, language: language, context: context)
                guard !Task.isCancelled else { return }
                onCreated(item)
                dismiss()
            } catch is CancellationError {
                return
            } catch let error as MenuStore.ImportError {
                errorMessage = error.message(language)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
