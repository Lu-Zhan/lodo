#!/bin/sh
# 把 chinese-ime-lm 重排器(ios/LodoIME/Reranker/ffi)编成 LodoRerankerFFI.xcframework。
# 产物提交进仓库,本机没装 Rust 也能编 app;改了 ffi 或升级上游 commit 才需要重跑。
# 需要 rustup 与三个 target:rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
set -eu
cd "$(dirname "$0")/../LodoIME/Reranker"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
export IPHONEOS_DEPLOYMENT_TARGET=17.0 MACOSX_DEPLOYMENT_TARGET=14.0
for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
    "$CARGO" build --release --manifest-path ffi/Cargo.toml --target "$target"
done
out=LodoRerankerFFI.xcframework
rm -rf "$out"
args=""
for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
    args="$args -library ffi/target/$target/release/liblodo_reranker.a -headers ffi/include"
done
# shellcheck disable=SC2086
xcodebuild -create-xcframework $args -output "$out"
du -sh "$out"/*/liblodo_reranker.a
