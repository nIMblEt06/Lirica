// Draws the background of the Lirica disk image: a near-black card in the app's colours with the
// wordmark, a soft arrow between the app and the Applications alias, and an install hint.
//
// Usage: swift Tools/dmg_background.swift <output-directory>
// Writes background.png (600×440) and background@2x.png (1200×880); make-dmg.sh combines the two
// into a retina-aware TIFF. The image is drawn 1:1 from the window's top-left, and Finder's
// content area is about 600×400, so everything lives in the top 400 points; the extra 40 are
// spare dark gradient in case another macOS leaves a taller content area.
import AppKit

let canvasWidth: CGFloat = 600
let canvasHeight: CGFloat = 440     // > content area; the surplus at the bottom is plain gradient

// Top-origin helpers: P(150, 175) is where Finder puts the centre of the Lirica.app icon.
var s: CGFloat = 1
var grain: CGImage!
func P(_ x: CGFloat, _ t: CGFloat) -> NSPoint { NSPoint(x: x * s, y: (canvasHeight - t) * s) }
func R(_ x: CGFloat, _ t: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x * s, y: (canvasHeight - t - h) * s, width: w * s, height: h * s)
}

let ink = NSColor(srgbRed: 245.0 / 255, green: 244.0 / 255, blue: 241.0 / 255, alpha: 1)   // near-white
let green = NSColor(srgbRed: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255, alpha: 1)   // --green
let blue = NSColor(srgbRed: 143.0 / 255, green: 151.0 / 255, blue: 255.0 / 255, alpha: 1)  // --blue
let coral = NSColor(srgbRed: 255.0 / 255, green: 138.0 / 255, blue: 110.0 / 255, alpha: 1) // --danger

func glow(_ color: NSColor, at x: CGFloat, _ t: CGFloat, radius: CGFloat, alpha: CGFloat) {
    // multi-stop falloff: a gentle tail avoids visible edges where the gradient meets the base
    let gradient = NSGradient(colorsAndLocations:
        (color.withAlphaComponent(alpha), 0),
        (color.withAlphaComponent(alpha * 0.55), 0.38),
        (color.withAlphaComponent(alpha * 0.22), 0.66),
        (color.withAlphaComponent(0), 1))!
    gradient.draw(in: NSBezierPath(ovalIn: R(x - radius, t - radius, radius * 2, radius * 2)),
                  relativeCenterPosition: .zero)
}

/// A soft dark pool that deepens the backdrop behind text, so the fonts keep their contrast.
func shade(at x: CGFloat, _ t: CGFloat, radius: CGFloat, alpha: CGFloat) {
    let gradient = NSGradient(colorsAndLocations:
        (NSColor.black.withAlphaComponent(alpha), 0),
        (NSColor.black.withAlphaComponent(alpha * 0.5), 0.45),
        (NSColor.black.withAlphaComponent(alpha * 0.18), 0.72),
        (NSColor.black.withAlphaComponent(0), 1))!
    gradient.draw(in: NSBezierPath(ovalIn: R(x - radius, t - radius, radius * 2, radius * 2)),
                  relativeCenterPosition: .zero)
}

/// Fine, evenly seeded grain, drawn over the finished art. Barely visible, but it breaks up the
/// faint banding that big soft gradients show on a near-black base, and adds a little texture.
func grainLayer(scale: CGFloat) -> CGImage {
    let w = Int(canvasWidth * scale), h = Int(canvasHeight * scale)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func rnd() -> UInt8 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8((seed >> 33) & 0xFF)
    }
    // premultiplied RGBA, alpha 8/255 (~3%): the speckle dithers the gradients a few levels
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        let v = Int(rnd()) * 8 / 255
        bytes[i] = UInt8(v); bytes[i + 1] = UInt8(v); bytes[i + 2] = UInt8(v); bytes[i + 3] = 8
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func centered(_ text: String, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, kern: CGFloat, top: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let line = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size * s, weight: weight),
        .foregroundColor: color,
        .kern: kern * s,
        .paragraphStyle: para,
    ])
    let h = ceil(line.size().height)
    line.draw(in: R(0, top, canvasWidth, h))
}

func line(from a: NSPoint, to b: NSPoint, color: NSColor, width w: CGFloat) {
    let path = NSBezierPath()
    path.move(to: a)
    path.line(to: b)
    path.lineWidth = w * s
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

func draw() {
    // base — deep charcoal, darker than any text so the fonts stay high-contrast
    NSGradient(colors: [
        NSColor(srgbRed: 24.0 / 255, green: 24.0 / 255, blue: 28.0 / 255, alpha: 1),   // #18181c
        NSColor(srgbRed: 15.0 / 255, green: 15.0 / 255, blue: 18.0 / 255, alpha: 1),   // #0f0f12
        NSColor(srgbRed: 9.0 / 255, green: 9.0 / 255, blue: 11.0 / 255, alpha: 1),     // #09090b
    ])!.draw(in: R(0, 0, canvasWidth, canvasHeight), angle: -90)

    // the icon's colours, kept to the corners and the very bottom so nothing sits behind the text
    glow(green, at: 30, -60, radius: 210, alpha: 0.13)
    glow(blue, at: 555, 25, radius: 265, alpha: 0.18)
    glow(coral, at: 300, 485, radius: 245, alpha: 0.12)

    // dark pools behind the two text blocks
    shade(at: 300, 60, radius: 235, alpha: 0.24)
    shade(at: 300, 330, radius: 200, alpha: 0.18)

    // wordmark and subtitle
    centered("Lirica", size: 40, weight: .semibold, color: ink, kern: 1.2, top: 46)
    centered("A living wallpaper for what's playing",
             size: 13, weight: .medium,
             color: ink.withAlphaComponent(0.72), kern: 0.3, top: 103)

    // arrow, centred on x = 300 and aimed at the icon centres
    let ay: CGFloat = 176
    line(from: P(262, ay), to: P(326, ay), color: ink.withAlphaComponent(0.52), width: 4)
    line(from: P(310, ay - 10), to: P(326, ay), color: ink.withAlphaComponent(0.52), width: 4)
    line(from: P(310, ay + 10), to: P(326, ay), color: ink.withAlphaComponent(0.52), width: 4)

    // install hint, under the icons
    centered("Drag Lirica into Applications to install",
             size: 12.5, weight: .regular,
             color: ink.withAlphaComponent(0.62), kern: 0.2, top: 333)

    // grain over everything, to keep the large gradients smooth
    NSGraphicsContext.current?.cgContext.draw(grain, in: R(0, 0, canvasWidth, canvasHeight))
}

func render(scale: CGFloat, to url: URL) {
    s = scale
    grain = grainLayer(scale: scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasWidth * scale),
                               pixelsHigh: Int(canvasHeight * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
render(scale: 1, to: out.appendingPathComponent("background.png"))
render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
print("wrote background.png and background@2x.png to \(out.path)")
