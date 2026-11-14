# Peek

Peek 是 macOS 的文件预览工具。图片、PDF、Markdown 和 HTML 先出现在屏幕右上角的浮动卡片，点击后在自带查看器打开。支持本地命令和 SSH 远程发送，可以独立使用，也可以接入 AI agent、终端或 Rex。

需要 macOS 26 或更新版本。Mac 接收端支持 Apple Silicon / Intel，远程发送端支持 Linux / macOS 的 amd64 / arm64；无需账号或中继服务。

## 下载

从 [GitHub Releases](https://github.com/terryops/peek/releases/latest) 下载 `Peek-universal.zip`，解压后将 `Peek.app` 放入「应用程序」并双击打开。Peek 在菜单栏运行，没有 Dock 图标。分发的 Mac App 已完成 Developer ID 签名和 Apple 公证。

## 远程快速开始

1. 菜单栏 Peek →「远程机器…」，输入 SSH 别名或 `user@host`，点「连接」。
2. 连接后点「拷贝命令」，在远程终端粘贴，并在末尾加要发送的文件路径。
3. 收到的文件出现在本机右上角，点击卡片查看。HTML / Markdown 的本地引用资源会一起传输。

沿用系统 SSH 配置、密钥和跳板机。未知指纹和密码使用原生验证窗口，密码不会保存。完整说明见 [远程文件](docs/remote-forwarding.md)。

## 用法

```sh
peek 文件…                          # 图片 / PDF / Markdown / HTML；多个文件一起推 = 一张卡
peek -t "登录页 修复后" a.png b.png   # 卡片标题（不给时：HTML 取 <title>，Markdown 取第一个 # 标题，否则文件名）
peek -c "对话名" x.png               # 指定来源对话名（一般不用，自动识别）
peek --remote-settings              # 管理远程机器；没有卡片时菜单栏仍可打开
peek --list | --clear | --quit
```

Claude Code 会话里不用改习惯：`open x.png / x.pdf / x.md / x.html`、`open -a Preview …`、`qlmanage -p …`
会自动变成卡片（SessionStart hook 把 `Peek.app/Contents/Resources/shim` 放到该会话 Bash 的 PATH 最前面）。
网址、文件夹、其他类型、`open -R`、`-a 其他 App` 原样交给 `/usr/bin/open`。`PEEK_OFF=1` 临时关掉。

## 卡片

- 每张卡顶部是**来源对话**：`/rename` 起的名 > Rex 里改过名的窗格 > 这段对话的第一句话
- 三种样式（菜单栏 → 卡片样式）：**大图**（默认，整张截图垫在自身模糊背景上）/ **简洁**（一行）/ **照片**（图就是卡）
- 叠放（默认）：最新一张在前，旧的露出边，鼠标移上去展开；菜单里可关掉叠放改成竖排
- 点：打开；⌥点：访达；拖：把文件拖去别的 App；两指右划：关掉；右键：打开 / 回到对话 / 访达 / 拷贝 / 暂时收起 / 关闭
- 没看过的一直留着（蓝点），看过的 5 分钟没碰自己收走；最多 3 张，多的排队
- 暂时收起：整摞缩进右边缘小把手，鼠标移上去展开、移开收回；「保持展开」或点把手恢复

## 查看器

- 图片：双击 适应 ↔ 1:1 像素，捏合 / ⌘± 缩放，← → 切换，底部缩略图条；多张可「并排对比」
- 外接屏上打开多张图片时默认并排对比；可用工具栏或 ⌘D 切回单张。单张查看时，鼠标滚轮向上 / 向下切换上一张 / 下一张图片（循环）；放大图片、PDF 和网页仍正常滚动
- 详情窗口：双指左滑下一张、右滑上一张（同一卡片内循环切换），拖动跟手、松手滑入、短滑或取消回弹；上下滑动仍滚动文档，图片 / PDF 放大后、网页含横向滚动内容时保留横向滚动
- PDF（PDFKit）、Markdown（marked 渲染，深色排版）、HTML（WebKit，本地 css/js/图片随卡片复制；外链在浏览器打开）
- 工具栏：拷贝、在访达中显示、**回到对话**（Rex 里直接跳到那个窗格；其他终端切到对应 App）。点了会关掉查看器、这张卡记为已读；从卡片右键「回到对话」则已读并收走卡片
- 打开时接管键盘；点关闭按钮或按 ⌘W 关闭详情并收走这张卡，Esc / 空格仅关闭详情。关掉后焦点回到原来的 App，不抢前台

## 快捷键

- 全局：⌃⌥P 打开最新一张（再按关掉）· ⌃⌥H 暂时收起 / 恢复 · ⌃⌥X 全部关闭（`defaults write com.terryops.peek hotkeyOpen "ctrl+opt+p"` 可改，"" 关掉）
- 查看器：⎋ / 空格 关闭详情 · ← → 卡内切换 · ↑ ↓ 上一张 / 下一张卡 · ↩ 回到对话 · ⌘C 拷贝 · ⌘R 访达 · ⌘D 并排 · ⌘W / ⌘⌫ 关闭并收走 · ⌘0 / ⌘1 / ⌘± 缩放 · ? 快捷键表

## 存放与清理

- `~/Library/Caches/Peek/items/<id>/files/`（APFS 克隆；原文件被覆盖不影响卡片），超过 24 小时自动删
- 调参：`defaults write com.terryops.peek lingerSeconds -float 300`、`maxCards -int 3`、`style rich|compact|photo`、`stacking deck|list`

## 远程机器

菜单栏 →「远程机器…」→ 输入 SSH 主机 →「连接」。连接后拷贝命令，在远程终端末尾加文件路径即可推回本机。沿用系统 SSH 配置、密钥和跳板机；未知指纹与密码使用原生验证窗口。无需中继服务或 Mac 入站端口。

连接支持取消、重试、断开和移除；移除保留已收到的文件。多台 Mac 使用显式 `--to` 路由，窗口拷贝的命令已经带上本机目标。完整用法、限制和分发说明见 [远程文件](docs/remote-forwarding.md)。

## 安装 / 更新

```sh
./Scripts/install.sh --prebuilt /path/Peek.app  # 安装已有包，不重新编译
./Scripts/install.sh   # 编译 + 自检 + ~/Applications/Peek.app + LaunchAgent(com.terryops.peek) + ~/bin/peek
```

构建需要 Xcode 的 Swift 6.2+ 工具链和 Go 1.24+。开发构建默认 ad-hoc 签名；分发签名和通用构建参数见 [远程文件](docs/remote-forwarding.md)。

Claude Code 的可选 SessionStart hook 可参照 `Resources/hooks/session-start.sh` 配置。Markdown 渲染使用 vendored `Resources/web/marked.js`（marked 18.2.0，MIT）。
调试：`peek --debug dump`（状态写到 `~/Library/Caches/Peek/debug.json`）。

## 测试

```sh
swift test
(cd Remote && go test ./... && go test -race ./... && go vet ./...)
```

默认测试使用本地临时目录和进程，不需要远程主机。实际 SSH 认证取消集成测试可显式设置 `PEEK_TEST_ASKPASS_SSH_HOST=user@host`，只应使用自己控制、已验证指纹的主机。

## 许可

Peek 以 [MIT License](LICENSE) 开源。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
