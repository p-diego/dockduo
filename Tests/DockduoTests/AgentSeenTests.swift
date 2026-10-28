import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Un messaggio di dockduo-hook per la sessione `id` nell'app com.code; `extra` va in fondo al payload.
private func message(_ state: String, id: String = "s", extra: String = "") -> Data {
    Data(#"{"agent":"claude","state":"\#(state)","bundle":"com.code","payload":{"session_id":"\#(id)","cwd":"/x"\#(extra)}}"#.utf8)
}

private let code = AppEntry(name: "Code", pid: 7, windowID: 0, bundle: "com.code")
private func dockEntry(_ bar: BarState) -> AppEntry {
    dockApps(running: [code], launched: [:], visible: [7], sessions: Array(bar.sessions.values))[0]
}

// Review Focus 1: un'attesa che hai già visto non gira, non dice "Ti aspetta" e non suona più. Attivare la sua app la
// vede; se l'app è già davanti quando l'attesa comincia, è vista da subito. L'attesa resta: l'anello giallo fermo.
@MainActor @Test func aWaitSeenInItsAppStopsNagging() {
    let bar = BarState()
    var front: String? = "com.other"
    let server = AgentServer(state: bar, path: "/tmp/dockduo-unused.sock", changed: {}, front: { front })
    server.apply(message("waiting"))
    #expect(dockEntry(bar).nagging)
    #expect(ringMotion(dockEntry(bar).agent, nagging: dockEntry(bar).nagging, reduceMotion: false) == .lap(every: 30, lasting: 1.5))

    markSeen(bundle: "com.other", sessions: &bar.sessions)   // un'altra app: niente
    #expect(dockEntry(bar).nagging)
    markSeen(bundle: "com.code", sessions: &bar.sessions)
    #expect(bar.sessions["s"]?.state == .waiting && !dockEntry(bar).nagging)
    #expect(ringMotion(dockEntry(bar).agent, nagging: dockEntry(bar).nagging, reduceMotion: false) == .none)
    server.apply(message("waiting"))   // l'attesa continua: resta vista
    #expect(!dockEntry(bar).nagging)

    // Una nuova attesa (dopo un turno finito) non è vista; con l'app davanti sì. Niente "working" qui: spegnerebbe i rinnovi
    // di QuotaCache.shared mentre RenewedAccounts li guarda.
    server.apply(message("done"))
    server.apply(message("waiting"))
    #expect(bar.sessions["s"]?.seen == false)
    front = "com.code"
    server.apply(message("waiting", id: "t"))
    #expect(bar.sessions["t"]?.seen == true)
}

private let idlePrompt = #","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt""#

// Review Focus 4: Claude, un minuto dopo un turno finito, manda la notifica "fermo" (idle_prompt): il turno resta finito,
// niente giallo, niente ridisegno. Un permesso invece è un'attesa vera, e la notifica "fermo" non la tocca.
@MainActor @Test func anIdleTurnStaysDone() {
    let bar = BarState()
    var ticks = 0
    let server = AgentServer(state: bar, path: "/tmp/dockduo-unused.sock", changed: { ticks += 1 }, front: { nil })
    server.apply(message("done"))
    server.apply(message("waiting", extra: idlePrompt))
    #expect(bar.sessions["s"]?.state == .done && ticks == 1)
    server.apply(message("waiting", extra: #","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#))
    #expect(bar.sessions["s"]?.state == .waiting && ticks == 2)
    server.apply(message("waiting", extra: idlePrompt))
    #expect(bar.sessions["s"]?.state == .waiting && ticks == 2)
}

// Ruling #5 (27/10): un turno interrotto (Esc) non manda Stop e restava al lavoro 10 minuti; la notifica "fermo" lo chiude,
// in silenzio: niente suono, attesa né testo. Una seconda non crea niente.
@MainActor @Test func anInterruptedTurnEndsOnIdlePrompt() {
    let bar = BarState()
    var ticks = 0, sounds = 0
    let server = AgentServer(state: bar, path: "/tmp/dockduo-unused.sock", changed: { ticks += 1 }, front: { nil }, sound: { _ in sounds += 1 })
    // Al lavoro senza passare da apply: un "working" spegnerebbe i rinnovi di QuotaCache.shared mentre RenewedAccounts li guarda.
    bar.sessions["s"] = AgentSession(id: "s", agent: .claude, state: .working, cwd: "/x", bundle: "com.code", since: .now, updatedAt: .now)
    server.apply(message("waiting", extra: idlePrompt))
    #expect(bar.sessions["s"] == nil && ticks == 1 && sounds == 0)
    server.apply(message("waiting", extra: idlePrompt))
    #expect(bar.sessions.isEmpty && ticks == 1 && sounds == 0)
}

// Un suono per un'attesa che non hai visto e per un turno finito (spec dock-degli-agenti §4); niente per un'attesa vista (ci
// sei andato e l'agente la ripete, o è cominciata con la sua app davanti) né per il turno fermo di Claude.
@MainActor @Test func theSoundsFollowTheMoments() {
    let bar = BarState()
    var front: String?, sounds: [AgentState] = []
    let server = AgentServer(state: bar, path: "/tmp/dockduo-unused.sock", changed: {}, front: { front }, sound: { sounds.append($0.state) })
    server.apply(message("waiting"))
    markSeen(bundle: "com.code", sessions: &bar.sessions)
    server.apply(message("waiting"))
    server.apply(message("done"))
    server.apply(message("waiting", extra: #","hook_event_name":"Notification","notification_type":"idle_prompt""#))
    front = "com.code"
    server.apply(message("waiting", id: "t"))
    #expect(sounds == [.waiting, .done])
}

// Il testo accanto all'app (spec dock-degli-agenti §2): "Ti aspetta" finché aspetta e non ci sei andato, "Finito" quando ha
// finito; un'attesa vista e il lavoro non dicono niente.
@Test func agentLabelFollowsTheApp() {
    #expect(agentLabel(.waiting, nagging: true)?.text == "Waiting for you")
    #expect(agentLabel(.waiting, nagging: true)?.state == .waiting)
    #expect(agentLabel(.waiting, nagging: false) == nil)
    #expect(agentLabel(.done, nagging: false)?.text == "Finished")
    #expect(agentLabel(.done, nagging: false)?.state == .done)
    #expect(agentLabel(.working, nagging: false) == nil)
    #expect(agentLabel(nil, nagging: false) == nil)
}

// I testi degli agenti a barra nascosta aspettano: "Finito" esce (e i suoi 5 s partono) quando la barra si vede. Un testo che
// c'è già quando la vista compare non è una novità. "Sessione rinnovata" esce solo se lì non c'è già un altro testo.
@MainActor @Test func agentLabelsWaitForTheBar() async throws {
    let labels = SideLabels(), bar = BarVisibility()
    bar.visible = true
    let host = LabelHost(labels: labels, bar: bar)
    host.show("Finished")   // compare già finita, a barra in vista: niente
    try await Task.sleep(for: .milliseconds(200))
    #expect(labels.items.isEmpty)

    bar.visible = false
    host.show(nil); host.show("Finished")   // finisce a barra nascosta
    try await Task.sleep(for: .milliseconds(200))
    #expect(labels.items.isEmpty)
    bar.visible = true
    try await until { labels.items["agent-7"]?.text == "Finished" }

    host.show("Finished", renewed: "Session renewed")   // c'è già "Finito": il rinnovo non lo copre
    try await Task.sleep(for: .milliseconds(200))
    #expect(labels.items["agent-7"]?.text == "Finished")
    host.show(nil); host.show(nil, renewed: "Session renewed")   // lì non c'è niente: esce
    try await until { labels.items["agent-7"]?.text == "Session renewed" }
    withExtendedLifetime(host) {}
}

// Il Dock e l'icona di uno spazio della stessa app dividono l'id del testo: se quella che l'ha messo in vista se ne va
// (la finestra chiusa o spostata), "Ti aspetta" torna dall'altra, che aspetta ancora.
@MainActor @Test func aStayingLabelComesBackFromTheViewThatIsLeft() async throws {
    _ = NSApplication.shared
    let labels = SideLabels(), bar = BarVisibility()
    bar.visible = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    window.contentView = host
    func show(_ both: Bool) {
        host.rootView = AnyView(TwoIcons(both: both).environment(\.sideLabels, labels).environment(\.barVisibility, bar))
        host.layoutSubtreeIfNeeded()
    }
    show(false)
    try await until { labels.items["agent-7"] != nil }
    let first = try #require(labels.items["agent-7"]).anchor
    show(true)   // la seconda lo prende
    try await until { labels.items["agent-7"].map { $0.anchor != first } == true }
    show(false)   // e se ne va: torna dalla prima
    try await until { labels.items["agent-7"]?.anchor == first }
    #expect(labels.items["agent-7"]?.text == "Waiting for you")
    withExtendedLifetime(window) {}
}

private struct TwoIcons: View {
    let both: Bool
    var body: some View {
        VStack(spacing: 0) {
            icon
            if both { icon }
        }
    }
    private var icon: some View {
        Color.clear.frame(width: 20, height: 20).sideLabel(id: "agent-7", text: "Waiting for you", style: .agent(color: .yellow), stays: true)
    }
}

// Due testi d'agente sulla stessa icona di prova, come in AppIconView: lo stato e il rinnovo.
@MainActor private final class LabelHost {
    let labels: SideLabels, bar: BarVisibility
    private let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(labels: SideLabels, bar: BarVisibility) {
        _ = NSApplication.shared
        (self.labels, self.bar) = (labels, bar)
        window.contentView = host
    }

    func show(_ text: String?, renewed: String? = nil) {
        host.rootView = AnyView(Color.clear.frame(width: 20, height: 20)
            .sideLabel(id: "agent-7", text: text, style: .agent(color: .green))
            .sideLabel(id: "agent-7", text: renewed, style: .agent(color: nil), ifFree: true)
            .environment(\.sideLabels, labels).environment(\.barVisibility, bar))
        host.layoutSubtreeIfNeeded()
    }
}

// La prova a occhio dei testi sull'app (AGENT_LABEL_SHOTS=cartella): a 2×, in scuro e in chiaro, un'icona del Dock a barra 52
// col suo anello e accanto, a 8 pt, la capsula del nome del Dock con "Ti aspetta", "Finito" e "Sessione rinnovata" nei colori
// di AppIconView. Fuori dallo schermo il vetro non si disegna: sotto ogni capsula il suo chiaro misurato (dockNameShot), e
// sotto l'icona un riquadro del colore del Dock (DockSectionShots).
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_LABEL_SHOTS"] != nil)) func agentLabelShots() throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENT_LABEL_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
    let rows: [(String, AgentState, Color?)] = [("Ti aspetta", .waiting, AgentState.waiting.color(in: nil)),
                                                ("Finito", .done, AgentState.done.color(in: nil)), ("Sessione rinnovata", .done, nil)]
    for dark in [true, false] {
        let glass = dark ? Color.white.opacity(0.128) : Color(red: 0.94, green: 0.945, blue: 0.955)
        let dock = dark ? Color(red: 13 / 255, green: 14 / 255, blue: 20 / 255) : Color(red: 0.93, green: 0.93, blue: 0.95)
        let view = VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.0) { text, state, color in
                HStack(spacing: 8) {
                    Image(nsImage: icon).resizable().frame(width: 31, height: 31).overlay { AgentRing(state: state) }
                        .padding(7).background(dock).frame(width: 52)
                    DockNameLabel(text: text, color: color).background(Capsule().fill(glass))
                }
            }
        }
        .environment(\.barScale, 52.0 / 38).environment(\.colorScheme, dark ? .dark : .light)
        .padding(.vertical, 16).padding(.leading, 2).frame(width: 260, alignment: .leading)
        .background(dark ? Color(red: 1 / 255, green: 2 / 255, blue: 8 / 255) : Color(red: 0.80, green: 0.83, blue: 0.88))
        // In una finestra mai mostrata, per la scala dello schermo (dockNameShot).
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(dark ? "etichette-scuro.png" : "etichette-chiaro.png"))
        withExtendedLifetime(window) {}
    }
}
