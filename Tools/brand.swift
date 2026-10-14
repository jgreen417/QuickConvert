// Brand artwork for the README. Same visual language as the app icon: a blue→violet gradient
// with a soft dot grid.
//
//   swift Tools/brand.swift banner                     → docs/banner-light.png, docs/banner-dark.png
//   swift Tools/brand.swift frame <in.png>... <out.png> → screenshots side by side on the branded backdrop
import AppKit

let blue = NSColor(srgbRed: 0.33, green: 0.42, blue: 1.0, alpha: 1)
let violet = NSColor(srgbRed: 0.62, green: 0.30, blue: 0.95, alpha: 1)

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func canvas(_ w: Int, _ h: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The brand pattern: a dot grid that fades toward one corner.
func dots(in rect: CGRect, color: NSColor, spacing: CGFloat, radius: CGFloat) {
    var y = rect.minY + spacing / 2
    while y < rect.maxY {
        var x = rect.minX + spacing / 2
        while x < rect.maxX {
            let fade = 1 - min(1, hypot(x - rect.maxX, y - rect.maxY) / hypot(rect.width, rect.height) * 1.15)
            color.withAlphaComponent(color.alphaComponent * fade).setFill()
            NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
            x += spacing
        }
        y += spacing
    }
}

func icon(in rect: CGRect) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = violet.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = rect.width * 0.18
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.06)
    shadow.set()
    NSGradient(colors: [blue, violet])!.draw(in: path, angle: -60)
    NSGraphicsContext.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.57, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let s = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        s.draw(in: CGRect(x: rect.midX - s.size.width / 2, y: rect.midY - s.size.height / 2, width: s.size.width, height: s.size.height))
    }
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: CGPoint, kern: CGFloat = 0) -> CGFloat {
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    a.draw(at: p)
    return a.size().width
}

func chip(_ s: String, at p: CGPoint, dark: Bool) -> CGFloat {
    let font = rounded(30, .semibold)
    let w = NSAttributedString(string: s, attributes: [.font: font]).size().width + 44
    let r = CGRect(x: p.x, y: p.y, width: w, height: 58)
    (dark ? NSColor.white.withAlphaComponent(0.08) : blue.withAlphaComponent(0.08)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 29, yRadius: 29).fill()
    (dark ? NSColor.white.withAlphaComponent(0.16) : blue.withAlphaComponent(0.22)).setStroke()
    let border = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 28, yRadius: 28)
    border.lineWidth = 2
    border.stroke()
    _ = text(s, font, dark ? NSColor.white.withAlphaComponent(0.85) : NSColor(srgbRed: 0.25, green: 0.27, blue: 0.55, alpha: 1),
             at: CGPoint(x: r.minX + 22, y: r.minY + 11))
    return w
}

func banner(dark: Bool) -> Data {
    canvas(2560, 840) { r in
        // Background: near-white or near-black with a faint brand wash and the dot grid.
        (dark ? NSColor(srgbRed: 0.06, green: 0.06, blue: 0.09, alpha: 1) : NSColor(srgbRed: 0.985, green: 0.985, blue: 1, alpha: 1)).setFill()
        r.fill()
        NSGradient(colors: [blue.withAlphaComponent(dark ? 0.28 : 0.10), violet.withAlphaComponent(dark ? 0.30 : 0.12), .clear])!
            .draw(fromCenter: CGPoint(x: r.maxX - 420, y: r.maxY - 120), radius: 0,
                  toCenter: CGPoint(x: r.maxX - 420, y: r.maxY - 120), radius: 1500, options: [])
        dots(in: r, color: dark ? NSColor.white.withAlphaComponent(0.13) : violet.withAlphaComponent(0.20), spacing: 40, radius: 2.4)

        icon(in: CGRect(x: 170, y: 250, width: 340, height: 340))
        let ink = dark ? NSColor.white : NSColor(srgbRed: 0.08, green: 0.09, blue: 0.16, alpha: 1)
        let sub = dark ? NSColor.white.withAlphaComponent(0.66) : NSColor(srgbRed: 0.33, green: 0.35, blue: 0.45, alpha: 1)
        let x: CGFloat = 600
        let wQuick = text("Quick", rounded(150, .heavy), ink, at: CGPoint(x: x, y: 430), kern: -3)
        // "Convert" in the brand gradient.
        let convert = NSAttributedString(string: "Convert", attributes: [.font: rounded(150, .heavy), .kern: -3])
        let size = convert.size()
        let rect = CGRect(x: x + wQuick, y: 430, width: size.width, height: size.height)
        if let mask = NSImage(size: size, flipped: false, drawingHandler: { _ in
            NSAttributedString(string: "Convert", attributes: [.font: rounded(150, .heavy), .kern: -3, .foregroundColor: NSColor.black]).draw(at: .zero)
            return true
        }).cgImage(forProposedRect: nil, context: nil, hints: nil), let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.clip(to: rect, mask: mask)
            NSGradient(colors: [blue, violet])!.draw(in: rect, angle: 0)
            ctx.restoreGState()
        }
        _ = text("Right-click any file in Finder. Pick a format. Done.", rounded(54, .medium), sub, at: CGPoint(x: x + 6, y: 340))
        var cx = x + 6
        for label in ["Images", "Video", "Audio", "PDF", "Documents", "Local only"] {
            cx += chip(label, at: CGPoint(x: cx, y: 230), dark: dark) + 18
        }
    }
}

/// Puts screenshots (with their own transparency, e.g. from `screencapture -o -l`) side by side on the
/// branded backdrop, bottom-aligned, each with a soft shadow. `scale` enlarges low-DPI captures.
func frame(_ inputs: [URL], _ output: URL, scale: CGFloat = 1) throws {
    let shots = try inputs.map { url -> (NSImage, CGSize) in
        guard let img = NSImage(contentsOf: url), let rep = img.representations.first else { throw CocoaError(.fileReadCorruptFile) }
        return (img, CGSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale))
    }
    let gap: CGFloat = 70 * scale
    let contentW = shots.map(\.1.width).reduce(0, +) + gap * CGFloat(shots.count - 1)
    let contentH = shots.map(\.1.height).max() ?? 0
    let pad = max(110 * scale, min(contentW, contentH) * 0.16)
    let data = canvas(Int(contentW + pad * 2), Int(contentH + pad * 2)) { r in
        NSGradient(colors: [NSColor(srgbRed: 0.40, green: 0.47, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.64, green: 0.38, blue: 0.96, alpha: 1)])!
            .draw(in: r, angle: -35)
        dots(in: r, color: NSColor.white.withAlphaComponent(0.22), spacing: 34 * scale, radius: 2.2 * scale)
        NSGraphicsContext.current?.imageInterpolation = .high
        var x = pad
        for (img, size) in shots {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: 0.10, green: 0.05, blue: 0.30, alpha: 0.45)
            shadow.shadowBlurRadius = 50 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -20 * scale)
            shadow.set()
            img.draw(in: CGRect(x: x, y: pad, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            x += size.width + gap
        }
    }
    try data.write(to: output)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "banner":
    try banner(dark: false).write(to: URL(fileURLWithPath: "docs/banner-light.png"))
    try banner(dark: true).write(to: URL(fileURLWithPath: "docs/banner-dark.png"))
    print("Wrote docs/banner-light.png, docs/banner-dark.png")
case "frame" where args.count >= 3:
    let paths = Array(args.dropFirst())
    try frame(paths.dropLast().map { URL(fileURLWithPath: $0) }, URL(fileURLWithPath: paths.last!))
default:
    print("usage: swift Tools/brand.swift banner | frame <in.png>... <out.png>")
}
