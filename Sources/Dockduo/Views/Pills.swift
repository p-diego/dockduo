import SwiftUI

// Il fondo delle pillole, scuro o chiaro col Mac (27/9). Scuro: il vetro scuro con un velo nero sotto e un tint nero. Il
// tint non cambia la luminosità (misurato il 2026-09-26: da 0,25 a 0,32 l'interno resta a 140/255): scurisce solo il velo,
// un filo per il contrasto (autore, 2026-09-26); lo spazio attivo = lo stesso velo più lo scarto di sempre (0,15). Chiaro:
// il vetro chiaro di macOS e basta (autore, 27/9), col velo bianco solo sullo spazio attivo, che senza era identico agli
// altri (179 contro 178 su 255).
struct ClearTones {
    let light: Bool   // la barra in chiaro: la sua tavolozza (clearLight, Theme.swift); scura: nessuna
    init(_ palette: Palette?) { light = palette != nil }
    private var base: Color { light ? .white : .black }
    func veil(active: Bool) -> Color { light ? (active ? base.opacity(0.23) : .clear) : base.opacity(active ? 0.23 : 0.08) }
    var tint: Color? { light ? nil : base.opacity(0.25) }
    var scheme: ColorScheme { light ? .light : .dark }   // il vetro chiaro o scuro, come la barra
    // La lente dello spazio attivo dentro un Dock (WorkspaceBackground). Scuro: velo più leggero del 0,23 e tinta
    // un filo blu — il vetro del Dock scurisce già, e scurisce il rosso più del blu: una tinta neutra non basta
    // (tarata sui rapporti pixel con la pillola separata, 4/10). Chiaro: il velo bianco dell'attiva, nessuna tinta.
    var lensVeil: Color { light ? veil(active: true) : base.opacity(0.18) }
    var lensTint: Color? { light ? nil : Color(red: 0.02, green: 0.07, blue: 0.18).opacity(0.22) }
}

extension View {
    // Pillola larga 26 (in scala) dei widget: margini interni e lo sfondo di ogni pillola (PillBackground).
    func pill(padding: CGFloat = 8, dock: Bool = false) -> some View { modifier(Pill(padding: padding, dock: dock)) }
}

// Dentro un Dock (DockBoxView) lo sfondo lo disegna il Dock e la pillola è una sua casella: larga e alta almeno quanto le
// sue icone (26 qui sono i 31 del Dock, inDockScale), senza margini suoi, come le app accanto. Tiene la superficie di click
// intera, che da sola dava PillBackground (senza, i click nei margini cadevano attraverso: lo stesso difetto già corretto
// negli spazi, 4/10).
struct Pill: ViewModifier {
    var padding: CGFloat = 8   // il margine lungo la barra (il Dock: quello di macOS, DockBoxView)
    var dock = false           // la capsula del Dock: larga come quella di macOS (dockWidth) e col suo vetro
    @Environment(\.mergedPill) private var merged
    @Environment(\.barScale) private var scale

    func body(content: Content) -> some View {
        if merged {
            content.frame(width: 26 * scale).frame(minHeight: 26 * scale).contentShape(Rectangle())
        } else {
            content.padding(.vertical, padding * scale).frame(width: (dock ? dockWidth : 26) * scale).modifier(PillBackground(dock: dock))
        }
    }
}

// La fila degli spazi, sempre dentro un Dock: fra l'uno e l'altro i 2 del Dock fra le sue caselle (26 qui = 31 lì).
struct WorkspacesRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { BarStack(spacing: 2 * 26 / 31, content: content) }
}

// Una fila lungo la barra, in colonna; la spaziatura in scala (barScale).
struct BarStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.barScale) private var scale

    var body: some View { VStack(spacing: spacing * scale, content: content) }
}

// Lo sfondo di ogni pillola, widget e spazi: il vetro. Sul Dock quello del Dock di macOS (dockGlass, 25/10: «deve essere
// uguale»; riferimento dell'autore il dock dell'iPhone Duo), coi suoi angoli; il resto (le etichette di lato) capsule di
// vetro scuro o chiaro (ClearTones), come col 13 di fabbrica del cursore che non c'è più (dock-contenitori §5). Gli angoli
// in scala con lo spessore.
struct PillBackground: ViewModifier {
    var active = false
    var dock = false
    @Environment(\.palette) private var palette
    @Environment(\.barScale) private var scale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: (dock ? dockRadius : 13) * scale)
        if dock {
            // Dove il vetro del Dock manca, il .clear: trasparente col bordo luminoso.
            content.glassEffect((dockGlass ?? .clear).interactive(), in: shape).contentShape(shape)
        } else {
            let tones = ClearTones(palette)
            content
                .background(shape.fill(tones.veil(active: active)))
                .glassEffect(.regular.tint(tones.tint).interactive(), in: shape)
                .environment(\.colorScheme, tones.scheme)
                .contentShape(shape)
        }
    }
}
