import Foundation

/// CLI side: HTML and Markdown pull in local files (css, js, images). Copy the ones
/// living under the document's folder next to its snapshot so the card renders
/// on its own, without Peek needing access to wherever the original lives.
enum Assets {
    private static let maxTotal = 60 * 1024 * 1024
    private static let maxFiles = 300

    private static let htmlRefRE = try! NSRegularExpression(
        pattern: "(?:src|href|poster)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>\"']+))",
        options: [.caseInsensitive]
    )
    private static let srcsetRE = try! NSRegularExpression(
        pattern: "srcset\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
        options: [.caseInsensitive]
    )
    private static let cssRefRE = try! NSRegularExpression(
        pattern: "url\\(\\s*['\"]?([^'\"\\)\\s]+)['\"]?\\s*\\)|@import\\s+['\"]([^'\"]+)['\"]",
        options: [.caseInsensitive]
    )
    private static let mdRefRE = try! NSRegularExpression(
        pattern: "!?\\[[^\\]]*\\]\\(\\s*(?:<([^>\\r\\n]+)>|([^)\\s>]+))(?:\\s+[^)]*)?\\)|(?m)^\\s{0,3}\\[[^\\]]+\\]:\\s*(?:<([^>\\r\\n]+)>|([^\\s>]+))",
        options: []
    )

    /// Relative paths (from the document's folder) of local files it references.
    static func references(of doc: URL) -> [String] {
        guard WebDoc.isWeb(doc) else { return [] }
        let base = doc.deletingLastPathComponent().standardizedFileURL
        let realBase = base.resolvingSymlinksInPath().standardizedFileURL
        let realBasePrefix = realBase.path.hasSuffix("/") ? realBase.path : realBase.path + "/"
        var found: [String] = []
        var seen = Set<String>()
        var queue: [(URL, String)] = [(doc, "")]
        while let (file, prefix) = queue.popLast(), found.count < maxFiles {
            guard let text = read(file) else { continue }
            let isCSS = file.pathExtension.lowercased() == "css"
            for ref in candidates(in: text, markdown: WebDoc.isMarkdown(file), css: isCSS) {
                guard let rel = clean(ref) else { continue }
                let target = base.appendingPathComponent(prefix).appendingPathComponent(rel).standardizedFileURL
                guard target.path.hasPrefix(base.path + "/") else { continue }
                // Prevent symlinks inside the folder from escaping outside the document root.
                let realTarget = target.resolvingSymlinksInPath().standardizedFileURL
                guard realTarget.path.hasPrefix(realBasePrefix),
                      (try? realTarget.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(target.path.dropFirst(base.path.count + 1))
                guard !seen.contains(relative) else { continue }
                seen.insert(relative)
                found.append(relative)
                // Stylesheets reference fonts / images / imported stylesheets of their own.
                if target.pathExtension.lowercased() == "css" {
                    queue.append((realTarget, (relative as NSString).deletingLastPathComponent))
                }
            }
        }
        return found
    }

    /// Copies referenced files into `filesDir`, keeping their relative layout.
    static func copy(for doc: URL, into filesDir: URL) {
        let base = doc.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var total = 0
        for rel in references(of: doc) {
            let src = base.appendingPathComponent(rel).resolvingSymlinksInPath().standardizedFileURL
            guard (try? src.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard total + size <= maxTotal else { break }
            let dst = filesDir.appendingPathComponent(rel)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil { total += size }
        }
    }

    /// <title> of an HTML page, or the first "# heading" of a Markdown file.
    static func title(of doc: URL) -> String? {
        guard WebDoc.isWeb(doc), let text = read(doc, limit: 512 * 1024) else { return nil }
        if WebDoc.isMarkdown(doc) {
            var inFrontMatter = false
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if i == 0 && line == "---" { inFrontMatter = true; continue }
                if inFrontMatter { if line == "---" { inFrontMatter = false }; continue }
                if line.hasPrefix("# ") { return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces).nonEmpty }
            }
            return nil
        }
        guard let r = text.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = String(text[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = inner
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        return Origin.clean(decoded, max: 60).nonEmpty
    }

    private static func read(_ url: URL, limit: Int = 4 * 1024 * 1024) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func candidates(in text: String, markdown: Bool, css: Bool) -> [String] {
        var regexes: [NSRegularExpression] = [cssRefRE]
        if !css { regexes.append(htmlRefRE) }
        if markdown { regexes.append(mdRefRE) }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        for re in regexes {
            for m in re.matches(in: text, range: full) {
                for idx in 1..<m.numberOfRanges {
                    let r = m.range(at: idx)
                    if r.location != NSNotFound && r.length > 0 {
                        out.append(unescapeHTML(ns.substring(with: r)))
                        break
                    }
                }
            }
        }
        if !css {
            for m in srcsetRE.matches(in: text, range: full) {
                for idx in 1..<m.numberOfRanges {
                    let r = m.range(at: idx)
                    guard r.location != NSNotFound && r.length > 0 else { continue }
                    for part in ns.substring(with: r).split(separator: ",") {
                        if let first = part.split(whereSeparator: \.isWhitespace).first {
                            out.append(unescapeHTML(String(first)))
                        }
                    }
                    break
                }
            }
        }
        return out
    }

    private static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Local relative path, or nil for URLs, anchors, data: and absolute paths.
    private static func clean(_ ref: String) -> String? {
        var s = ref.trimmingCharacters(in: .whitespaces)
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        guard !s.isEmpty, !s.hasPrefix("/"), !s.contains(":") else { return nil }
        return s.removingPercentEncoding ?? s
    }
}
