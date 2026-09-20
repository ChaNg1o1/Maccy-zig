<p align="center">
  <img src="assets/repo-header.png" alt="MaccyZig 仓库头图">
</p>

<h1 align="center">MaccyZig</h1>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white">
  <img alt="UI" src="https://img.shields.io/badge/UI-AppKit%20%2B%20Cocoa-5c6bc0">
</p>

MaccyZig 帮你在 macOS 上找回和复用复制过的内容。

它常驻菜单栏，自动保存可搜索的剪贴板历史，让你快速找回之前复制过的文字、链接、图片和文件，不用反复切换 App 或翻笔记。

## 下载

预构建的 macOS 版本会发布到 GitHub [Releases](https://github.com/ChaNg1o1/Maccy-zig/releases) 页面。你也可以在仓库页面右侧的 Releases 区域直接下载。

下载 `MaccyZig-*-macOS.zip`，解压后把 `MaccyZig.app` 移动到 `/Applications`。

## 你可以用它做什么

- 从 macOS 菜单栏打开剪贴板历史。
- 搜索最近复制过的文字、链接、图片和文件。
- 正常粘贴，也可以粘贴为纯文本。
- 把重要内容加入收藏，清理历史时不会丢失。
- 在使用图片前先预览。
- 历史太乱时，一键清空未收藏内容。
- 在设置菜单里调整历史数量上限。
- 调整窗口大小，并在下次打开时保留尺寸。
- 在英文和简体中文界面之间切换。

## 面向开发者

MaccyZig 使用 Zig、Objective-C、AppKit、Cocoa 和 SQLite 构建。仓库也提供 CLI 命令，用于捕获、监听、统计、列出、基准测试和导入现有 Maccy 数据。

## 环境要求

- 运行 App 需要 macOS 14 或更新版本。
- 从源码构建需要 Zig `0.16.0` 或兼容的近期构建。
- 编译 macOS 桥接代码需要 Xcode Command Line Tools。
- 需要在 `.signing-identity`（或 `CODESIGN_IDENTITY`）中固定一个代码签名身份，详见「代码签名与辅助功能权限」。

安装常用依赖：

```sh
xcode-select --install
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

生成 `dist/MaccyZig.app`：

```sh
./scripts/package-app.sh
```

打包脚本会：

- 以 `ReleaseFast` 构建 `maccy-zig`
- 在 `dist/MaccyZig.app` 创建 App bundle
- 复制 `resources/Info.plist`
- 生成 `AppIcon.icns`
- 从 `assets/menubar.svg` 渲染菜单栏模板图
- 使用固定的签名身份进行签名（先 `CODESIGN_IDENTITY`，其次 `.signing-identity`）

指定签名身份：

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/package-app.sh
```

### 代码签名与辅助功能权限

macOS 用 App 的 designated requirement 记录辅助功能授权。ad-hoc 签名没有证书，
它的 requirement 只是一串 `cdhash H"..."`，每次重新构建都会变：系统设置里
MaccyZig 依然是勾选状态，但 `AXIsProcessTrusted()` 返回 false，于是每次粘贴都
弹窗。用证书签名后，requirement 由 bundle id 和证书构成，跨重建、跨重装都保持
不变。

因此打包脚本不再自动猜测身份。只需固定一次：

```sh
security find-identity -v -p codesigning
echo "Apple Development: Your Name (TEAMID)" > .signing-identity   # 已 gitignore
```

临时测试仍可用 `CODESIGN_IDENTITY=-` 走 ad-hoc，脚本会明确警告。身份变更时，
`scripts/install-replace.sh` 会发现 requirement 不匹配并执行
`tccutil reset Accessibility`，你只需要重新授权一次。

## 本地安装

目前还没有已签名的公开下载包。如果想现在试用，需要先从源码构建并在本地安装打包后的 App。

用新打包的版本替换 `/Applications/MaccyZig.app`：

```sh
./scripts/install-replace.sh
```

该脚本会谨慎处理安装流程：

- 打包 App
- 在可用时导入现有 Maccy 剪贴板历史
- 备份已有的 `/Applications/MaccyZig.app`
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
--max-items N        未固定历史上限，默认 500
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

## Release 构建

推送类似 `v0.1.0` 的 tag，或在 Actions 页面手动运行 `Release` workflow，都会触发 GitHub Actions 创建发布版本。

CI 上没有签名证书，所以 release 包是显式以 ad-hoc 方式签名的（`CODESIGN_IDENTITY=-`）：首次打开需要按
release notes 里的步骤放行，并且每次升级后都要重新授予一次辅助功能权限——原因见上面的
「代码签名与辅助功能权限」。两个架构的最低系统版本都取自 `resources/Info.plist` 的
`LSMinimumSystemVersion`，`scripts/smoke-package.sh` 会校验二进制和它一致。

每个 release 会包含：

- `MaccyZig-<tag>-macOS.zip`
- `MaccyZig-<tag>-macOS.zip.sha256`
- 带小型 ASCII logo 和安装说明的 release notes

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

如果复选框已经勾选但粘贴仍然弹窗，说明 App 是 ad-hoc 签名的，参见「代码签名与
辅助功能权限」。

## Jev 智能推荐（可选，默认关闭）

在「设置 → 智能推荐」中打开后，每次唤出面板都会让
[TypeSafe 的 Jev 模型](https://docs.typesafe.ai/)判断：在你即将粘贴的那个应用里，
历史记录中哪一条才是你想要的，并直接预选它。Jev 返回的是候选行 id 上的类型化
choice，可以直接驱动选中逻辑。面板底部会显示选中了哪条以及置信度；
「操作… → 用 Jev 推荐要粘贴的内容」是同一个开关，方便不打开设置就切换。

在「设置 → 智能推荐」那一行左侧选择通过哪个服务调用 Jev，把对应的 API key 粘贴进去并点击
**保存并验证**：会先真实请求一次服务确认可用，通过后 key 才存进登录钥匙串（仅本机，不进
NSUserDefaults，也不进仓库），输入框随即清空。每个服务各存各的 key，来回切换不用重填。

三种服务说的是同一套 TypeSafe 报文，区别只有地址、模型名和凭证：

| 服务 | 请求地址 | 模型名 | 用什么 key |
| --- | --- | --- | --- |
| TypeSafe（直连） | `https://api.typesafe.ai/v1/systemone` | `jev-latest` | TypeSafe API key |
| Vercel AI Gateway | `https://ai-gateway.vercel.sh/typesafe/v1/systemone` | `typesafe-ai/jev` | AI Gateway API key |
| 自定义地址 | `<Base URL>/v1/systemone` | 默认 `jev-latest`，可改 | 上游服务要求的 key |

- **Vercel AI Gateway**：用的是它的
  [TypeSafe 兼容接口](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe)，不需要 TypeSafe 账号，
  在 Vercel 控制台的 AI Gateway 里创建 API key 即可。Vercel 按 TypeSafe 的标价计费、不加价，每个团队
  每月有免费额度，但免费额度只覆盖一部分模型——Jev 在不在其中以 Vercel 的
  [Free Tier 模型列表](https://vercel.com/ai-gateway/models?freeTier=true)为准。
- **Cloudflare AI Gateway**：选「自定义地址…」。先在 Cloudflare 的 AI Gateway 里建一个
  [Custom Provider](https://developers.cloudflare.com/ai-gateway/configuration/custom-providers/)，
  `base_url` 填 `https://api.typesafe.ai`，slug 比如 `typesafe`；然后 Base URL 填
  `https://gateway.ai.cloudflare.com/v1/<account_id>/<gateway_id>/custom-typesafe`，API key 仍然填
  TypeSafe 的 key（网关原样转发）。如果网关开了鉴权，把 `cf-aig-authorization` 和 `Bearer <token>` 填进
  「附加请求头」，它的值同样存在钥匙串里。Cloudflare 的网关本身免费（日志、缓存、限流），但它只是
  你自己 TypeSafe key 前面的一层代理，模型调用的费用仍由 TypeSafe 收取。
- 自定义地址只接受 `https://`：API key 和剪贴板预览都经过这个地址。

按 `$0.042 / 百万输入 token`、每次打开面板约 2k token 估算，一次推荐约 $0.0001。

发给 Jev 的每条候选带哪些上下文、结果怎么判定，见
[docs/jev-context.md](docs/jev-context.md)，里面有判定规则的实测数据。

Jev 选中某条时，底部显示 `✦ Jev 选中 · 98%`，另有最多两条次优候选在来源应用前带一个
淡 `✦`。你一旦自己开始选，迟到的建议就不会再抢走选中项；搜索过滤后会在更小的候选集上
重新问一次，而不是直接放弃；它看过但没有把握时不显示任何东西，
面板保持默认的置顶选中即可。只有你能处理的失败（缺 key、key 被拒、服务不可达）
才会在底部提示。

开启后会离开本机的数据：当前可见的前 12 条预览（每条 200 字符）、它们的来源
应用，以及目标应用、窗口标题、聚焦输入框内容（400 字符）和它正上方的屏幕文字（600 字符）。形似凭证的条目
（`sk-…`、`ghp_…`、`AKIA…`、PEM 私钥块、`password = …`、JWT）会直接从候选集中剔除，
不会发送；聚焦输入框里如果是凭证也不会回传。只有当某条明显胜过「都不合适」
选项、且明显领先第二名时才会显示推荐，否则选中行不动。

目标位置始终从两个来源描述：辅助功能（应用自己对输入框的说明）和屏幕（你实际看到的内容，
不管应用用什么技术栈写的）。后者通过 ScreenCaptureKit + Vision 读取粘贴落点正上方的一块窗口
区域 —— 落点依次取光标、聚焦输入框、鼠标指针 —— 约 200ms，且是在面板本来就在等数据的那段
时间里跑的；只识别并发送离落点最近的几行（最多 600 字符，形似凭证的行会被丢弃）。这需要
「屏幕录制」权限，在「设置 → 快捷键与权限」里和辅助功能那一项并排授权。
`maccy-zig ocr-check` 可以在你自己机器上量这条路径的耗时；「操作… → 查看 Jev 判断过程」
会打开一个实时检查器窗口：上方显示最近一次屏幕捕获的原图，下方是每次推荐的目标上下文、
发送的候选句子、返回的概率分布、接受或拒绝的判据和各段耗时。开着时重启也会自动回来，
不写任何文件。开着时还会记录每次鼠标按下落在了本应用的哪个窗口、哪个视图、当时应用是否处于活动状态，
排查「按钮点了没反应」就靠它；关闭时不存在任何鼠标监听。

每条候选还会带上出处（复制那一刻的窗口标题和页面/文件，仅在 Jev 开启时采集）、是否刚在
这里粘过、是否和刚粘过的条目是同一批复制的。每次粘贴都会留下一条评测样本；用 App 包内的
二进制运行 `maccy-zig jev-eval`，可以把这些样本重放到当前的提问方式上，给出精度和「抢错行」
次数；`maccy-zig jev-context` 会打印 Jev 在当前聚焦输入框上到底看到了什么。

离线校验脱敏与置信度逻辑：

```sh
./zig-out/bin/maccy-zig jev-self-check
```

校验各窗口里的每个控件是否真的点得到：在屏幕外构建真实的设置窗口和主面板（中英文各一遍），
按 AppKit 自己的方式对每个控件上的多个点做 hit-test —— 不显示任何窗口，也不触发任何点击。
加上 `MZ_UI_SNAPSHOT_DIR=<目录>` 还会把每个窗口渲染成 PNG 存到该目录：

```sh
./zig-out/bin/maccy-zig ui-self-check
```

然后添加或启用 `MaccyZig.app`。

## 发布检查清单

发布到 GitHub 前：

- 运行 `zig build test`。
- 运行 `./zig-out/bin/maccy-zig jev-self-check` 和 `./zig-out/bin/maccy-zig ui-self-check`。
- 运行 `./scripts/smoke-package.sh`。
- 运行 `./scripts/smoke-bundle-launch.sh`。
- 在干净的 macOS 账号或机器上验证打包后的 App。
- 确认打包产物的 bundle identifier 是 `io.github.chang1o1.MaccyZig`（与原版 Maccy 区分，确保 TCC 授权独立）。

## 许可证

MaccyZig 使用 MIT License。详情见 [LICENSE](LICENSE)。
