# PKG Sender for macOS — v1.2.0

## What's New in 1.2.0

### New
- **Remove items from the library.** Right-click a card (or use the **Library ▸ Delete** menu / `⌘⌫`) to remove an entry. A confirmation dialog asks first; removed items go to the Trash, so they stay recoverable.
- **Right-click "Open in PKG Viewer".** Send a package straight to the companion PKG Viewer app from the card's context menu.
- **Send-queue protection.** You can no longer delete an item that is queued, sending, or copying — the dialog explains the file is busy and must finish or be removed from the queue first.

### Fixed
- **Double-click to send works again.** A gesture-arena conflict between the context menu and the double-click tap had silently disabled double-click-to-send. The two gestures are now attached so they no longer compete.
- **Card layout restored.** A previous menu rewrite had stretched the library cards; the grid layout is back to normal.
- **No more Gatekeeper hang when opening PKG Viewer.** The app now clears the `com.apple.quarantine` attribute from packages before handing them to PKG Viewer, so macOS no longer pops a verification dialog (which could also open two Viewer windows at once).

## Introduction

A native macOS PKG sender, ported from [Loopayeh/pkg-sender](https://github.com/Loopayeh/pkg-sender) (.NET / Avalonia). It pushes PKG packages and disc images to **PlayStation 5** / **PlayStation 4** over the local network.

- Pure Swift 6 + SwiftUI / AppKit, zero third-party dependencies
- Universal binary (Apple Silicon `arm64` + Intel `x86_64`), requires **macOS 12** minimum

## System Requirements

- macOS 12.0 or later
- PS5 / PS4 on the same local network

## Key Features

- **PS5 push**: send PKG via the Range service, with pause / resume and resumable transfer
- **PS4 push**: PKG (RPI + GoldHEN payload) sending, plus exFAT image copy
- **Library**: add folder / scan disks; auto-scans after adding. Handles PS5 PKG, PS4 PKG (incl. legacy `\x7FPKG`), exFAT images, and PS5 patch / downgrade packages (`\x7FLIH`)
- **Library management**: remove entries (moved to Trash, recoverable) with a confirm prompt; open a package in PKG Viewer from the card's right-click menu
- **Multi-select & batch**: ⌘ toggle, ⇧ range select, double-click to send, select all / invert
- **Send queue**: pause / resume, ▲▼ reorder, PS4 sequential-install mode
- **Lightweight auto-update**: silently checks GitHub Releases at launch; shows a status-bar prompt and opens the download page when a new version is found (prompt only — no auto download / replace)
- **Four languages**: Simplified Chinese / Traditional Chinese / 日本語 / English
- **About window**: login-item toggle, auto-update check toggle, open project home

## Quick Start

1. Menu **Library ▸ Add Folder…** (or drop a folder into the window) to pick a directory with PKGs; it auto-scans
2. Enter your PS5 / PS4 console IP (the first launch auto-detects the local network address)
3. Select a game, double-click or press "Send" to push it to the console

Full steps are in the in-app **Guide** (status-bar Guide button).

## Install & Distribution

This app is **ad-hoc signed (not notarized)**. If double-clicking does nothing after download (Gatekeeper blocks it), run in Terminal:

```bash
xattr -r -d com.apple.quarantine /path/to/PkgSender.app
codesign -f -s - --deep /path/to/PkgSender.app
```

It then runs on this Mac or any other Mac. The app is not sandboxed (it needs to read `/Volumes` and listen on an inbound port).

## Credits

- Original project [Loopayeh/pkg-sender](https://github.com/Loopayeh/pkg-sender) (MIT)
- macOS port: CarlChina

## Known Limitations

- No Developer ID signing or notarization; cross-machine distribution relies on the two commands above
- Auto-update only "prompts + opens the download page"; it does not auto-download or install
- The app deliberately disables the sandbox to read `/Volumes` and listen on a port

---

# PKG Sender for macOS — v1.2.0（中文）

## v1.2.0 更新内容

### 新增
- **资源库删除功能**：右键卡片（或菜单 **Library ▸ 删除** / `⌘⌫`）移除条目，删除前二次确认；条目移入废纸篓，可恢复。
- **右键「通过 PKG Viewer 查看」**：从卡片右键菜单直接调用 PKG Viewer 打开包。
- **发送队列保护**：正在排队 / 发送 / 拷贝中的条目不可删除，对话框会提示文件占用中，需先完成或移出队列。

### 修复
- **双击发送恢复**：右键菜单与双击手势在手势竞技场中相互抢占，导致双击发送静默失效；已重构使两者不再冲突。
- **卡片布局恢复**：此前一次菜单改写误把卡片拉伸，网格布局已恢复正常。
- **打开 PKG Viewer 不再卡 Gatekeeper**：交给 PKG Viewer 前自动清除 `com.apple.quarantine` 属性，避免 macOS 弹出验证框（也曾导致 Viewer 一次开两个窗口）。

## 简介

原生 macOS 版本的 PKG 发送工具，移植自 [Loopayeh/pkg-sender](https://github.com/Loopayeh/pkg-sender)（.NET / Avalonia）。通过局域网把 PKG 安装包与镜像发送到 **PlayStation 5** / **PlayStation 4**。

- 纯 Swift 6 + SwiftUI / AppKit 实现，零第三方依赖
- 通用二进制（Apple Silicon `arm64` + Intel `x86_64`），最低支持 **macOS 12**

## 系统要求

- macOS 12.0 或更高
- 与 PS5 / PS4 处于同一局域网

## 主要功能

- **PS5 推送**：通过 Range 服务发送 PKG，支持暂停 / 恢复、断点续传
- **PS4 推送**：PKG（RPI + GoldHEN 载荷）发送，以及 exFAT 镜像拷贝
- **资源库**：添加文件夹 / 扫描磁盘，添加后自动扫描；适配 PS5 PKG、PS4 PKG（含老式 `\x7FPKG`）、exFAT 镜像，以及 PS5 补丁 / 降级包（`\x7FLIH`）
- **资源管理**：支持删除条目（移入废纸篓、可恢复，带二次确认）；可从卡片右键菜单调用 PKG Viewer 打开包
- **多选与批量**：⌘ 切换、⇧ 连选、双击发送、全选 / 反选
- **发送队列**：暂停 / 恢复、▲▼ 重排、PS4 顺序安装模式
- **轻量自动更新**：启动时静默检查 GitHub Release，发现新版本在状态栏提示并跳转到下载页（仅提示，不自动下载 / 替换）
- **四语界面**：简体中文 / 繁體中文 / 日本語 / English
- **关于窗口**：登录项开关、自动检查更新开关、跳转项目主页

## 快速开始

1. 菜单 **Library ▸ Add Folder…**（或把文件夹拖入窗口）选择含 PKG 的目录，自动扫描
2. 填入 PS5 / PS4 主机 IP（首次启动会自动探测局域网地址）
3. 选中游戏，双击或点「发送」推送到主机

完整步骤见应用内**指南**（状态栏 Guide 按钮）。

## 安装与分发

本应用为 **ad-hoc 签名（未公证）**。下载后若双击无法打开（Gatekeeper 拦截），在终端执行：

```bash
xattr -r -d com.apple.quarantine /path/to/PkgSender.app
codesign -f -s - --deep /path/to/PkgSender.app
```

即可在本机或其他 Mac 上运行。应用未启用沙盒（需读取 `/Volumes` 并监听入站端口）。

## 致谢

- 原项目 [Loopayeh/pkg-sender](https://github.com/Loopayeh/pkg-sender)（MIT）
- macOS 移植：CarlChina

## 已知限制

- 未做 Developer ID 签名与公证，跨机分发依赖上方两条命令
- 自动更新仅「提示 + 跳转下载页」，不自动下载安装
- 为读取 `/Volumes` 与监听端口，应用主动关闭了沙盒
