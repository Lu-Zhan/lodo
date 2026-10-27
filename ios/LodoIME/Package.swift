// swift-tools-version: 5.9
import PackageDescription

// lodo 键盘的拼音引擎:纯 Swift、无 UIKit,和 LodoCore 分开(LodoCore 要编 watchOS,
// 8 MB 的词库和它无关)。
//
// LodoReranker 是可选的一层:chinese-ime-lm 4M 重排器(Rust,预编译成 xcframework,
// 重编见 ios/Tools/build_reranker.sh)。LodoIME 本身不依赖它。
let package = Package(
    name: "LodoIME",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LodoIME", targets: ["LodoIME"]),
        .library(name: "LodoReranker", targets: ["LodoReranker"]),
        .library(name: "LodoKeyboardModel", targets: ["LodoKeyboardModel"]),
        .library(name: "LodoKeyboardUI", targets: ["LodoKeyboardUI"]),
    ],
    targets: [
        .target(name: "LodoIME", resources: [.copy("Resources/PinyinLexicon.bin")]),
        .binaryTarget(name: "LodoRerankerFFI", path: "Reranker/LodoRerankerFFI.xcframework"),
        .target(name: "LodoReranker", dependencies: ["LodoIME", "LodoRerankerFFI"],
                resources: [.copy("Resources/pinyin-ime-reranker-4M.safetensors")]),
        // 键位、布局计算、打字状态机:纯逻辑,macOS 上也能单测。
        .target(name: "LodoKeyboardModel", dependencies: ["LodoIME"]),
        // 键盘视图(UIKit,整份 #if os(iOS)):扩展和截图用的 LodoKeyboardDemo 共用。
        .target(name: "LodoKeyboardUI", dependencies: ["LodoKeyboardModel", "LodoReranker"]),
        .testTarget(name: "LodoIMETests", dependencies: ["LodoIME", "LodoReranker", "LodoKeyboardModel"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "LodoKeyboardUITests", dependencies: ["LodoKeyboardUI"]),
    ]
)
