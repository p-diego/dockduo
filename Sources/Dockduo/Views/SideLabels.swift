import SwiftUI

// I testi brevi (app in primo piano, canzone, gli agenti sull'app) nella barra di lato non stanno
// nella barra stretta: escono accanto alla loro pillola, verso il centro dello schermo, per 5 s a ogni novità (spec
// barra-di-lato §4).
// Il pannello che li ospita è di SidePanel; qui l'archivio, il modificatore e la vista.
let sideLabelSeconds: TimeInterval = 5

enum SideLabelStyle: Equatable {
    case glass                                  // capsula con lo sfondo delle pillole (app, canzone)
    case dockName                               // il nome di una voce del Dock al passaggio del mouse (DockNameLabel)
    case agent(color: Color?)                   // un agente sull'app: la capsula del nome del Dock, il testo nel colore dello stato
}

struct SideLabel: Equatable {
    var text: String
    var style: SideLabelStyle
    var anchor: CGRect   // la pillola, nello spazio "bar" della sua barra
}

// Uno per barra di lato: gli id ("front", "nowPlaying", "dock", "agent-<pid>") valgono dentro una barra.
@Observable final class SideLabels {
    private(set) var items: [String: SideLabel] = [:]
    static let dock = "dock"   // il nome del Dock al passaggio del mouse (DockName)
    func show(_ id: String, _ label: SideLabel) { if items[id] != label { items[id] = label } }
    // ifText: solo se il testo visibile è ancora quello di chi chiede (più viste dividono un id, es. "front"); at: e se sta
    // ancora sulla sua cornice (due voci del Dock con lo stesso nome, due Chrome o due Download).
    func hide(_ id: String, ifText: String, at anchor: CGRect? = nil) {
        if let label = items[id], label.text == ifText, anchor == nil || anchor == label.anchor { items[id] = nil }
    }
    // Chi non ha mai mostrato niente (shown == nil) non nasconde niente: le altre viste dello stesso id restano.
    func release(_ id: String, shown: String?, at anchor: CGRect? = nil) { if let shown { hide(id, ifText: shown, at: anchor) } }
    // Quello in vista per l'id è di chi ha quel testo su quella cornice.
    func isShowing(_ id: String, _ text: String, at anchor: CGRect) -> Bool { items[id]?.text == text && items[id]?.anchor == anchor }
    // Chi rientra (claim del modificatore) rimette il suo testo se in vista non c'è già, su quella cornice: un'altra voce
    // con lo stesso nome non basta.
    func claim(_ id: String, _ label: SideLabel) { if !isShowing(id, label.text, at: label.anchor) { show(id, label) } }
}

extension EnvironmentValues {
    @Entry var sideLabels: SideLabels? = nil   // nil = fuori dalla barra (anteprime): il modificatore non fa niente
}

func labelNews(old: String?, new: String?) -> Bool { new != nil && new != old }

extension View {
    // claim: quando cambia, chi ha un testo lo rimette se in vista non c'è il suo (il Dock, rientrando su una voce).
    // stays: resta finché c'è, senza i 5 s ("Ti aspetta"); ifFree: esce solo se per l'id non c'è già un testo ("Sessione
    // rinnovata", spec dock-degli-agenti §3).
    func sideLabel(id: String, text: String?, style: SideLabelStyle, claim: Int = 0, stays: Bool = false,
                   ifFree: Bool = false) -> some View {
        modifier(SideLabelModifier(id: id, text: text, style: style, claim: claim, stays: stays, ifFree: ifFree))
    }
}

private struct SideLabelModifier: ViewModifier {
    let id: String, text: String?, style: SideLabelStyle, claim: Int, stays: Bool, ifFree: Bool
    @Environment(\.sideLabels) private var labels
    @Environment(\.barVisibility) private var bar

    func body(content: Content) -> some View {
        if let labels {
            content.modifier(Active(labels: labels, bar: bar, id: id, text: text, style: style, claim: claim, stays: stays, ifFree: ifFree))
        } else { content }
    }

