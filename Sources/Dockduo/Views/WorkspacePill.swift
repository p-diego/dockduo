import AppKit
import SwiftUI

// Icona dal pid dell'app, non dal nome: più processi possono chiamarsi uguale (l'app Shortcuts e il servizio XPC
// ShortcutsViewService, con l'icona generica, che compariva per primo). Cache per bundle id, per nome se manca.
private var iconCache: [String: NSImage] = [:]

func appIcon(_ app: AppEntry) -> NSImage? {
    let key = app.bundle.isEmpty ? app.name : app.bundle
    if let cached = iconCache[key] { return cached }
    guard let icon = NSRunningApplication(processIdentifier: app.pid)?.icon else { return nil }
    iconCache[key] = icon
    return icon
}

// Misure, in scala (nel Dock 26 = 31 pt): il numero e sotto le icone da 20, a 2 pt del Dock l'uno dall'altra come le sue
// caselle; 4 sopra e sotto.
// Trascinare un'icona su un'altra pillola sposta la finestra (IconDrag.swift): il gesto sta qui, simultaneo, così la
// pillola riceve ancora il suo tap e il gruppo il suo ⌘-trascina; lo stato e il rilascio li gestisce la barra (IconDragging).
struct WorkspacePill: View {
    let report: SpaceReport
    let frontWindow: Int?
    let highlighted: Bool                // è la pillola su cui cadrebbe l'icona trascinata
    let dragging: Int?                   // windowID dell'icona che si sta trascinando: qui resta attenuata
    let onDrag: (AppEntry, CGPoint, CGPoint) -> Void   // l'app, il punto di presa e il puntatore, nello spazio "bar"
    let onDrop: (CGPoint) -> Void                      // il puntatore al rilascio
    @Environment(\.palette) private var palette
    @Environment(\.barScale) private var scale
    @Environment(\.barAxis) private var axis

    var body: some View {
        let focused = report.workspace.isFocused
        let reduced = report.workspace.name.isEmpty   // senza AeroSpace (reducedReport): click = attiva l'app, niente spazio né trascinamento
        // Ogni spazio gli stessi margini: uno spazio vuoto è lungo uguale ovunque — i margini per posizione rendevano le
        // misure "strane" (autore, 4/10). Stretti, come una fila di caselle del Dock: coi 12 di prima numero e icone si
        // perdevano nel Dock. In colonna: il nome sopra, le icone una sotto l'altra (spec barra-di-lato §3); in basso in fila.
        BarStack(spacing: 2 * 26 / 31) {
            // La pillola ridotta si presenta: un simbolo al posto del nome dello spazio — e da vuota non è una capsula muta (autore, 3/10).
            if reduced {
                Image(systemName: "macwindow").font(.system(size: 11 * scale)).foregroundStyle(.secondary)
            } else {
                Text(report.workspace.name).font(.system(size: 13 * scale)).fixedSize()
            }
            ForEach(report.apps, id: \.windowID) { app in
                // Il nome accanto all'app a fuoco: gli id delle finestre sono unici, il confronto basta da solo
                // (prima c'era anche `focused &&`, ridondante con AeroSpace e falso in ridotto, dove id = pid).
                AppIconView(app: app, showName: app.windowID == frontWindow, dimmed: app.windowID == dragging,
                            action: { reduced ? showApp(app) : focusWindow(id: app.windowID) })
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named("bar"))
                            .onChanged { onDrag(app, $0.startLocation, $0.location) }
                            .onEnded { onDrop($0.location) }
                    )
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(axis.ends, 4 * scale)
        .frame(axis, across: 26 * scale)
        .modifier(WorkspaceBackground(focused: focused))   // il vetro; dentro un Dock un'evidenziazione interna
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 13 * scale)   // una capsula, come la lente
                    .strokeBorder(palette?.accent ?? .white.opacity(0.5), lineWidth: 1 * scale)
            }
        }
        .onTapGesture { if !reduced { switchTo(workspace: report.workspace.name) } }
        .animation(.smooth(duration: 0.3), value: focused)
    }
}

