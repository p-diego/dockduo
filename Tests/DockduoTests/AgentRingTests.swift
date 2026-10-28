import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Il movimento di ogni stato (spec dock-degli-agenti §1, autore 25/10 sera): lo stesso giro per tutti, al lavoro ogni 10 s,
// ti aspetta ogni 30 s finché l'app non è vista, finito uno solo; niente con "Riduci movimento".
@Test func ringMotionFollowsTheState() {
    #expect(ringMotion(.working, nagging: true, reduceMotion: false) == .lap(every: 10, lasting: 1.5))
    #expect(ringMotion(.waiting, nagging: true, reduceMotion: false) == .lap(every: 30, lasting: 1.5))
    #expect(ringMotion(.waiting, nagging: false, reduceMotion: false) == .none)
    #expect(ringMotion(.done, nagging: true, reduceMotion: false) == .lapOnce(lasting: 1.5))
    #expect(ringMotion(nil, nagging: true, reduceMotion: false) == .none)
    for state in [AgentState.working, .waiting, .done, nil] {
        #expect(ringMotion(state, nagging: true, reduceMotion: true) == .none)
    }
}

// Review Focus 3: gli anelli si muovono agli stessi istanti, dieci app al lavoro fanno un giro solo ogni 10 s tutte
// insieme, non uno sfasato dopo l'altro (la barra non smetterebbe mai di ridisegnarsi).
@Test func ringsMoveTogether() {
    #expect(nextMovement(after: 12.3, every: 10) == 20)
    #expect(nextMovement(after: 20, every: 10) == 30)
    #expect(nextMovement(after: 12.3, every: 30) == 30)
}

// Fra un giro e l'altro l'anello è quello fermo di sempre: com'era prima del giro (t = 0) resta dopo (il keyframeAnimator
// si ferma a t = 1); a metà giro la scia si vede. Fra due immagini uguali ImageRenderer sbaglia a volte di 1 su qualche
// byte: si confronta la differenza più grande.
@MainActor @Test func theRingAtRestIsTheSameBeforeAndAfterALap() throws {
    for state in [AgentState.working, .waiting, .done] {
        let color = state.color(in: nil)
        let before = try pixels(RingLook(state: state, color: color, t: 0))
        #expect(try maxDifference(before, pixels(RingLook(state: state, color: color, t: 1))) <= 1)
        #expect(try maxDifference(before, pixels(RingLook(state: state, color: color, t: 0.5))) > 30)
    }
}

// La testa del giro (autore, 25/10: «V3 · testa viva»): sul blu il bordo schiarito all'85 % come prima, sul giallo
// arancio vivo, sul verde smeraldo; a inizio e fine giro (by 0) il colore del bordo. Sul thread principale: il blu è un
// colore di sistema (NSColor) e risolverlo altrove si blocca aspettando il principale.
@MainActor @Test func theLapHeadIsVividOnYellowAndGreen() {
    let blue = AgentState.working.color(in: nil), yellow = AgentState.waiting.color(in: nil), green = AgentState.done.color(in: nil)
    #expect(near(AgentState.working.lapHead(on: blue, by: 1), blue.mix(with: .white, by: 0.85)))
    #expect(near(AgentState.waiting.lapHead(on: yellow, by: 1), Color(red: 1, green: 0.5, blue: 0)))
    #expect(near(AgentState.done.lapHead(on: green, by: 1), Color(red: 0, green: 0.72, blue: 0.3)))
    for (state, ring) in [(AgentState.working, blue), (.waiting, yellow), (.done, green)] {
        #expect(near(state.lapHead(on: ring, by: 0), ring))
    }
}

// In chiaro gli anelli sono l'arancio e il verde di sistema, scuri come il blu: la stessa regola (la luce dell'anello) dà a
// tutti e tre il bordo schiarito, perché una testa arancio o smeraldo su di loro quasi non si vedeva.
@MainActor @Test func theLapHeadIsLightOnTheDarkerRingsOfLightMode() {
    for state in [AgentState.working, .waiting, .done] {
        let ring = state.color(in: clearLight)
        for amount in [0.5, 1] { #expect(near(state.lapHead(on: ring, by: amount), ring.mix(with: .white, by: 0.85 * amount))) }
    }
}

@MainActor private func near(_ a: Color, _ b: Color) -> Bool {
    let (x, y) = (a.resolve(in: EnvironmentValues()), b.resolve(in: EnvironmentValues()))
    return [x.red - y.red, x.green - y.green, x.blue - y.blue].allSatisfy { abs($0) < 0.005 }
}

private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? .max }

// Review Focus 3: finito il giro l'anello non si ridisegna più fino al prossimo battito (qui fra un'ora: il tempo passa
// senza altri movimenti). Fuori dallo schermo SwiftUI anima senza il ritmo dello schermo, a migliaia di immagini al
// secondo: un ridisegno a riposo ne darebbe centinaia. Il giro si conta dai fotogrammi (RingHost.laps), non dal tempo.
@MainActor @Test func theRingIsStillBetweenMovements() async throws {
    let ring = RingHost(.working, ticks: 1)
    try await until { ring.laps == 1 }   // il giro è partito ed è finito (un fotogramma a t = 1 dopo uno prima della fine)
    let still = ring.frames
    try await Task.sleep(for: .seconds(3))
    #expect(ring.laps == 1 && ring.restFrames(since: still) == 0)
    withExtendedLifetime(ring) {}
}

