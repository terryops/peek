import AppKit
import ImageIO
import QuickLookThumbnailing

/// Small, fast previews. Raster images go through ImageIO in-process (a few ms);
/// PDFs, SVGs and the rest fall back to Quick Look.
enum Thumbs {
    private static let queue = DispatchQueue(label: "peek.thumbs", qos: .userInitiated, attributes: .concurrent)
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [NSImage]] = [:]

    static func cached(_ item: PeekItem) -> [NSImage]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[item.id]
    }

    static func forget(_ id: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[id] = nil
    }

    static var cacheKeys: [String] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return Array(cache.keys)
    }

    /// Loads up to `limit` thumbnails for an item and calls back on the main queue.
    static func load(_ item: PeekItem, limit: Int = 3, maxPixel: CGFloat = 720, done: @escaping ([NSImage]) -> Void) {
        let wanted = min(max(0, limit), item.urls.count)
        if let hit = cached(item), hit.count >= wanted {
            done(hit)
            return
        }
        let urls = Array(item.urls.prefix(wanted))
        let existing = cached(item) ?? []
        let id = item.id
        queue.async {
            let group = DispatchGroup()
            var images = [NSImage?](repeating: nil, count: urls.count)
            let lock = NSLock()
            for (i, url) in urls.enumerated() {
                if i < existing.count {
                    lock.lock()
                    images[i] = existing[i]
                    lock.unlock()
                    continue
                }
                if WebDoc.isWeb(url) {
                    group.enter()
                    DispatchQueue.main.async {
                        WebSnapshot.capture(url) { img in
                            lock.lock()
                            images[i] = img
                            lock.unlock()
                            group.leave()
                        }
                    }
                    continue
                }
                if let img = rasterThumb(url, maxPixel: maxPixel) {
                    lock.lock()
                    images[i] = img
                    lock.unlock()
                    continue
                }
                group.enter()
                let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel / 2, height: maxPixel / 2),
                                                       scale: 2, representationTypes: [.thumbnail, .icon])
                QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                    lock.lock()
                    images[i] = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
                    lock.unlock()
                    group.leave()
                }
            }
            _ = group.wait(timeout: .now() + 5)
            lock.lock()
            let result = images.enumerated().map { i, img in img ?? NSWorkspace.shared.icon(forFile: urls[i].path) }
            lock.unlock()
            DispatchQueue.main.async {
                cacheLock.lock()
                if (cache[id]?.count ?? 0) <= result.count {
                    cache[id] = result
                }
                let finalResult = cache[id] ?? result
                cacheLock.unlock()
                done(finalResult)
            }
        }
    }

    private static func rasterThumb(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"].contains(ext),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    /// Square, rounded, aspect-filled version for menu rows.
    static func menuIcon(_ image: NSImage, side: CGFloat = 30, radius: CGFloat = 6) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.addClip()
            let s = image.size
            guard s.width > 0, s.height > 0 else { return true }
            let scale = max(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            image.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            inner.lineWidth = 0.5
            inner.stroke()
            return true
        }
    }
}

extension Thumbs {
    static func prune(keeping ids: Set<String>) {
        for id in Array(cacheKeys) where !ids.contains(id) { forget(id) }
    }
}
