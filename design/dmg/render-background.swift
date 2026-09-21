// Renders the DMG window background at @2x (1320x800 px, DPI-tagged so it
// reads as 660x400 pt in Finder's window). Coordinates below are in Finder's
// "position of item" space: origin top-left of the window content area, y
// increasing downward, matching the icon positions set in scripts/release.sh.
//
// Run: swift design/dmg/render-background.swift design/dmg/background.png
//
// Content: the app's black surface, a thin centered arrow from the left icon
// slot to the right icon slot, "Drag Zumbo to Applications" under the arrow,
// and the Zumbo wordmark small at the top left.
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else { fatalError("usage: render-background.swift <out.png>") }
let dst = URL(fileURLWithPath: args[1])

let ptW = 660.0, ptH = 400.0
let scale = 2.0
let pxW = Int(ptW * scale), pxH = Int(ptH * scale)

// Window content-space points (top-left origin, y down), matching the icon
// positions used in scripts/release.sh: Zumbo.app at (165,190), Applications
// at (495,190), icon size 128.
let leftIconCenter = CGPoint(x: 165, y: 190)
let rightIconCenter = CGPoint(x: 495, y: 190)
let iconHalfWidth: CGFloat = 64

func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: ptH - p.y) }

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: ptW, height: ptH)

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current = ctx
let cg = ctx!.cgContext

// Background fill, #0B0B0B.
let bg = NSColor(calibratedRed: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0B / 255.0, alpha: 1)
bg.setFill()
NSRect(x: 0, y: 0, width: ptW, height: ptH).fill()

// Arrow: thin white-60% line with rounded caps, small filled arrowhead,
// from just past the left icon's right edge to just before the right icon's
// left edge, centered on the icons' vertical midline.
let arrowY = leftIconCenter.y
let arrowStart = flip(CGPoint(x: leftIconCenter.x + iconHalfWidth + 18, y: arrowY))
let arrowEnd = flip(CGPoint(x: rightIconCenter.x - iconHalfWidth - 30, y: arrowY))

let arrowColor = NSColor.white.withAlphaComponent(0.6)
arrowColor.setStroke()
arrowColor.setFill()

let shaft = NSBezierPath()
shaft.lineWidth = 2.5
shaft.lineCapStyle = .round
shaft.move(to: arrowStart)
shaft.line(to: arrowEnd)
shaft.stroke()

let headLength: CGFloat = 12
let headWidth: CGFloat = 8
let head = NSBezierPath()
head.move(to: CGPoint(x: arrowEnd.x, y: arrowEnd.y))
head.line(to: CGPoint(x: arrowEnd.x - headLength, y: arrowEnd.y + headWidth / 2))
head.line(to: CGPoint(x: arrowEnd.x - headLength, y: arrowEnd.y - headWidth / 2))
head.close()
head.fill()

// "Drag Zumbo to Applications" under the arrow, 15pt medium, white 85%.
let caption = "Drag Zumbo to Applications"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let captionAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    .paragraphStyle: paragraph,
]
let captionString = NSAttributedString(string: caption, attributes: captionAttrs)
let captionSize = captionString.size()
let captionTopLeft = flip(CGPoint(x: ptW / 2 - captionSize.width / 2, y: arrowY + 26))
captionString.draw(at: captionTopLeft)

// Zumbo wordmark, small, top left, white.
let logoURL = URL(fileURLWithPath: "design/icon/zumbo-logo-white.svg")
if let logo = NSImage(contentsOf: logoURL) {
    let logoHeight: CGFloat = 20
    let aspect = logo.size.width / max(logo.size.height, 1)
    let logoWidth = logoHeight * aspect
    let logoTopLeftPt = CGPoint(x: 24, y: 24)
    let logoOrigin = flip(CGPoint(x: logoTopLeftPt.x, y: logoTopLeftPt.y + logoHeight))
    logo.draw(in: NSRect(x: logoOrigin.x, y: logoOrigin.y, width: logoWidth, height: logoHeight),
              from: .zero, operation: .sourceOver, fraction: 1)
} else {
    FileHandle.standardError.write("warning: could not load \(logoURL.path), skipping wordmark\n".data(using: .utf8)!)
}

NSGraphicsContext.restoreGraphicsState()

// Render at @2x pixel dimensions with 144 DPI tagged, so Finder (which reads
// PNG DPI metadata) displays it sharp at 660x400 pt without a separate TIFF.
guard let cgImage = rep.cgImage else { fatalError("no CGImage from rep") }
let pixelRep = NSBitmapImageRep(cgImage: cgImage)
pixelRep.size = NSSize(width: ptW * scale, height: ptH * scale)

guard let data = pixelRep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
// Patch the PNG's pHYs chunk to 144 DPI (5669 px/m) so DPI-aware viewers
// (Finder among them) treat pxW x pxH as ptW x ptH at 2x.
func withDPI(_ png: Data, dpi: Double) -> Data {
    var bytes = [UInt8](png)
    let pxPerMeter = UInt32((dpi * 39.3701).rounded())
    var phys: [UInt8] = []
    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    phys += be32(pxPerMeter)
    phys += be32(pxPerMeter)
    phys += [1] // meters
    var chunkData = phys
    let type: [UInt8] = Array("pHYs".utf8)
    var chunk: [UInt8] = be32(UInt32(chunkData.count)) + type + chunkData
    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1 != 0) ? (0xedb88320 ^ (c >> 1)) : (c >> 1) }
            table[n] = c
        }
        var crc: UInt32 = 0xffffffff
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
    let crc = crc32(type + chunkData)
    chunk += be32(crc)
    // Insert right after the IHDR chunk (8-byte signature + 4 length + 4 type "IHDR" + 13 data + 4 crc = 33 bytes).
    let insertAt = 8 + 25
    bytes.insert(contentsOf: chunk, at: insertAt)
    return Data(bytes)
}
let tagged = withDPI(data, dpi: 144)
try tagged.write(to: dst)
print("wrote \(dst.path) (\(pxW)x\(pxH) px, 144 dpi -> \(Int(ptW))x\(Int(ptH)) pt)")
