# PkgSenderMac

[Loopayeh/pkg-sender](https://github.com/Loopayeh/pkg-sender)（Windows / .NET / Avalonia）的原生 macOS 移植版。  
Swift 6 + SwiftUI，零第三方依赖，Apple Silicon 与 Intel 通用。

- **系统要求**：macOS 12 Monterey 或更高
- **架构**：Universal（arm64 + x86_64）
- **界面语言**：English / 简体中文 / 繁體中文 / 日本語

[English README](README.md)

---

## 快速开始

```bash
cd PkgSenderMac
./build.sh --arch auto     # 构建（推荐：自动适配本机工具链）
open build/PkgSender.app
```

`--arch auto` 会构建本机工具链能链接的架构。Apple Silicon + 纯 Command Line Tools  
的环境只能产出 arm64；装了完整 Xcode 即可得到 Universal 包。

其他用法：

```bash
./build.sh                 # 强制 arm64 + x86_64（需要完整 Xcode）
./build.sh --arch arm64    # 仅 Apple Silicon（最快）
./build.sh --arch x86_64   # 仅 Intel
```

---

## 使用

1. 顶部填主机 IP（PS5 / PS4），点 `测试` 确认连通；`探测` 自动搜索局域网主机。
2. 点 **`+ 添加文件夹`** 选择目录 —— **选完立即开始扫描**，无需再点扫描。  
   要扫整块磁盘用菜单 `媒体库 ▸ 扫描驱动器…`（⌘D）。
3. 卡片网格显示结果：
   - **单击**选中，**⌘-单击** 多选，**⇧-单击** 连选，**双击** 发送
   - 菜单 `媒体库` 提供 全选 ⌘A / 反选 ⌘⇧I / 全不选 ⌘.
4. 多选后 `发送 PKG`（⌘S）入队。PS5 走 Range 服务推送，PS4 走 RPI / GoldHEN。
5. 镜像文件（`.exfat` / `.ffpkg` / `.ffpfsc`）用 `复制镜像`（⌘I）送到主机  
   `/data/homebrew`，支持续传与覆盖。

队列行可 ⏸ 暂停 / ▶ 继续 / ✕ 移除 / ▲▼ 重排；`全部暂停` 一次冻结所有任务。  
暂停是可续传的 —— 主机从断点继续，不会重下。

菜单栏右侧可切换界面语言（默认跟随系统）。

---

## 工程结构

```
PkgSenderMac/
├── Package.swift              # SPM 描述，platforms: [.macOS(.v12)]
├── build.sh                   # 构建 + 打包 .app + 生成图标 + 签名
├── Sources/
│   ├── PkgSenderCore/         # 纯 Swift 核心库（无 UI，可单测、可 CLI 复用）
│   │   ├── Models/            # GameItem / QueueEntry / AppSettings / 格式化
│   │   ├── Parsing/           # PKG 解析：SFO、param.json、CNT/EXFAT、图标与摘要
│   │   ├── Networking/        # HTTP Range 服务、PS5 客户端、PS4 RPI/GoldHEN、网段发现
│   │   └── Services/          # 媒体库扫描、设置持久化
│   └── PkgSenderApp/          # 可执行目标（SwiftUI + AppKit）
│       ├── PkgSenderApp.swift # @main / AppDelegate / 菜单命令
│       ├── AppModel.swift     # @MainActor ObservableObject，全局状态与队列驱动
│       ├── RootView.swift     # 主窗口：header / 工具栏 / 状态栏 / 拖放
│       ├── LibraryPanel.swift # 卡片网格、搜索筛选、多选手势
│       ├── QueuePanel.swift   # 发送队列、进度、暂停/重排
│       ├── Dialogs.swift      # About / 指南 / 切主机 / 续传覆盖
│       ├── AppTheme.swift     # 设计令牌与通用控件
│       ├── L10n.swift         # 运行时本地化（4 语）
│       ├── AppSupport.swift   # NSOpenPanel / 剪贴板 / 通知 封装
│       ├── LoginItemManager.swift
│       ├── UpdateService.swift  # 仅保留版本号
│       └── Resources/         # 图标、GoldHEN 载荷、{en,zh-Hans,zh-Hant,ja}.lproj
├── Tests/PkgSenderCoreTests/  # 核心库单测
└── build/PkgSender.app        # 产物
```

核心库不依赖任何第三方包；应用只依赖核心库与系统框架。网络层基于  
`URLSession` + BSD sockets，没有引入 SwiftNIO 等。

---

## 实现要点

| 能力             | macOS 实现                                                                                               |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| 文件服务器          | 自实现 HTTP/1.1（`RangeHTTPServer`）：GET/HEAD、`/pkg/{id}`、`/catalog`，支持 Range `200/206/416`、keep-alive、断点续传 |
| PS5 推送         | `URLSession` 调 `12800/9090`：`/api`、`/api/install`、`/api/files/pull`                                    |
| PS4 推送         | RPI `POST /api/install`；失败则 GoldHEN binloader 注入 + bin 层 manifest                                      |
| 主机发现           | `getifaddrs` 取真实 IPv4，排除 `lo0`/虚拟网卡；UDP 12801 beacon + TCP 探测                                          |
| 开机自启           | macOS 13+ `SMAppService.mainApp`；12 降级写 LaunchAgent plist                                              |
| 通知 / 剪贴板 / 对话框 | `UNUserNotificationCenter` / `NSPasteboard` / `NSOpenPanel`                                            |

相对上游修复了两个问题：拖放镜像文件被忽略；老式 PS4 包（`\x7FPKG` 魔数）被跳过。

### macOS 12 兼容

- 部署目标固定 `arm64/x86_64-apple-macosx12.0`，经 `otool` 确认 `minos 12.0`。
- 不用 Observation、`NavigationSplitView`、`ShareLink`、`#Preview`；  
  状态全部走 `@MainActor ObservableObject` + `@Published`。
- `onChange` 必须是**单参数**形式（双参数是 macOS 14+）。
- `@FocusState` 的投影值不是 `Binding<Bool>`，不能直接传给需要 `Binding` 的参数。

---

## 多国语言

界面语言可在菜单栏 `Language` 切换 —— macOS 没有 per-app 语言覆盖，所以是在应用内实现的，  
无需改系统设置。默认跟随系统，`zh-Hant-TW` 这类会正确回退到繁体。

字符串在 `Sources/PkgSenderApp/Resources/<lang>.lproj/Localizable.strings`，  
用标准 macOS 布局，`genstrings` / Xcode 可直接提取。**新增或修改翻译后需重新  
`./build.sh`**（`.lproj` 会被拷进 `PkgSenderMac_PkgSenderApp.bundle`）。

---

## 分发

`build.sh` 产出的 app 是 **ad-hoc 签名**，拷到别的 Mac 会被加上隔离属性。  
分享前请去掉隔离标记并重新签名：

```bash
xattr -r -d com.apple.quarantine /Applications//PkgSender.app
codesign -f -s - --deep /Applications//PkgSender.app
```

---

## 测试与限制

核心库配有 XCTest（`Tests/PkgSenderCoreTests`）。纯 Command Line Tools 环境的  
macOS SDK 不含 XCTest，需在**完整 Xcode** 中 `xcodebuild test` 运行。

已知限制：

- PS4 GoldHEN 路径依赖主机侧开启 Payload Server / BinLoader，且主机需能回调 PC  
  （防火墙或隔离网络会导致"已注入但未回调"）。
- 暂停/继续后主机端也需在主机上手动继续（与上游行为一致）。
- 锁屏或无窗口环境下无法用截图/自动化验证点击行为。
