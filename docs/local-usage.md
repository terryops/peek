# 本地使用

Peek 在本机预览图片、PDF、Markdown 和 HTML，不需要连接远程机器。Rex、AI agent 和 Claude Code hook 都是可选集成。

## 安装命令

下载并解压 [Mac 安装包](https://github.com/terryops/peek/releases/latest)，将 `Peek.app` 放进「应用程序」并打开。可在菜单栏点击「安装 peek 命令」并勾选「登录时打开」，或在终端执行：

```sh
mkdir -p "$HOME/bin"
ln -sfn "/Applications/Peek.app/Contents/MacOS/Peek" "$HOME/bin/peek"
export PATH="$HOME/bin:$PATH"
```

将 `export PATH="$HOME/bin:$PATH"` 加入 `~/.zprofile`，新终端也能使用。通过仓库的 `Scripts/install.sh` 安装时会自动创建命令和开机启动项；终端同样需要包含 `~/bin` 的 PATH。

## 发送文件

```sh
peek screenshot.png
peek report.pdf
peek report.md
peek page.html
peek -t "设计对比" before.png after.png
peek -c "项目名称" -t "检查结果" report.md
```

多个文件放进同一张卡片。点击卡片打开查看器；多张图片可并排对比，HTML / Markdown 的本地引用资源随卡片保存。可在终端或 AI agent 中调用同一个命令。

```sh
peek --list    # 列出卡片
peek --clear   # 清空卡片
peek --quit    # 退出后台 App
```

卡片快照保存在 `~/Library/Caches/Peek/`，超过24小时清理。查看器按 Esc 关闭，⌘C 拷贝，⌘R 在访达中显示。