// Lo sfondo di uno spazio: la solita pillola, oppure — dentro un Dock (\.mergedPill) — niente vetro suo e lo spazio
// attivo evidenziato da una forma piatta interna, come la lente dei pannelli di macOS.
struct WorkspaceBackground: ViewModifier {
    let focused: Bool
    @Environment(\.mergedPill) private var merged
    @Environment(\.palette) private var palette
    @Environment(\.barScale) private var scale

    func body(content: Content) -> some View {
        if merged {
            content
                .foregroundStyle(palette?.text ?? .white)
                .contentShape(Rectangle())   // la superficie di click di tutto il segmento: nelle separate la dava PillBackground (fix 4/10: i click cadevano attraverso)
                .background { if focused { lens } }
        } else {
            content.modifier(PillBackground(active: focused))
        }
    }

    // La lente: il vetro dello sfondo delle pillole (PillBackground), in scala da evidenziazione interna. In scuro è vetro
    // nel vetro del Dock, che scurisce già: velo leggero e tinta un filo blu, tarati sui rapporti pixel fino a combaciare
    // con la pillola separata (4/10).
    private var lens: some View {
        let shape = RoundedRectangle(cornerRadius: 13 * scale)   // una capsula: lo spazio è largo 26
        let tones = ClearTones(palette)
        return shape.fill(tones.lensVeil).glassEffect(.regular.tint(tones.lensTint), in: shape)
    }
}

struct AppIconView: View {
    let app: AppEntry
    let showName: Bool    // è l'app in primo piano: il nome esce di lato (sideLabel)
    var dimmed = false      // la sua icona si sta trascinando altrove
    var size: CGFloat = 20  // il lato dell'icona, in scala (il Dock le ha più grandi)
    let action: () -> Void
    @Environment(\.barScale) private var scale
    @Environment(\.palette) private var palette

    var body: some View {
        let label = agentLabel(app.agent, nagging: app.nagging), id = "agent-\(app.pid)"   // un testo per app, anche con più finestre
        let renewed = !app.agents.isDisjoint(with: QuotaCache.shared.renewed)
        HStack {
            if let icon = appIcon(app) {
                Image(nsImage: icon).resizable().frame(width: size * scale, height: size * scale)
                    .shadow(color: .black.opacity(0.3), radius: 2 * scale)
                    .overlay { AgentRing(state: app.agent, nagging: app.nagging) }
            }
        }
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.3 : 1)
        // Simultaneo, non esclusivo: anche la pillola riceve il click (il glass anima la pressione);
        // il suo `workspace N` è un no-op se siamo già lì.
        .simultaneousGesture(TapGesture().onEnded(action))
        .overlay(AppMenu(app: app))   // sopra: riceve il click destro, inoltra i sinistri
        .sideLabel(id: "front", text: showName ? app.name : nil, style: .glass)   // nella pillola non sta (spec barra-di-lato §4)
        // "Ti aspetta" e "Finito" sull'app, non più nel fumetto di una mascotte (spec dock-degli-agenti §2), col colore dello
        // stato dove si legge (DockNameLabel); "Sessione rinnovata" quando i limiti di un suo agente ripartono, se lì non c'è
        // già un altro testo (§3).
        .sideLabel(id: id, text: label?.text, style: .agent(color: label?.state.color(in: palette)), stays: app.nagging)
        .sideLabel(id: id, text: renewed ? String(localized: "Session renewed") : nil, style: .agent(color: nil), ifFree: true)
        .animation(.smooth(duration: 0.3), value: showName)
    }
}

// Il testo di un agente accanto all'app (spec dock-degli-agenti §2): "Ti aspetta" finché aspetta e non ci sei andato (resta),
// "Finito" quando la sua sessione più urgente ha finito (5 s, contati da quando la barra si vede: sideLabel). Un'attesa vista
// e il lavoro non dicono niente.
func agentLabel(_ agent: AgentState?, nagging: Bool) -> (text: String, state: AgentState)? {
    switch agent {
    case .waiting where nagging: (String(localized: "Waiting for you"), .waiting)
    case .done: (String(localized: "Finished"), .done)
    default: nil
    }
}

