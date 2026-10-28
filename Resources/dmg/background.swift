// Sfondo della finestra del DMG (make dmg): `swift Resources/dmg/background.swift <out.png>`.
// 640×400 pt a 2× (144 dpi, così il Finder lo mostra alla misura giusta sui Retina). Fondo quasi nero come la
// finestra delle impostazioni (white 0.07); le icone (dockduo a 160,180; Applicazioni a 480,180) le mette il Finder
// (Resources/dmg/layout.applescript): qui solo la freccia tra le due, la didascalia e la nota sul primo avvio.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? ".background.png"
let size = NSSize(width: 640, height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size   // punti ≠ pixel: il PNG esce a 144 dpi
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(white: 0.07, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// Coordinate dall'alto come nel Finder; il contesto ha l'origine in basso.
func at(_ x: CGFloat, _ yFromTop: CGFloat) -> NSPoint { NSPoint(x: x, y: size.height - yFromTop) }
func text(_ s: String, size pt: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerX: CGFloat, top: CGFloat) {
    let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: pt, weight: weight),
                                                       .foregroundColor: NSColor(white: 1, alpha: alpha)])
    let w = a.size().width
    a.draw(at: at(centerX - w / 2, top + a.size().height))
}

let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 40, weight: .medium).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.7)])))!
let aw = arrow.size.width, ah = arrow.size.height
arrow.draw(in: NSRect(origin: at(320 - aw / 2, 180 + ah / 2), size: arrow.size))

text("Drag dockduo into Applications", size: 18, weight: .medium, alpha: 0.9, centerX: 320, top: 290)
text("First launch: macOS blocks apps it hasn't verified.", size: 12, weight: .regular, alpha: 0.5, centerX: 320, top: 336)
text("Open System Settings › Privacy & Security and choose Open Anyway.", size: 12, weight: .regular, alpha: 0.5, centerX: 320, top: 354)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
