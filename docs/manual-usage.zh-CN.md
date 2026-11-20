# 手动使用、快捷键与构建指南

[English](manual-usage.md) · 简体中文 · [返回 README](../README.zh-CN.md)

脱离 AI Agent 时，Peek 也可以直接在任意本地终端、脚本或远程 SSH 会话中独立使用。

## 本地命令行

确认 `peek` 已链接至 `PATH`：

```sh
mkdir -p "$HOME/bin"
ln -sfn "/Applications/Peek.app/Contents/MacOS/Peek" "$HOME/bin/peek"
```

发送本机图片（`png`、`jpg`、`webp`、`gif`、`heic`、`svg`、`avif`、`tiff`、`bmp`）、PDF、Markdown 或 HTML：

```sh
peek screenshot.png
peek report.pdf
peek report.md
peek page.html
peek -t "设计对比" before.png after.png    # 多个文件合并为同一张卡片
peek -c "项目A" -t "检查结果" report.html   # 自定义顶部来源名与卡片标题
```

未指定 `-t` 时，单文件卡片会自动提取 HTML 的 `<title>`、Markdown 的首个 `# ` 标题或文件名。文档同目录下引用的本地 CSS、JS、图片会随快照一并保存，后续覆盖原文件不会影响已有卡片。

管理卡片与后台应用：

```sh
peek --remote-settings   # 打开「远程机器」连接窗口
peek --list              # 列出 24 小时内的卡片
peek --clear             # 清空全部卡片与缓存快照
peek --quit              # 退出菜单栏后台应用
```

## SSH 远程发送

直接复用系统 `/usr/bin/ssh`（沿用 `~/.ssh/config`、密钥、SSH agent 与跳板机），从远程 Linux 或 macOS（`amd64` / `arm64`）向本机推文件，无需账号、中继服务或 Mac 入站端口：

Agent 可在接收端 Mac 上直接管理连接，无需打开窗口：

```sh
peek remote add user@server --name "构建机" --wait --json
peek remote list --json
peek remote command "构建机"
peek remote disconnect "构建机"
peek remote connect "构建机" --wait
peek remote remove "构建机"
```

可用名称、SSH 地址或连接 ID 指定主机。`--wait` 等待安装并连接成功，`--timeout <秒数>` 调整等待时限（默认 60，最多 300 秒）；失败退出码为非零。`remote command` 输出包含当前 Mac 接收端 UUID 的远端发送命令。

手动连接方式：

1. 点击菜单栏 Peek 图标 →「远程机器…」，或执行 `peek --remote-settings`。
2. 输入 SSH 别名、`user@host` 或 `user@host:port` 并点击「连接」。首次遇到未知主机指纹或需要密码时使用系统原生验证窗口，密码不会落盘保存。
3. 点击「拷贝命令」，粘贴到远程终端并在末尾附上文件路径：

```sh
'/home/me/.local/bin/peek' --to '<接收端UUID>' report.html chart.png
```

更多远程发送用法：

```sh
peek -t '检查结果' -c '服务A' report.html screenshot.png
peek --list-targets
peek --to <接收端UUID> report.md
PEEK_TARGET=<接收端UUID> peek report.pdf
```

- 同一台远程主机只连接了一台 Mac 时可省略 `--to`；多台 Mac 同时连接同一主机时需显式指定 UUID 或唯一名称。
- HTML / Markdown 引用的本地资源随文档一同传输（单次最多 300 个文件、总计 64 MiB；符号链接不会越过文档根目录）。
- 收到的原始文件保存在 `~/Downloads/Peek/<主机>/<时间>_<标题>_<短ID>/`；卡片快照遵循 24 小时缓存清理规则，Downloads 中的原文件保留。
- 更多细节参考：[local-usage.md](local-usage.md) · [remote-forwarding.md](remote-forwarding.md)。

## 卡片与查看器操作