// I colori degli stati, gli stessi per il bordo delle icone e per i testi degli agenti sull'app. Col vetro quelli di sempre: blu
// fisso (non l'accento di sistema: con accento verde o giallo si confonderebbe con finito e in attesa), il giallo
// #FFD34F, verde chiaro. In chiaro quelli di clearLight.
extension AgentState {
    func color(in palette: Palette?) -> Color {
        switch self {
        case .working: palette?.blue ?? Color(nsColor: .systemBlue)   // puro (autore, 12/10: schiarito al 35 % era spento)
        case .waiting: palette?.yellow ?? Color(red: 1, green: 0.83, blue: 0.31)   // #FFD34F
        case .done: palette?.green ?? Color(red: 0.6, green: 1, blue: 0.6)
        }
    }

    // La testa del giro dell'anello, `by` da 0 (il colore del bordo) a 1. Una regola sola, dalla luce dell'anello: su un
    // anello chiaro (il giallo e il verde dello scuro) una tinta viva, su uno più scuro (il blu, e in chiaro l'arancio e il
    // verde di sistema) il bordo schiarito: la tinta viva su arancio e verde di sistema quasi non si vedeva (autore, 25/10:
    // «bene l'animazione su blu, quella su giallo e verde non hanno abbastanza contrasto» → «V3 · testa viva», tarata sullo
    // scuro).
    func lapHead(on ring: Color, by amount: Double) -> Color {
        guard luminance(ring) > 0.5 else { return ring.mix(with: .white, by: 0.85 * amount) }
        return ring.mix(with: vivid, by: amount)
    }

    private var vivid: Color {
        switch self {
        case .working: Color(red: 0, green: 0.48, blue: 1)   // blu puro (nessun anello blu è chiaro, oggi)
        case .waiting: Color(red: 1, green: 0.5, blue: 0)    // arancio vivo
        case .done: Color(red: 0, green: 0.72, blue: 0.3)    // smeraldo
        }
    }
}

// Stato dell'agente AI attorno all'icona (spec agenti §4, rivista il 2026-09-24 sera): un bordo di 1 pt sul margine
// esterno dell'icona, blu = al lavoro, giallo = aspetta te, verde = finito. Compare e sparisce con il withAnimation del
// Poller. Ogni tanto fa un giro (spec dock-degli-agenti §1, autore 25/10 sera): una scia chiara corre lungo l'anello, la
// stessa per tutti gli stati nel loro colore; al lavoro ogni 10 s, ti aspetta ogni 30 s finché l'app non è vista
// (`nagging` falso: giallo fermo), finito uno solo.
// Costo: ogni cambio dello schermo lo paga il WindowServer (~5 ms, chiunque disegni). Fra un giro e l'altro niente
// ridisegni: il battito (ringClock) arriva solo all'inizio di un giro, il keyframeAnimator anima solo per la sua durata e
// poi resta l'anello fermo di sempre. Fermo anche con la barra nascosta o coperta e con "Riduci movimento".
struct AgentRing: View {
    let state: AgentState?
    var nagging = true
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ringClock) private var clock
    @Environment(\.barVisibility) private var bar
    @State private var beat = 0   // cambia = parte un giro
    @State private var held = false   // il giro di un cambio di stato arrivato a barra nascosta

    var body: some View {
        let motion = ringMotion(state, nagging: nagging, reduceMotion: reduceMotion)
        // Il battito e i cambi stanno fuori dall'anello, sempre presenti: un'icona senza anello che comincia ad aspettare o a
        // lavorare (dopo "Reimposta l'agente", la scadenza dei 10 minuti, un riavvio a metà sessione) gira subito, come un
        // cambio di stato, e non al battito dopo.
        Color.clear
            .overlay {
                if let state {
                    let color = state.color(in: palette)
                    Color.clear
                        .keyframeAnimator(initialValue: 0.0, trigger: beat) { _, t in RingLook(state: state, color: color, t: t) }
                            keyframes: { _ in MoveKeyframe(0.0); LinearKeyframe(1.0, duration: motion.lasting) }
                        .transition(.opacity)
                }
            }
            // Un giro subito quando lo stato cambia (comincia il lavoro, l'attesa, finisce), poi ai battiti, allineati per
            // tutti gli anelli (nextMovement): dieci app al lavoro girano insieme. Un'icona che compare già con uno stato (la
            // barra che parte, un'app che si sposta) aspetta il battito; comparsa già finita, nessun giro. Il giro di un cambio
            // a barra nascosta parte quando la barra si vede (spec §1: il verde di "finito" aspetta che la barra esca); quelli
            // dei battiti no, c'è il prossimo.
            .onChange(of: motion) { move(motion, holds: true) }
            .onChange(of: bar?.visible) { if bar?.visible == true, held { held = false; move(motion) } }
            .task(id: motion) {
                guard let every = motion.every else { return }
                while (try? await clock.wait(every)) != nil { move(motion) }
            }
    }

    // Solo nella barra e se la si vede: fuori (anteprime, icone dei menu) l'anello resta fermo.
    private func move(_ motion: RingMotion, holds: Bool = false) {
        guard motion != .none, let bar else { return }
        if bar.visible { beat += 1 } else if holds { held = true }
    }
}

