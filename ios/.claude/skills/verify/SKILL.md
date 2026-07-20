---
name: verify
description: 在 iOS 模拟器里构建、安装并驱动 lodo app 验证改动(截图取证)。
---

# lodo iOS 验证方法

## 构建 + 安装 + 启动(必须 cd 到 ios/)

```bash
cd ios
UDID=$(xcrun simctl list devices available | grep "iPhone 17 Pro (" | grep -oE '[A-F0-9-]{36}')
xcrun simctl boot $UDID 2>/dev/null
xcodebuild -project Lodo.xcodeproj -scheme Lodo \
  -destination "platform=iOS Simulator,id=$UDID" build
APP=$(xcodebuild -project Lodo.xcodeproj -scheme Lodo \
  -destination "platform=iOS Simulator,id=$UDID" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/Lodo.app
xcrun simctl install $UDID "$APP"
xcrun simctl launch $UDID com.lodo.app
xcrun simctl io $UDID screenshot shot.png
```

## DEBUG 启动参数(跳过无法模拟的点按)

- `--demo-done-tab` 直达已完成 tab
- `--demo-memory-tab` 直达记忆 tab
- `--demo-insight` 假的本周洞察文案

## 陷阱

- `simctl openurl` 打 `lodo://` 深链会弹 "Open in Lodo?" 系统确认框,simctl
  无法点按,弹窗挡住期间 scenePhase 一直是 inactive(依赖回前台的逻辑不会
  触发)。清理办法:`simctl shutdown` + `boot` 重启模拟器。
- simctl 没有 tap/键盘输入能力;要驱动新页面就照 ContentView.onAppear 的
  DEBUG 块加 `--demo-*` 参数。
- 模拟器经 iCloud 钥匙串能拿到真实 DeepSeek key,AI 请求是真调用。

## App Group 数据(共享容器)

```bash
GROUP=$(xcrun simctl get_app_container $UDID com.lodo.app groups | awk '{print $2}')
# SwiftData 库:$GROUP/lodo.store;收藏文件:$GROUP/Memory/
# Share Extension 收件箱:$GROUP/Memory/Inbox/<uuid>/{payload,meta.json}
# 往 Inbox 写 meta.json 再重启 app 可模拟"分享到 lodo"(consumeInbox 在回前台时跑)
```

## 纯逻辑单测(调度器/AI 解析)

```bash
cd ios/LodoCore && swift test
```
