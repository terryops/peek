# 远程文件

Peek 在 Mac 上接收 SSH 主机生成的图片、PDF、Markdown 和 HTML。需要 macOS 14 或更新版本；远程机器支持 Linux / macOS、amd64 / arm64。不需要账号、中继服务、Mac 的 SSH 服务或入站端口。

## 安装现成 App

解压分发包，将 `Peek.app` 放进「应用程序」并双击打开。Peek 在菜单栏运行，可直接从菜单启用「登录时打开」、点击「安装 peek 命令」，或进入「远程机器…」。使用现成 App 不需要仓库、Swift 或 Go。

## 首次连接

1. 打开菜单栏 Peek →「远程机器…」，或执行 `peek --remote-settings`。
2. 输入 SSH 别名、`user@host` 或 `user@host:port`，点「连接」。Peek 使用系统 SSH，沿用 `~/.ssh/config`、跳板机、密钥和 SSH agent。
3. 首次遇到未知主机时，核对原生验证窗口里的指纹后再信任。密码和私钥口令使用安全输入框，不会保存。取消验证会停止本次连接，可以手动重试。
4. 连接后点「拷贝命令」，在远程终端粘贴并在末尾加文件路径。例如：

   ```sh
   '/home/me/.local/bin/peek' --to '接收端UUID' report.html
   ```

   拷贝的是实际安装路径，已经处理 shell 引号，并明确指定当前 Mac。不要再给整条命令套引号。

远程 helper 放在 `~/.local/share/peek/bin/peek-remote`，并尽可能安装 `~/.local/bin/peek`。已有同名的其他程序不会被替换；这时窗口提供可用的完整备用路径。连接断开后，命令会报未连接，不会假装已送达。

## 发送

```sh
peek -t '检查结果' -c '项目A' report.html screenshot.png
peek --list-targets
peek --to 接收端UUID report.md
PEEK_TARGET=接收端UUID peek report.pdf
```

只有一个在线接收端时可以省略 `--to`；多个 Mac 同时连接同一主机时必须明确选择 UUID 或唯一名称。窗口拷贝的命令始终带当前 Mac 的 UUID。

HTML、Markdown 引用的本地资源随文件发送，每份文档保留各自资源目录。每次最多 300 个文件、总计 64 MiB；资源计入限制。符号链接资源不会越过文档根目录。发送端等到接收端完整校验、生成卡片并确认后才显示成功。传输中断不会生成残缺卡片。

收到的原始文件保存在 `~/Downloads/Peek/<主机>/<时间>_<标题>_<短ID>/`；卡片快照沿用 Peek 的 24 小时缓存规则，Downloads 文件保留。远程来源默认显示为 `<主机> · <项目名>`，不提供本机「回到对话」操作。断开或移除连接仅关闭 Peek 自己的 SSH 会话，保留已收到的文件和卡片。已连接主机在网络中断后自动重连（远端 `peek-remote` 未变更时跳过重复上传）；取消、认证取消、移除和退出会停止对应重试。

连接配置在 `~/Library/Application Support/Peek/remote-hosts.json`，仅当前用户可读写。配置写入失败会在原位置显示错误；无法保存移除时保留连接行，以便再次操作。

## 构建与安装

```sh
./Scripts/build.sh
./Scripts/install.sh
./Scripts/install.sh --prebuilt /完整路径/Peek.app
PEEK_UNIVERSAL=1 ./Scripts/build.sh
PEEK_UNIVERSAL=1 PEEK_SIGN_IDENTITY='Developer ID Application: …' ./Scripts/build.sh
```

构建需要 Xcode 的 Swift 工具链和 Go，打包四种远程 helper 以及可执行的 `ssh-askpass`。默认构建当前 Mac 架构；`PEEK_UNIVERSAL=1` 通过 Swift `--triple` 分别编译 arm64 / x86_64，再合并 Mac 接收端。Go helper 按远程平台各自提供。

安装会先校验签名、资源和运行自检，再更新 `~/Applications/Peek.app`、LaunchAgent 和 `~/bin/peek`，保留缓存、卡片和连接配置。`--prebuilt` 不进行编译，可直接安装另一台机器构建的包。

默认 ad-hoc 签名用于开发和本机验证。`PEEK_SIGN_IDENTITY` 会给 Darwin helper 和 App 使用指定身份、hardened runtime 和时间戳；对外分发仍需所有者自己的 Developer ID、公证和 stapling 流程。这里不包含公证凭据，也不代表已经公证或公开发布。