// Barra nascosta (fuori, coperta, o per macOS non visibile: BarVisibility): il battito arriva e l'anello non si muove, né
// lo recupera quando la barra si vede (c'è il prossimo). Il giro di un cambio di stato invece aspetta: il verde di "finito"
// parte quando la barra esce (spec dock-degli-agenti §1, "Con la barra nascosta").
@MainActor @Test func aHiddenBarHoldsTheLapOfAChange() async throws {
    let ring = RingHost(.working, ticks: 1, visible: false)
    try await until { ring.waits == 2 }   // il battito è arrivato e l'anello è tornato ad aspettare
    ring.visibility.visible = true
    try await Task.sleep(for: .seconds(0.4))
    #expect(ring.moved == 0)
    ring.visibility.visible = false
    ring.show(.done)
    try await Task.sleep(for: .seconds(0.4))
    #expect(ring.moved == 0)
    ring.visibility.visible = true
    try await until { ring.laps == 1 }   // il giro tenuto parte e finisce (che sia uno solo lo dice theDoneLapPlaysOnce)
    withExtendedLifetime(ring) {}
}

// Finito: un giro appena lo stato lo diventa, poi verde fermo.
@MainActor @Test func theDoneLapPlaysOnce() async throws {
    let ring = RingHost(.working, ticks: 0)
    ring.show(.done)
    try await until { ring.laps == 1 }
    let still = ring.frames
    try await Task.sleep(for: .seconds(1))
    #expect(ring.laps == 1 && ring.restFrames(since: still) == 0)
    withExtendedLifetime(ring) {}
}

// Un'icona che c'è già e non aveva l'anello comincia ad aspettare (dopo "Reimposta l'agente", la scadenza dei 10 minuti, un
// riavvio a metà sessione): un giro subito, come a ogni cambio di stato, non al battito dopo (qui fra un'ora).
@MainActor @Test func anExistingIconThatStartsWaitingLapsAtOnce() async throws {
    let ring = RingHost(nil, ticks: 0)
    ring.show(.waiting)
    try await until { ring.laps == 1 }
    withExtendedLifetime(ring) {}
}

// Un anello che compare con uno stato (la barra che parte, un'app che si sposta) non gira subito: aspetta il battito;
// comparso già finito, nessun giro.
@MainActor @Test func anAppearingRingWaitsForTheBeat() async throws {
    let rings = [RingHost(.working, ticks: 0), RingHost(.waiting, ticks: 0), RingHost(.done, ticks: 0)]
    try await Task.sleep(for: .seconds(0.5))
    #expect(rings.allSatisfy { $0.moved == 0 })
    withExtendedLifetime(rings) {}
}

// I pixel di una vista a 2×, in sRGB.
@MainActor private func pixels(_ view: some View) throws -> [UInt8] {
    let renderer = ImageRenderer(content: Color.gray.frame(width: 20, height: 20).overlay { view })
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}

// Aspetta che `done` diventi vero, fino a 30 s: con tutta la suite il thread principale resta occupato dagli altri test
// anche per 7 s di fila (misurato), e un anello aspetta lì il suo battito.
@MainActor func until(_ done: () -> Bool) async throws {   // anche per AgentSeenTests
    let deadline = Date.now + 30
    while !done() {
        try #require(Date.now < deadline, "tempo scaduto")
        try await Task.sleep(for: .milliseconds(20))
    }
}

// Una finestra di prova visibile per macOS, finché non la si copre: fuori dallo schermo una NSWindow non è mai visibile
// (`occlusionState` senza `.visible`). L'anello e i testi d'agente non la guardano: leggono BarVisibility (SidePanel).
final class TestWindow: NSWindow {
    var covered = false
    override var occlusionState: NSWindow.OcclusionState { covered ? [] : .visible }
}

// Un anello in una finestra fuori schermo, con un orologio finto: `ticks` battiti a 0,1 s, poi il prossimo fra un'ora.
// Conta i fotogrammi che l'anello disegna e i giri, dai fotogrammi: un giro è un fotogramma a t = 1 dopo uno prima della
// fine. Non i fotogrammi a metà né quelli a t = 1: con il thread principale occupato dagli altri test SwiftUI salta anche
// tutto il giro (da 0 a 1 in un fotogramma) e lo chiude a volte con due fotogrammi a t = 1, a un millesimo di secondo
// l'uno dall'altro (misurato il 25/10). `moved`: i fotogrammi lontani dal riposo di partenza (t = 0), per dire che un
// anello non si è mai mosso, giro finito o no. E le volte che l'anello si è messo ad aspettare il battito.
@MainActor private final class RingHost {
    var frames = 0, laps = 0, moved = 0, waits = 0
    private var last = 0.0
    private var lapEnds: [Int] = []   // il numero del fotogramma che chiude ogni giro
    var ticks: Int
    let visibility = BarVisibility()
    private let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(_ state: AgentState?, ticks: Int, visible: Bool = true) {
        _ = NSApplication.shared
        self.ticks = ticks
        visibility.visible = visible
        window.contentView = host
        show(state)
    }

