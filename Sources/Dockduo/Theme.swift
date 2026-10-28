import AppKit
import SwiftUI

// Un aspetto solo, quello del Dock di macOS (spec dock-degli-agenti §5): niente stili né temi, il chiaro o lo scuro del Mac.
// In scuro i bianchi di sempre (nessuna tavolozza); in chiaro clearLight.

// I colori della barra in chiaro: testo, il bordo di trascinamento sugli spazi (accent) e i colori degli stati (agenti al
// lavoro, in attesa, finiti).
struct Palette: Equatable {
    let text, accent, blue, yellow, green: Color
}

extension Color {
    // 0xRRGGBB; i canali li divide cgColor(hex:).
    init(hex: Int) { self.init(cgColor: Dockduo.cgColor(hex: hex)) }   // qualificata: Color ha la sua proprietà cgColor
}

func cgColor(hex v: Int) -> CGColor {
    CGColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
}

// La barra in chiaro (autore, 27/9): sul vetro chiaro, testi scuri come la barra di macOS in chiaro, gli stati coi colori di
// sistema di macOS in chiaro (blu, arancio, verde), che su fondo chiaro reggono meglio di quelli del vetro scuro.
// Fissi, non NSColor di sistema: quelli cambiano con l'aspetto e, risolti fuori dal main (i test), bloccavano il processo.
// Il bordo di trascinamento: nero a metà, come il bianco a metà dello scuro.
let clearLight = Palette(text: Color(hex: 0x1C1C1C), accent: .black.opacity(0.5),
                         blue: Color(hex: 0x007AFF), yellow: Color(hex: 0xFF9500), green: Color(hex: 0x34C759))

// La tavolozza della barra col Mac in chiaro o in scuro: in scuro nessuna (i bianchi di sempre), in chiaro clearLight.
func palette(dark: Bool) -> Palette? { dark ? nil : clearLight }

extension EnvironmentValues {
    // La tavolozza della barra (SideLook); nil = scuro.
    @Entry var palette: Palette? = nil
    @Entry var mergedPill = false   // dentro un Dock (DockBoxView): la pillola non disegna il suo sfondo, lo fa il Dock
    // La barra di lato (spec barra-di-lato §3): pillole in colonna, in scala con la larghezza della barra (larghezza / 38).
    @Entry var barScale: CGFloat = 1
}

// La luce di un colore (luminanza relativa WCAG), da 0 (nero) a 1 (bianco).
func luminance(_ c: Color) -> Double {
    let r = c.resolve(in: EnvironmentValues())
    return 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
}

// Contrasto WCAG tra due colori, da 1 a 21.
func contrast(_ a: Color, _ b: Color) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

extension Optional where Wrapped == Palette {
    var ink: Color { self?.text ?? .white.opacity(0.9) }       // testo e simboli dei widget
    var dim: Color { (self?.text ?? .white).opacity(0.45) }    // fondo della batteria e sua punta
}