enum RingMotion: Equatable {
    case none, lap(every: TimeInterval, lasting: TimeInterval), lapOnce(lasting: TimeInterval)

    var every: TimeInterval? {
        if case let .lap(every, _) = self { every } else { nil }
    }

    var lasting: TimeInterval {
        switch self {
        case .none: 0
        case let .lap(_, lasting), let .lapOnce(lasting): lasting
        }
    }
}

func ringMotion(_ state: AgentState?, nagging: Bool, reduceMotion: Bool) -> RingMotion {
    guard !reduceMotion else { return .none }
    switch state {
    case .working: return .lap(every: 10, lasting: 1.5)
    case .waiting: return nagging ? .lap(every: 30, lasting: 1.5) : .none
    case .done: return .lapOnce(lasting: 1.5)
    case nil: return .none
    }
}

// Il prossimo inizio di movimento: i multipli di `every` dall'inizio del tempo, uguali per tutti gli anelli.
func nextMovement(after now: TimeInterval, every: TimeInterval) -> TimeInterval {
    ((now / every).rounded(.down) + 1) * every
}

// Il battito degli anelli: `wait` aspetta l'inizio del prossimo movimento, `drawn` arriva a ogni fotogramma (col suo
// punto del movimento). Li sostituiscono solo i test (AgentRingTests), una volta per anello: per SwiftUI due orologi sono
// sempre uguali.
struct RingClock: Equatable {
    var wait: (TimeInterval) async throws -> Void = { every in
        let now = Date.now.timeIntervalSinceReferenceDate
        try await Task.sleep(for: .seconds(nextMovement(after: now, every: every) - now))
    }
    var drawn: (Double) -> Void = { _ in }
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var ringClock = RingClock()
}

// Un fotogramma dell'anello: `t` da 0 a 1 nel giro; a 0 e a 1 l'anello fermo di sempre. Nel giro lo stesso bordo si
// colora di una scia (autore: «un gradiente, chiaro che finisce sul colore del bordo»): la testa (lapHead) parte
// dall'alto, corre in senso orario e la coda sfuma nel colore dell'anello; entra e se ne va sfumando. Solo sulla linea:
// niente ombre colorate dentro l'icona.
struct RingLook: View {
    let state: AgentState
    let color: Color
    let t: Double
    @Environment(\.barScale) private var scale
    @Environment(\.ringClock) private var clock

    var body: some View {
        let _ = clock.drawn(t)
        let shape = RoundedRectangle(cornerRadius: 5 * scale)
        Group {
            if t > 0 && t < 1 {
                let fade = min(1, t / 0.2, (1 - t) / 0.2)   // entra e se ne va
                let light = state.lapHead(on: color, by: fade * fade * (3 - 2 * fade))
                let head = Angle.degrees(-90 + 360 * t)   // dall'alto, in senso orario
                // Il gradiente gira con la testa: dietro di lei la coda (un terzo dell'anello) torna al colore del bordo.
                shape.strokeBorder(AngularGradient(stops: [.init(color: color, location: 0), .init(color: color, location: 0.66),
                                                           .init(color: light, location: 1)],
                                                   center: .center, startAngle: head - .degrees(360), endAngle: head),
                                   lineWidth: 1 * scale)
            } else {
                shape.strokeBorder(color, lineWidth: 1 * scale)
            }
        }
        .padding(1 * scale)   // l'icona di macOS non riempie i suoi 20 pt: il bordo corre appena fuori dal suo margine
        .shadow(color: .black.opacity(0.6), radius: 0.5 * scale)   // stacco sulle icone chiare
    }
}