    func show(_ state: AgentState?) {
        host.rootView = AnyView(AgentRing(state: state).frame(width: 20, height: 20)
            .environment(\.barVisibility, visibility)
            .environment(\.ringClock, RingClock(wait: { [weak self] _ in try await Task.sleep(for: .seconds(self?.beat() ?? 3600)) },
                                                 drawn: { [weak self] t in self?.count(t) })))
        host.layoutSubtreeIfNeeded()
    }

    // Quanto manca al prossimo battito: 0,1 s finché ce ne sono, poi un'ora.
    private func beat() -> TimeInterval {
        waits += 1
        guard ticks > 0 else { return 3600 }
        ticks -= 1
        return 0.1
    }

    private func count(_ t: Double) {
        frames += 1
        if t > 0 { moved += 1 }
        if t == 1 && last < 1 { laps += 1; lapEnds.append(frames) }
        last = t
    }

    // I fotogrammi a riposo dopo `since`: oltre al gemello che può chiudere l'ultimo giro (un fotogramma subito dopo il suo),
    // ogni fotogramma è un ridisegno di troppo.
    func restFrames(since: Int) -> Int {
        let twin = lapEnds.last.map { $0 + 1 > since ? 1 : 0 } ?? 0
        return max(0, frames - since - twin)
    }
}

// I giri in chiaro, a colpo d'occhio, solo a richiesta (RING_SHEET=<file.png> swift test --filter ringSheetLight): una riga
// per stato coi colori del chiaro (clearLight) sul fondo chiaro, l'icona grande com'è con la barra dell'autore (larga 70),
// a riposo e in cinque punti del giro.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RING_SHEET"] != nil)) func ringSheetLight() throws {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RING_SHEET"]!)
    let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
    let scale: CGFloat = 70 / 38, tile = 31 * dockUnit * scale
    let sheet = VStack(alignment: .leading, spacing: 16) {
        ForEach([(AgentState.working, "Al lavoro"), (.waiting, "Ti aspetta"), (.done, "Finito")], id: \.1) { state, name in
            HStack(spacing: 24) {
                Text(name).font(.system(size: 13)).foregroundStyle(.black).frame(width: 80, alignment: .leading)
                ForEach([0, 0.15, 0.3, 0.45, 0.6, 0.75], id: \.self) { t in
                    Image(nsImage: icon).resizable().frame(width: tile, height: tile)
                        .overlay { RingLook(state: state, color: state.color(in: clearLight), t: t) }
                }
            }
        }
    }
    .padding(24).background(Color(red: 0.93, green: 0.93, blue: 0.95)).environment(\.barScale, scale)
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
}

// Il video dei tre giri, solo a richiesta:
//   RING_ANIM=<cartella> swift test --filter ringAnimationFrames
//   ffmpeg -framerate 60 -i <cartella>/%04d.png -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" -c:v libx264 -pix_fmt yuv420p anello.mp4
// Al lavoro, ti aspetta e finito su un'icona del Dock grande com'è con la barra dell'autore (larga 70: ~42 pt), sul fondo
// scuro e sul chiaro, 60 immagini al secondo: i tre giri partono insieme a 0,25 s (come ai battiti allineati), poi
// l'anello fermo.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RING_ANIM"] != nil)) func ringAnimationFrames() throws {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RING_ANIM"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
    let states: [(AgentState, String)] = [(.working, "Al lavoro"), (.waiting, "Ti aspetta"), (.done, "Finito")]
    let scale: CGFloat = 70 / 38, tile = 31 * dockUnit * scale
    for frame in 0..<150 {
        let time = Double(frame) / 60 - 0.25
        let rows = VStack(spacing: 0) {
            ForEach([true, false], id: \.self) { dark in
                HStack(spacing: 36) {
                    ForEach(states, id: \.1) { state, name in
                        let motion = ringMotion(state, nagging: true, reduceMotion: false)
                        VStack(spacing: 8) {
                            Image(nsImage: icon).resizable().frame(width: tile, height: tile)
                                .overlay { RingLook(state: state, color: state.color(in: nil), t: min(max(time / motion.lasting, 0), 1)) }
                            Text(name).font(.system(size: 13)).foregroundStyle(dark ? .white : .black)
                        }
                    }
                }
                .padding(24)
                .background(dark ? Color(red: 30 / 255, green: 32 / 255, blue: 38 / 255) : Color(red: 0.93, green: 0.93, blue: 0.95))
            }
        }
        .environment(\.barScale, scale)
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        // In sRGB a 8 bit: su uno schermo HDR ImageRenderer dà un'immagine PQ a 16 bit, che ffmpeg legge senza profilo (spenta).
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent(String(format: "%04d.png", frame)))
    }
}
