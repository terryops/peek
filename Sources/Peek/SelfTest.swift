import AppKit

/// `PEEK_HOME=/tmp/x peek --selftest` — exercises the store and CLI against a
/// throwaway folder. Refuses to run against the real cache.
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1; print("✓ \(what)") } else { failures += 1; print("✗ \(what)") }
    }

    static func run() -> Int32 {
        failures = 0
        passes = 0
        L10n.override = .zh
        defer { L10n.override = nil }
        guard let home = ProcessInfo.processInfo.environment["PEEK_HOME"], !home.isEmpty,
              Paths.root.path.hasPrefix(home) else {
            print("✗ 需要 PEEK_HOME 指向临时目录")
            return 2
        }
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.root)
        Paths.ensure()

        // Relative time (zh + en)
        let now = Date()
        check(RelativeTime.string(now.addingTimeInterval(-10), now: now) == "刚刚", "刚刚")
        check(RelativeTime.string(now.addingTimeInterval(-300), now: now) == "5 分钟前", "5 分钟前")
        L10n.override = .en
        check(RelativeTime.string(now.addingTimeInterval(-10), now: now) == "Just now", "Just now (en)")
        check(RelativeTime.string(now.addingTimeInterval(-300), now: now) == "5m ago", "5m ago (en)")
        L10n.override = .zh
        check(CLI.main(["--version"]) == 0, "--version")

        // Push two files with the same name from different folders + one more.
        let work = Paths.root.appendingPathComponent("work")
        let a = work.appendingPathComponent("a"), b = work.appendingPathComponent("b")
        try? fm.createDirectory(at: a, withIntermediateDirectories: true)
        try? fm.createDirectory(at: b, withIntermediateDirectories: true)
        writePNG(a.appendingPathComponent("shot.png"), color: .systemBlue)
        writePNG(b.appendingPathComponent("shot.png"), color: .systemPink)
        writePNG(a.appendingPathComponent("Login After.PNG"), color: .systemGreen)

        fm.changeCurrentDirectoryPath(a.path)
        check(CLI.push(["shot.png", b.appendingPathComponent("shot.png").path], title: nil, source: nil) == 0, "推两张同名图")
        check(CLI.push(["Login After.PNG"], title: "登录页", source: "EatWatch") == 0, "推一张带标题")
        check(CLI.push(["nope.png"], title: nil, source: nil) == 1, "不存在的文件报错")
        check(CLI.push([a.path], title: nil, source: nil) == 1, "文件夹报错")

        var items = Store.loadAll()
        check(items.count == 2, "库里两条（实际 \(items.count)）")
        if items.count == 2 {
            let newest = items[0], older = items[1]
            check(newest.displayTitle == "登录页" && newest.source == "EatWatch", "标题 / 来源")
            check(older.files.map(\.stored) == ["shot.png", "shot 2.png"], "同名改名：\(older.files.map(\.stored))")
            check(older.displayTitle == "shot", "默认标题去扩展名")
            check(older.source == "a", "来源取当前文件夹：\(older.source)")
            check(older.urls.allSatisfy { fm.fileExists(atPath: $0.path) }, "副本存在")
            // Overwrite the original: the card keeps its own snapshot.
            writePNG(a.appendingPathComponent("shot.png"), color: .systemYellow, size: 40)
            let copySize = (try? fm.attributesOfItem(atPath: older.urls[0].path)[.size] as? Int) ?? 0
            let origSize = (try? fm.attributesOfItem(atPath: a.appendingPathComponent("shot.png").path)[.size] as? Int) ?? 0
            check(copySize != origSize, "原图被覆盖，卡片里的副本不变")
            check(older.revealURLs[0].path == a.appendingPathComponent("shot.png").path, "访达定位到原文件")

            // Expiry
            var old = older
            old.created = now.addingTimeInterval(-Paths.retention - 60)
            try? Store.save(old)
            Store.cleanup()
            items = Store.loadAll()
            check(items.map(\.id) == [newest.id], "超过 24 小时自动清掉")
        }
        check((try? fm.contentsOfDirectory(atPath: Paths.incoming.path))?.isEmpty ?? false, "incoming 没残留")

        // HTML / Markdown: local assets come along, titles are picked up.
        let site = work.appendingPathComponent("site")
        try? fm.createDirectory(at: site.appendingPathComponent("css"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: site.appendingPathComponent("img"), withIntermediateDirectories: true)
        writePNG(site.appendingPathComponent("img/logo.png"), color: .systemTeal)
        writePNG(work.appendingPathComponent("outside.png"), color: .systemRed)
        try? "body{background:url('../img/logo.png')} @font-face{src:url(font.woff2)}".write(to: site.appendingPathComponent("css/app.css"), atomically: true, encoding: .utf8)
        try? "x".write(to: site.appendingPathComponent("css/font.woff2"), atomically: true, encoding: .utf8)
        try? """
        <html><head><title>登录页 &amp; 报告</title><link rel="stylesheet" href="css/app.css?v=2"></head>
        <body><img src="img/logo.png"><img src="../outside.png"><img src="https://x.com/a.png"><a href="#top">t</a></body></html>
        """.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try? "---\ntitle: x\n---\n\n# 迁移方案\n\n![图](img/logo.png)\n".write(to: site.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        let refs = Set(Assets.references(of: site.appendingPathComponent("index.html")))
        check(refs == ["css/app.css", "img/logo.png", "css/font.woff2"], "HTML 引用的本地文件（含 CSS 里的字体）：\(refs.sorted())")
        check(Assets.title(of: site.appendingPathComponent("index.html")) == "登录页 & 报告", "HTML 标题取 <title>")
        check(Assets.title(of: site.appendingPathComponent("plan.md")) == "迁移方案", "Markdown 标题取第一个 # 标题（跳过 front matter）")
        check(CLI.push([site.appendingPathComponent("index.html").path], title: nil, source: nil) == 0, "推 HTML")
        if let html = Store.loadAll().first {
            let files = html.dir.appendingPathComponent("files")
            check(html.displayTitle == "登录页 & 报告", "HTML 卡片标题")
            check(fm.fileExists(atPath: files.appendingPathComponent("css/app.css").path)
                  && fm.fileExists(atPath: files.appendingPathComponent("img/logo.png").path)
                  && !fm.fileExists(atPath: html.dir.appendingPathComponent("outside.png").path), "资源跟着复制、不越出文件夹")
        }
        // Multi-HTML asset isolation & symlink containment
        let site2 = work.appendingPathComponent("site2")
        try? fm.createDirectory(at: site2.appendingPathComponent("img"), withIntermediateDirectories: true)
        writePNG(site2.appendingPathComponent("img/logo.png"), color: .systemOrange, size: 32)
        try? fm.createSymbolicLink(at: site2.appendingPathComponent("img/escape.png"), withDestinationURL: work.appendingPathComponent("outside.png"))
        try? "<img src=\"img/logo.png\"><img src=\"img/escape.png\">".write(to: site2.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        check(CLI.push([site.appendingPathComponent("index.html").path, site2.appendingPathComponent("index.html").path], title: "双页", source: nil) == 0, "推两个同名资源 HTML")
        if let pair = Store.loadAll().first {
            let size0 = (try? fm.attributesOfItem(atPath: pair.urls[0].deletingLastPathComponent().appendingPathComponent("img/logo.png").path)[.size] as? Int) ?? 0
            let size1 = (try? fm.attributesOfItem(atPath: pair.urls[1].deletingLastPathComponent().appendingPathComponent("img/logo.png").path)[.size] as? Int) ?? 0
            check(size0 > 0 && size1 > 0 && size0 != size1, "两个 HTML 同名资源互不覆盖")
            check(!fm.fileExists(atPath: pair.urls[1].deletingLastPathComponent().appendingPathComponent("img/escape.png").path), "越界符号链接不复制")
        }
        let md = WebDoc.renderMarkdown("# 标题\n\n</script><b>x</b>", title: "t")
        check(md.contains("marked") || md.contains("<pre"), "Markdown 渲染页生成")
        check(!md.contains("</script><b>"), "Markdown 里的 </script> 被转义")

        // Shortcut strings
        check(Hotkeys.parse(Hotkeys.Action.open.fallback)?.display == "⌥⌘P", "打开详情的默认快捷键 ⌥⌘P")
        check(Hotkeys.parse(Hotkeys.Action.recent.fallback)?.display == "⌥4", "最近卡片的默认快捷键 ⌥4")
        check(Hotkeys.parse("⌃⌥H")?.display == "⌃⌥H", "快捷键解析 ⌃⌥H")
        check(Hotkeys.parse("cmd+shift+return")?.display == "⇧⌘↩", "快捷键解析 cmd+shift+return")
        check(Hotkeys.parse("") == nil && Hotkeys.parse("p") == nil, "空串 / 没修饰键 = 关掉")

        Store.removeAll()
        check(Store.loadAll().isEmpty, "全部清空")
        try? fm.removeItem(at: Paths.root)
        print(failures == 0 ? "通过，\(passes) 项" : "失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    private static func writePNG(_ url: URL, color: NSColor, size: Int = 64) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
