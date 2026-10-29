import AppKit
import SwiftUI

/// Renders the popup panel with sample data, light and dark side by side, on
/// a backdrop that stands in for the desktop. Uses real AppKit windows so the
/// native controls draw exactly as they do in the menu bar.
enum Preview {
    @MainActor
    static func render(to url: URL) {
        _ = NSApplication.shared
        let pad = Pad(previewWithSampleData: ())
        let scale: CGFloat = 2, margin: CGFloat = 36, gap: CGFloat = 32, radius: CGFloat = 22

        func snapshot(_ appearance: NSAppearance.Name) -> NSImage {
            let host = NSHostingView(rootView: PanelView(pad: pad, openSettings: {}, quit: {}, onSize: { _ in })
                .environment(\.controlActiveState, .key))
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(rep)
            return image
        }

        let cards = [(snapshot(.aqua), NSColor(white: 0.965, alpha: 1)), (snapshot(.darkAqua), NSColor(white: 0.165, alpha: 1))]
        let w = cards.map(\.0.size.width).reduce(0, +) + gap + margin * 2
        let h = cards.map(\.0.size.height).max()! + margin * 2

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.66, blue: 0.85, alpha: 1),
                   ending: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.62, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -45)
        var x = margin
        for (image, fill) in cards {
            let rect = NSRect(x: x, y: h - margin - image.size.height, width: image.size.width, height: image.size.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 1
            path.stroke()
            x += image.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
