import Foundation

/// CLI side: HTML and Markdown pull in local files (css, js, images). Copy the ones
/// living under the document's folder next to its snapshot so the card renders
/// on its own, without Peek needing access to wherever the original lives.
enum Assets {
    private static let maxTotal = 60 * 1024 * 1024
    private static let maxFiles = 300

    /// Relative paths (from the document's folder) of local files it references.
    static func references(of doc: URL) -> [String] {
        guard WebDoc.isWeb(doc) else { return [] }
        let base = doc.deletingLastPathComponent().standardizedFileURL
        var found: [String] = []
        var seen = Set<String>()
        var queue: [(URL, String)] = [(doc, "")]
        while let (file, prefix) = queue.popLast(), found.count < maxFiles {
            guard let text = read(file) else { continue }
            let isCSS = file.pathExtension.lowercased() == "css"
            for ref in candidates(in: text, markdown: WebDoc.isMarkdown(file), css: isCSS) {
                guard let rel = clean(ref) else { continue }
                let target = base.appendingPathComponent(prefix).appendingPathComponent(rel).standardizedFileURL
                guard target.path.hasPrefix(base.path + "/") else { continue }   // stay inside the folder
                let relative = String(target.path.dropFirst(base.path.count + 1))
                guard !seen.contains(relative) else { continue }
                seen.insert(relative)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                found.append(relative)
                // Stylesheets reference fonts / images of their own.
                if target.pathExtension.lowercased() == "css" {
                    queue.append((target, (relative as NSString).deletingLastPathComponent))
                }
            }
        }
        return found
    }

    /// Copies referenced files into `filesDir`, keeping their relative layout.
    static func copy(for doc: URL, into filesDir: URL) {
        let base = doc.deletingLastPathComponent()
        let fm = FileManager.default
        var total = 0
        for rel in references(of: doc) {
            let src = base.appendingPathComponent(rel)
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
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func candidates(in text: String, markdown: Bool, css: Bool) -> [String] {
        var patterns = ["url\\(\\s*['\"]?([^'\")]+)['\"]?\\s*\\)"]
        if !css { patterns.append("(?:src|href|poster)\\s*=\\s*[\"']([^\"']+)[\"']") }
        if markdown { patterns.append("!\\[[^\\]]*\\]\\(\\s*<?([^)\\s>]+)") }
        var out: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                out.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }

    /// Local relative path, or nil for URLs, anchors, data: and absolute paths.
    private static func clean(_ ref: String) -> String? {
        var s = ref.trimmingCharacters(in: .whitespaces)
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        guard !s.isEmpty, !s.hasPrefix("/"), !s.contains(":") else { return nil }
        return s.removingPercentEncoding ?? s
    }
}
