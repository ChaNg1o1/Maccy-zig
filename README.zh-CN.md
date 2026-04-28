# MaccyZig

[English](README.md) | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)
![UI](https://img.shields.io/badge/UI-AppKit%20%2B%20Cocoa-5c6bc0)

![MaccyZig 仓库头图](assets/repo-header.png)

MaccyZig 帮你在 macOS 上找回和复用复制过的内容。

它常驻菜单栏，自动保存可搜索的剪贴板历史，让你快速找回之前复制过的文字、链接、图片和文件，不用反复切换 App 或翻笔记。

## 你可以用它做什么

- 从 macOS 菜单栏打开剪贴板历史。
- 搜索最近复制过的文字、链接、图片和文件。
- 正常粘贴，也可以粘贴为纯文本。
- 把重要内容加入收藏，清理历史时不会丢失。
- 在使用图片前先预览。
- 历史太乱时，一键清空未收藏内容。
- 调整窗口大小，并在下次打开时保留尺寸。
- 在英文和简体中文界面之间切换。

## 面向开发者

MaccyZig 使用 Zig、Objective-C、AppKit、Cocoa 和 SQLite 构建。仓库也提供 CLI 命令，用于捕获、监听、统计、列出、基准测试和导入现有 Maccy 数据。

## 环境要求

- 运行 App 需要 macOS 14 或更新版本。
- 从源码构建需要 Zig `0.16.0` 或兼容的近期构建。
- 编译 macOS 桥接代码需要 Xcode Command Line Tools。
- 打包菜单栏图标需要 ImageMagick（`magick`）。
- 打包脚本会使用有效的 Apple Development 签名身份；没有时会使用 ad-hoc 签名兜底。

安装常用依赖：

```sh
xcode-select --install
brew install imagemagick
```

## 构建

构建开发版二进制：

```sh
zig build
```

从构建产物运行 App：

```sh
zig build run
```

构建优化版：

```sh
zig build -Doptimize=ReleaseFast
```

## 打包 App

生成 `dist/Maccy.app`：

```sh
./scripts/package-app.sh
```

打包脚本会：

- 以 `ReleaseFast` 构建 `maccy-zig`
- 在 `dist/Maccy.app` 创建 App bundle
- 复制 `resources/Info.plist`
- 生成 `AppIcon.icns`
- 从 `assets/menubar.svg` 渲染菜单栏模板图
- 使用 `CODESIGN_IDENTITY`、第一个 Apple Development 身份或 ad-hoc 签名进行签名

指定签名身份：

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/package-app.sh
```

## 本地安装

目前还没有已签名的公开下载包。如果想现在试用，需要先从源码构建并在本地安装打包后的 App。

用新打包的版本替换 `/Applications/Maccy.app`：

```sh
./scripts/install-replace.sh
```

该脚本会谨慎处理安装流程：

- 打包 App
- 在可用时导入现有 Maccy 剪贴板历史
- 备份已有的 `/Applications/Maccy.app`
- 备份原 Maccy SQLite 数据和偏好设置
- 在备份目录中写入 `restore.sh`
- 安装并打开新 App

备份路径：

```text
~/Backups/MaccyZig-YYYYMMDD-HHMMSS/
```

恢复旧版本：

```sh
~/Backups/MaccyZig-YYYYMMDD-HHMMSS/restore.sh
```

## 开发者 CLI

查看帮助：

```sh
./zig-out/bin/maccy-zig --help
```

捕获当前剪贴板一次：

```sh
zig build run -- once
```

持续监听剪贴板：

```sh
./zig-out/bin/maccy-zig watch --max-blob-mib 4
```

列出历史条目：

```sh
./zig-out/bin/maccy-zig list
```

查看存储统计：

```sh
./zig-out/bin/maccy-zig stats
```

使用自定义数据库路径：

```sh
./zig-out/bin/maccy-zig watch --db /tmp/maccy-zig.sqlite
```

常用选项：

```text
--db PATH            SQLite 路径
--interval-ms N      watch 轮询间隔，默认 500
--max-items N        未固定历史上限，默认 200
--max-blob-mib N     跳过超过 N MiB 的单个剪贴板 blob，默认 16
--max-age-days N     自动删除超过 N 天的未固定条目，默认 0 = 关闭
--no-images          仅存储 text/html/rtf/文件 URL
```

## 验证

运行单元测试：

```sh
zig build test
```

Smoke test 打包结果：

```sh
./scripts/smoke-package.sh
```

Smoke test 启动：

```sh
./scripts/smoke-bundle-launch.sh
```

验证产物会写入：

```text
dist/verification/
```

## 项目结构

```text
.
├── build.zig
├── assets/
│   ├── logo.png
│   ├── logo-mark.png
│   ├── logo-thumb.png
│   └── menubar.svg
├── resources/
│   └── Info.plist
├── scripts/
│   ├── package-app.sh
│   ├── install-replace.sh
│   ├── smoke-package.sh
│   └── smoke-bundle-launch.sh
└── src/
    ├── main.zig
    ├── capture_service.zig
    ├── storage.zig
    ├── macos_app.m
    ├── macos_clipboard.m
    ├── macos_hotkey.m
    └── macos_paste.m
```

## 数据存储

默认数据库路径：

```text
~/Library/Application Support/MaccyZig/Storage.sqlite
```

数据库使用 WAL 模式，元数据存放在 `history_items`，剪贴板内容存放在 `history_contents`。

## 权限

和其他剪贴板管理器一样，本应用会读取系统剪贴板。根据目标应用和粘贴路径，执行粘贴操作时可能需要 macOS 辅助功能权限。

如果粘贴动作不可用，请打开：

```text
系统设置 -> 隐私与安全性 -> 辅助功能
```

然后添加或启用 `Maccy.app`。

## 发布检查清单

发布到 GitHub 前：

- 运行 `zig build test`。
- 运行 `./scripts/smoke-package.sh`。
- 运行 `./scripts/smoke-bundle-launch.sh`。
- 在干净的 macOS 账号或机器上验证打包后的 App。
- 决定 bundle identifier 是否继续使用 `org.p0deje.Maccy`，或改为项目专属 identifier。

## 许可证

MaccyZig 使用 MIT License。详情见 [LICENSE](LICENSE)。