- **卡片手势** — 点击打开第一个文件 · `⌥`+点击在访达中显示 · 直接从卡片拖拽文件到其他 App · 双指右滑关闭 · 右键打开菜单（打开、回到对话、在访达中显示、拷贝、暂时收起、关闭）。
- **样式与布局** — 菜单栏支持切换「大图 / 简洁 / 照片」三种卡片样式，以及「叠放 / 竖排列表」模式。
- **暂时收起** — 将整摞卡片收进屏幕右边缘小把手，鼠标移入自动展开预览、移开收回。
- **自动生命周期** — 未读卡片带圆点标记。最新一张未读卡片 5 分钟内未打开，整摞卡片就会缩成右侧小把手，鼠标移入即可展开。已读卡片静置 5 分钟后自动离开屏幕。同屏最多显示 3 张，超出自动排队。`~/Library/Caches/Peek/` 下的快照满 24 小时自动清理。
- **查看器** — 双击图片可在适应窗口和原始像素之间切换。在触控板上双指张开或捏合可连续缩放，双指轻点两下可放大指针所在位置，再轻点两下恢复整图。也可用 `⌘±` 缩放，用滚轮或双指左右滑切换文件，按 `⌘D` 并排对比图片。宽窗口中，在右侧预览上双指上滑切到下一条，下滑回到上一条。长文档滚到相应边缘后，再滑一次即可切换。左侧可滚动浏览缩略图，点击后查看对应文件。`⌘C` 拷贝成功后会短暂显示提示。Markdown / HTML 内的外部网页链接调用系统默认浏览器打开。

## 快捷键

全局快捷键基于 Carbon 注册，无需辅助功能权限：

| 快捷键 | 范围 | 操作 |
| --- | --- | --- |
| `⌥⌘P` | 全局 | 打开最新卡片的详情 |
| `⌃⌥H` | 全局 | 暂时收起或恢复卡片堆叠 |
| `⌃⌥X` | 全局 | 关闭全部卡片 |
| `⎋` / `Space` | 查看器 | 关闭查看器并恢复显示卡片 |
| `⌘W` / `⌘⌫` | 查看器 | 关闭查看器并收走当前卡片 |
| `←` `→` / 左右滑 | 查看器 | 切换当前卡片内的文件 |
| `↑` `↓` | 查看器 | 切换文件（单文件卡片时切换卡片） |
| `⌥↑` `⌥↓` | 查看器 | 切换上一张 / 下一张卡片 |
| `⌘D` | 查看器 | 切换多图并排对比 |
| `⌘0` / `⌘1` / `⌘±` | 查看器 | 适应窗口 / 原始像素 / 缩放 |
| `⌘C` / `⌘R` / `↩` | 查看器 | 拷贝 / 在访达中显示 / 回到对话 |
| `?` | 查看器 | 显示或隐藏快捷键速查表 |

## 参数调整（`defaults`）

```sh
defaults write com.terryops.peek hotkeyOpen "opt+cmd+p"    # 设为 "" 可关闭对应全局快捷键
defaults write com.terryops.peek hotkeyTuck "ctrl+opt+h"
defaults write com.terryops.peek hotkeyCloseAll "ctrl+opt+x"
defaults write com.terryops.peek lingerSeconds -float 300
defaults write com.terryops.peek maxCards -int 3
defaults write com.terryops.peek style rich                # rich | compact | photo
defaults write com.terryops.peek stacking deck             # deck | list
defaults write com.terryops.peek language zh               # zh | en（默认跟随系统语言）
```

## 源码构建与测试

构建需要 macOS 14+、Swift 6.0+（Xcode）与 Go 1.24+（交叉编译无第三方依赖的 `darwin` / `linux` × `amd64` / `arm64` 远程 helper）。

```sh
./Scripts/install.sh                        # 编译、自检并安装 ~/Applications/Peek.app + LaunchAgent + ~/bin/peek
./Scripts/install.sh --prebuilt /path/Peek.app
./Scripts/build.sh                          # 仅构建 build/Peek.app
PEEK_UNIVERSAL=1 ./Scripts/build.sh         # 构建 arm64 + x86_64 通用 Mac 二进制
PEEK_HOME="$(mktemp -d)" swift test
(cd Remote && go test -race ./... && go vet ./...)
```
