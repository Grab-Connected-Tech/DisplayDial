#if SCREENSHOTS
// Renders the real panel (live monitor values) to docs/panel-{light,dark}.png for the README.
// Drawing our own view needs no Screen Recording permission. Built only by `./build.sh screenshots`.
import SwiftUI

enum Screenshots {
    static func run() {
        let displays = Displays()
        displays.rescan()
        displays.selected?.refresh()
        // DDC reads take a second or two; wait for them before drawing.
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            guard displays.selected?.responded != nil || Date().timeIntervalSince(start) > 10 else { return }
            timer.invalidate()
            for (file, look) in [("panel-light", NSAppearance.Name.aqua), ("panel-dark", .darkAqua)] {
                render(displays, look, to: "docs/\(file).png")
            }
            exit(0)
        }
    }

    private static func render(_ displays: Displays, _ look: NSAppearance.Name, to path: String) {
        let appearance = NSAppearance(named: look)!
        let keys = Keys(displays: displays)
        let host = NSHostingView(rootView: Panel(displays: displays, keys: keys, settings: SettingsWindow(keys: keys)).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        host.appearance = appearance
        host.frame.size = host.fittingSize
        // Controls only draw in the accent colour inside the key window; macOS won't let a
        // background tool take focus, so the window just claims to be key.
        let window = KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let scale: CGFloat = 2, margin: CGFloat = 40, radius: CGFloat = 12
        let panel = host.bounds.size
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)

        // Transparent canvas: rounded panel with a soft shadow, like the real menu bar window.
        let size = CGSize(width: (panel.width + margin * 2) * scale, height: (panel.height + margin * 2) * scale)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: margin, y: margin, width: panel.width, height: panel.height)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(shape); ctx.setFillColor(.black); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape); ctx.clip()
        ctx.draw(rep.cgImage!, in: rect)
        ctx.resetClip()
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(look == .darkAqua ? 0.15 : 0).cgColor)
        ctx.strokePath()

        let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
        try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
        window.orderOut(nil)
    }
}

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
#endif