    // I testi degli agenti che durano 5 s sono momenti (spec dock-degli-agenti §1-2): a barra nascosta aspettano (`held`) e i
    // loro 5 s contano da quando la barra si vede; quello che c'è già quando la vista compare (la barra che parte, una
    // finestra spostata) non è una novità, come l'anello che compare finito.
    private struct Active: ViewModifier {
        let labels: SideLabels, bar: BarVisibility?, id: String, text: String?, style: SideLabelStyle, claim: Int, stays: Bool, ifFree: Bool
        @State private var frame = CGRect.zero
        @State private var last: String?
        @State private var hide: DispatchWorkItem?
        @State private var held: String?
        @State private var appeared = false
        private var moment: Bool { if case .agent = style { !stays } else { false } }

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: {
                    // segue la pillola finché si vede, se quello in vista è il suo (testo e cornice)
                    if let text, labels.isShowing(id, text, at: frame) { labels.show(id, SideLabel(text: text, style: style, anchor: $0)) }
                    frame = $0
                }
                .onChange(of: text, initial: true) { _, new in
                    defer { last = new; appeared = true }
                    held = nil
                    guard let new else { hide?.cancel(); labels.release(id, shown: last, at: frame); return }
                    guard labelNews(old: last, new: new), appeared || !moment else { return }
                    if moment, bar?.visible == false { held = new } else { present(new) }
                }
                .onChange(of: bar?.visible) { if bar?.visible == true, let new = held { held = nil; present(new) } }
                // Un testo che resta ("Ti aspetta") lo rimette qualunque vista lo porta ancora: più viste dividono l'id (il Dock
                // e l'icona di uno spazio della stessa app), e quella che se ne va lo toglie a tutte.
                .onChange(of: stays && text != nil && labels.items[id] == nil) { _, gone in if gone, let text { present(text) } }
                .onChange(of: claim) { if let text { labels.claim(id, SideLabel(text: text, style: style, anchor: frame)) } }
                .onChange(of: style) { _, new in   // stesso testo già in vista, cambia solo l'aspetto
                    if let text, labels.items[id]?.text == text { labels.show(id, SideLabel(text: text, style: new, anchor: frame)) }
                }
                .onDisappear { hide?.cancel(); labels.release(id, shown: last, at: frame) }
        }

        private func present(_ new: String) {
            if ifFree, labels.items[id] != nil { return }
            labels.show(id, SideLabel(text: new, style: style, anchor: frame))
            guard style != .dockName, !stays else { return }   // il nome del Dock resta finché il mouse è sulla voce
            debounce(&hide, after: sideLabelSeconds) { [labels, id] in labels.hide(id, ifText: new) }
        }
    }
}

struct SideLabelsView: View {
    let labels: SideLabels
    let opensLeft: Bool   // barra sul bordo destro: i testi escono a sinistra
    @Environment(\.palette) private var palette
    @Environment(\.barScale) private var scale
    private let settings = Settings.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let covered = coveredLabels(labels.items)
                ForEach(labels.items.sorted { $0.key < $1.key }, id: \.key) { id, label in
                    let dock = label.style == .dockName   // compare, cambia voce e sparisce di colpo, come nel Dock di macOS
                    view(label)
                        // il vuoto fra barra e testo; il nome del Dock dal vetro del Dock
                        .padding(opensLeft ? .trailing : .leading,
                                 dock ? dockNameGap(anchor: label.anchor, barWidth: settings.sideWidth, opensLeft: opensLeft) : 8)
                        .frame(width: geo.size.width, alignment: opensLeft ? .trailing : .leading)
                        .position(x: geo.size.width / 2, y: label.anchor.midY - (dock ? 0.5 : 0))   // il nome del Dock mezzo punto più su, come lì
                        .transition(dock ? .identity : .scale(scale: 0.5, anchor: opensLeft ? .trailing : .leading).combined(with: .opacity))
                        .transaction { if dock { $0.animation = nil } }
                        // Coperto dal nome del Dock (coveredLabels) se ne va e torna di colpo come lui, senza animarsi sotto.
                        .opacity(covered.contains(id) ? 0 : 1)
                        .transaction(value: covered.contains(id)) { $0.animation = nil }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.smooth(duration: 0.25), value: labels.items)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func view(_ label: SideLabel) -> some View {
        switch label.style {
        case .glass:
            // Stretta sul testo; oltre 330 pt si ferma lì e tronca in fondo (un frame(maxWidth:) la allargherebbe sempre a 330).
            let text = Text(label.text).font(.system(size: 12 * scale, weight: .semibold)).foregroundStyle(palette?.text ?? .white).lineLimit(1)
            ViewThatFits(in: .horizontal) { text.fixedSize(); text.truncationMode(.tail).frame(width: 330, alignment: .leading) }
                .padding(.horizontal, 10 * scale).frame(height: 26 * scale).modifier(PillBackground())
        case .dockName:
            DockNameLabel(text: label.text)
        case .agent(let color):
            DockNameLabel(text: label.text, color: color)
        }
    }
}

// Accanto a un'icona un testo solo, o due capsule si sovrapporrebbero: prima il nome del Dock al passaggio del mouse (lo
// chiedi tu), poi il testo dell'agente, poi gli altri (l'app davanti). Gli id di quelli coperti: restano, invisibili, e
// tornano quando la riga si libera.
func coveredLabels(_ items: [String: SideLabel]) -> Set<String> {
    func rank(_ id: String) -> Int { id == SideLabels.dock ? 0 : id.hasPrefix("agent-") ? 1 : 2 }
    var rows: [CGFloat] = [], covered: Set<String> = []
    for (id, label) in items.sorted(by: { (rank($0.key), $0.key) < (rank($1.key), $1.key) }) {
        if rows.contains(where: { abs($0 - label.anchor.midY) < 1 }) { covered.insert(id) } else { rows.append(label.anchor.midY) }
    }
    return covered
}
