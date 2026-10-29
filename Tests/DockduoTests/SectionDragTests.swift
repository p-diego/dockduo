import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Spostare e togliere le sezioni trascinandole, in modifica (spec impostazioni-nel-dock §2). Solo Dock finti e suite nuove.

private func w(_ ids: WidgetID...) -> [BarItem] { ids.map(BarItem.widget) }

// Come si vede la barra: le sezioni dei Dock di ogni zona, dall'alto (gli id no).
private func look(_ docks: [DockBox]) -> [[[BarItem]]] { Zone.allCases.map { z in docks.filter { $0.zone == z }.map(\.sections) } }

// Un Dock dentro, un altro Dock, un Dock nuovo; il Dock che resta vuoto sparisce; una sezione che non sta in nessun Dock
// (dalla galleria) entra e basta. Gli indici contano i Dock e le sezioni come si vedono, la trascinata compresa.
@Test func aSectionIsPlacedWhereItIsDropped() {
    let a = DockBox(zone: .top, sections: w(.workspaces))
    let b = DockBox(zone: .middle, sections: w(.apps, .folders, .shelf))
    let d = DockBox(zone: .middle, sections: w(.nowPlaying))
    let docks = [a, b, d]
    func placed(_ w: WidgetID, _ t: SectionTarget) -> [[[BarItem]]] { look(sectionPlaced(.widget(w), at: t, docks: docks)) }
    // Nello stesso Dock: davanti a sé o subito dopo resta dov'è.
    #expect(placed(.apps, .into(dock: b.id, index: 0)) == look(docks))
    #expect(placed(.apps, .into(dock: b.id, index: 1)) == look(docks))
    #expect(placed(.apps, .into(dock: b.id, index: 2)) == [[w(.workspaces)], [w(.folders, .apps, .shelf), w(.nowPlaying)], []])
    #expect(placed(.apps, .into(dock: b.id, index: 3)) == [[w(.workspaces)], [w(.folders, .shelf, .apps), w(.nowPlaying)], []])
    #expect(placed(.shelf, .into(dock: b.id, index: 0)) == [[w(.workspaces)], [w(.shelf, .apps, .folders), w(.nowPlaying)], []])
    #expect(placed(.apps, .into(dock: b.id, index: 99)) == [[w(.workspaces)], [w(.folders, .shelf, .apps), w(.nowPlaying)], []])
    // In un altro Dock, che resta lui (stesso id).
    let moved = sectionPlaced(.widget(.shelf), at: .into(dock: a.id, index: 0), docks: docks)
    #expect(look(moved) == [[w(.shelf, .workspaces)], [w(.apps, .folders), w(.nowPlaying)], []])
    #expect(moved.map(\.id) == [a.id, b.id, d.id])
    // Un Dock nuovo fra i Dock di una zona, in fondo a un'altra, in una zona vuota.
    #expect(placed(.folders, .newDock(zone: .middle, index: 1)) == [[w(.workspaces)], [w(.apps, .shelf), w(.folders), w(.nowPlaying)], []])
    #expect(placed(.folders, .newDock(zone: .top, index: 1)) == [[w(.workspaces), w(.folders)], [w(.apps, .shelf), w(.nowPlaying)], []])
    #expect(placed(.folders, .newDock(zone: .top, index: 0)) == [[w(.folders), w(.workspaces)], [w(.apps, .shelf), w(.nowPlaying)], []])
    #expect(placed(.folders, .newDock(zone: .bottom, index: 0)) == [[w(.workspaces)], [w(.apps, .shelf), w(.nowPlaying)], [w(.folders)]])
    // La sola sezione di un Dock: il Dock se ne va con lei.
    let alone = sectionPlaced(.widget(.nowPlaying), at: .into(dock: a.id, index: 1), docks: docks)
    #expect(look(alone) == [[w(.workspaces, .nowPlaying)], [w(.apps, .folders, .shelf)], []] && !alone.contains { $0.id == d.id })
    // Da sola in un Dock e lasciata subito sopra o sotto di lui: la barra resta com'è.
    #expect(placed(.nowPlaying, .newDock(zone: .middle, index: 1)) == look(docks))
    #expect(placed(.nowPlaying, .newDock(zone: .middle, index: 2)) == look(docks))
    // Da nessun Dock (la galleria): entra e basta.
    let two = [a, b]
    #expect(look(sectionPlaced(.widget(.nowPlaying), at: .into(dock: b.id, index: 1), docks: two))
            == [[w(.workspaces)], [w(.apps, .nowPlaying, .folders, .shelf)], []])
    #expect(look(sectionPlaced(.widget(.nowPlaying), at: .newDock(zone: .bottom, index: 0), docks: two))
            == [[w(.workspaces)], [w(.apps, .folders, .shelf)], [w(.nowPlaying)]])
    // Un Dock che non c'è più: niente.
    #expect(sectionPlaced(.widget(.apps), at: .into(dock: UUID(), index: 0), docks: docks) == docks)
}

// Lo Stato non entra mai in un Dock con altre sezioni (Review Focus 2): lasciato dentro un Dock fa un Dock suo subito prima,
// nella stessa zona, e quel Dock resta com'era. Nemmeno un'altra sezione entra nel Dock dello Stato. In un Dock vuoto
// (salvato vuoto) sì.
@Test func theStatusNeverSharesADock() {
    let status = BarItem.widget(.status)
    let s = DockBox(zone: .top, sections: [status]), a = DockBox(zone: .top, sections: w(.workspaces))
    let x = DockBox(zone: .middle, sections: w(.apps, .folders)), y = DockBox(zone: .middle, sections: w(.nowPlaying))
    let docks = [s, a, y, x]
    #expect(sectionLanding(status, at: .into(dock: x.id, index: 1), docks: docks) == .newDock(zone: .middle, index: 1))
    let placed = sectionPlaced(status, at: .into(dock: x.id, index: 1), docks: docks)
    #expect(look(placed) == [[w(.workspaces)], [w(.nowPlaying), [status], w(.apps, .folders)], []])
    #expect(placed.first { $0.id == x.id } == x && placed.filter { $0.sections.contains(status) }.count == 1)
    // Un'altra sezione lasciata nel Dock dello Stato: un Dock suo, subito prima.
    let workspaces = sectionPlaced(.widget(.workspaces), at: .into(dock: s.id, index: 1), docks: docks)
    #expect(look(workspaces) == [[w(.workspaces), [status]], [w(.nowPlaying), w(.apps, .folders)], []])
    // Nel suo Dock resta dov'è.
    #expect(sectionPlaced(status, at: .into(dock: s.id, index: 0), docks: docks) == docks)
    // In un Dock vuoto entra.
    let empty = DockBox(zone: .bottom, sections: [])
    let intoEmpty = sectionPlaced(status, at: .into(dock: empty.id, index: 0), docks: docks + [empty])
    #expect(intoEmpty.first { $0.id == empty.id }?.sections == [status] && !intoEmpty.contains { $0.id == s.id })
}

// Una sezione trascinata e rilasciata lontano da ogni barra esce dal Dock, come una cartella (Review Focus 3); rilasciata
// sulla barra dove non va, o annullata (Esc, col tasto ancora giù), resta dov'era; rilasciata su un posto, ci va.
@MainActor @Test func aSectionDraggedAwayLeavesTheDock() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    let box = DockBox(zone: .middle, sections: w(.apps, .folders, .shelf))
    s.docks = [box]
    let drop = DockDrop(settings: s)
    drop.bars = { [CGRect(x: 0, y: 0, width: 52, height: 1000), CGRect(x: 1000, y: 0, width: 52, height: 1000)] }   // due schermi
    let far = CGPoint(x: 400, y: 500), onBar = CGPoint(x: 26, y: 500), otherBar = CGPoint(x: 1026, y: 500)
    drop.source = .section(.widget(.folders))
    #expect(drop.movingSection == .widget(.folders) && drop.moving == nil)
    drop.ended([], at: onBar, cancelled: false)   // sulla barra, dove non va
    #expect(s.docks == [box] && drop.source == nil)
    drop.source = .section(.widget(.folders))
    drop.ended([], at: otherBar, cancelled: false)   // sulla barra dell'altro schermo
    #expect(s.docks == [box])
    drop.source = .section(.widget(.folders))
    drop.sectionHover = SectionHover(target: .newDock(zone: .top, index: 0), display: 1)
    drop.ended([], at: far, cancelled: true)   // annullato lontano
    #expect(s.docks == [box] && drop.source == nil && drop.sectionHover == nil)
    drop.source = .section(.widget(.folders))
    drop.ended([], at: far, cancelled: false)   // rilasciato lontano: esce
    #expect(s.docks.map(\.sections) == [w(.apps, .shelf)] && drop.source == nil)
    drop.source = .section(.widget(.shelf))
    drop.dropped(at: .into(dock: box.id, index: 0))   // su un posto della barra
    drop.ended(.move, at: onBar, cancelled: false)
    #expect(s.docks.map(\.sections) == [w(.shelf, .apps)] && drop.source == nil)
    // Solo dockduo la può prendere, per spostarla.
    #expect(dockDragMask(.section(.widget(.apps)), .withinApplication) == .move && dockDragMask(.section(.widget(.apps)), .outsideApplication) == [])
}

// Dove cadrebbe la sezione trascinata, dall'altezza sulle cornici a riposo: dentro un Dock al posto fra le sue sezioni,
// fuori dai Dock un Dock nuovo nella zona di quel terzo della barra, dopo i Dock della zona sopra il puntatore.
@Test func theSectionTargetFollowsTheHeight() {
    let a = DockBox(zone: .top, sections: w(.status)), a2 = DockBox(zone: .top, sections: w(.workspaces))
    let b = DockBox(zone: .bottom, sections: w(.apps, .folders, .shelf))
    let docks: [(box: DockBox, frame: CGRect, sections: [CGRect])] = [
        (a, CGRect(x: 0, y: 10, width: 52, height: 50), [CGRect(x: 0, y: 10, width: 52, height: 50)]),
        (a2, CGRect(x: 3, y: 70, width: 45, height: 50), [CGRect(x: 10, y: 77, width: 31, height: 36)]),
        (b, CGRect(x: 3, y: 700, width: 45, height: 200), [CGRect(x: 10, y: 707, width: 31, height: 50),
                                                           CGRect(x: 10, y: 770, width: 31, height: 50),
                                                           CGRect(x: 10, y: 833, width: 31, height: 60)]),
    ]
    let zones: [Zone: CGRect] = [.top: CGRect(x: 0, y: 0, width: 52, height: 333), .middle: CGRect(x: 0, y: 333, width: 52, height: 333),
                                 .bottom: CGRect(x: 0, y: 666, width: 52, height: 333)]
    func target(_ y: CGFloat) -> SectionTarget? { sectionTarget(at: y, docks: docks, zones: zones) }
    #expect(target(795) == .into(dock: b.id, index: 1))   // a metà della seconda sezione
    #expect(target(702) == .into(dock: b.id, index: 0) && target(898) == .into(dock: b.id, index: 3))
    #expect(target(130) == .newDock(zone: .top, index: 2))   // sotto l'ultimo Dock in cima
    #expect(target(65) == .newDock(zone: .top, index: 1))    // fra i due Dock in cima
    #expect(target(5) == .newDock(zone: .top, index: 0))
    #expect(target(500) == .newDock(zone: .middle, index: 0))   // la zona di mezzo, vuota
    #expect(target(950) == .newDock(zone: .bottom, index: 1) && target(680) == .newDock(zone: .bottom, index: 0))
    #expect(target(1200) == nil)   // fuori dalla barra
    // Un Dock che non si vede (vuoto, senza cornice) non conta.
    let hidden = DockBox(zone: .top, sections: [])
    let withHidden = [docks[0], (hidden, CGRect.null, [CGRect]()), docks[1]]
    #expect(sectionTarget(at: 130, docks: withHidden, zones: zones) == .newDock(zone: .top, index: 3))
    #expect(sectionTarget(at: 65, docks: withHidden, zones: zones) == .newDock(zone: .top, index: 1))
}

// Il posto si apre dove la sezione cadrebbe davvero (lo Stato davanti al Dock, non dentro), e non dove lasciarla non cambia
// niente: da dove parte, sul suo posto, la barra resta ferma sotto il puntatore.
@MainActor @Test func theRoomOpensOnlyWhereTheSectionWouldMove() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    let status = DockBox(zone: .top, sections: w(.status)), box = DockBox(zone: .middle, sections: w(.apps, .folders, .shelf))
    s.docks = [status, box]
    let drop = DockDrop(settings: s)
    #expect(drop.room(at: .into(dock: box.id, index: 2)) == nil)   // niente in mano
    drop.source = .section(.widget(.apps))
    #expect(drop.room(at: .into(dock: box.id, index: 0)) == nil && drop.room(at: .into(dock: box.id, index: 1)) == nil)
    #expect(drop.room(at: .into(dock: box.id, index: 2)) == .into(dock: box.id, index: 2))
    #expect(drop.room(at: .newDock(zone: .bottom, index: 0)) == .newDock(zone: .bottom, index: 0))
    drop.source = .section(.widget(.status))
    #expect(drop.room(at: .into(dock: status.id, index: 0)) == nil && drop.room(at: .newDock(zone: .top, index: 1)) == nil)
    #expect(drop.room(at: .into(dock: box.id, index: 1)) == .newDock(zone: .middle, index: 0))
}

// Un trascinamento di sezione accende il velo come ogni altro (dragAround, dal battito dragTick: basta il tasto giù e la
// tavola del trascinamento cambiata da quando era su; un clic, con la tavola di prima, no) e arriva alla barra: il suo
// rilascio prende il tipo della sezione. Non è un file dal Finder: la casella della mensola vuota non compare. Col tasto su
// e fermo il battito non legge la tavola (ogni lettura è una chiamata al sistema): il numero di riposo lo prende alla risalita.
@Test func aSectionDragTurnsOnTheVeil() {
    #expect(DockDrop.sectionType.identifier == "com.dockduo.section")
    #expect(DockDrop.barTypes.contains(DockDrop.sectionType))
    #expect(DockDrop.barTypes.contains(.fileURL) && DockDrop.barTypes.contains(DockDrop.folderType))
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let drop = DockDrop(settings: Dockduo.Settings(defaults: d))
    var reads = 0
    func tick(_ pressed: Bool, _ count: Int) { drop.dragTick(pressed: pressed, count: { reads += 1; return count }, files: { true }) }
    tick(true, 1)
    tick(false, 1)   // la risalita: il numero di riposo
    reads = 0
    tick(false, 1); tick(false, 1)
    #expect(reads == 0)
    tick(true, 1)   // un clic
    #expect(!drop.dragAround)
    drop.source = .section(.widget(.apps))   // lift(section:) scrive la tavola
    tick(true, 2)
    #expect(drop.dragAround && drop.fileDrag == nil)
    drop.source = nil
    tick(false, 2)
    #expect(!drop.dragAround)
}

// Una sezione si prende (sulla barra e nella galleria) premendo e muovendo di 4 punti, una volta sola per pressione; senza
// pressione mai.
@Test func aSectionLiftsAfterFourPoints() {
    var press = LiftTracker()
    func lifts(_ x: CGFloat, _ y: CGFloat) -> Bool { press.shouldLift(at: CGPoint(x: x, y: y)) }
    #expect(!lifts(10, 10))
    press.pressedAt = CGPoint(x: 10, y: 10)
    #expect(!lifts(12, 12))   // 2,8 punti
    #expect(lifts(10, 14) && press.pressedAt == nil)
    #expect(!lifts(10, 30))
}

// Un trascinamento la cui uscita si è persa (dropExited mai arrivato) non lascia niente acceso: al battito col tasto su e
// niente in mano si spegne quello che spegne leave(). Col tasto giù, al battito della risalita (il rilascio dal Finder può
// arrivare dopo), con una voce in mano (che torna al suo posto) o mentre un rilascio dal Finder inserisce ancora le sue
// voci (il posto aperto resta finché arrivano), no.
@Test func theDragBeatClearsALostExit() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let drop = DockDrop(settings: Dockduo.Settings(defaults: d))
    func tick(_ pressed: Bool) { drop.dragTick(pressed: pressed, count: { 7 }, files: { true }) }
    let hover = DockHover(dock: UUID(), display: 1, spot: .shelf, folders: false)
    let section = SectionHover(target: .newDock(zone: .top, index: 0), display: 1)
    func lit() -> Bool { drop.hover == hover && drop.overBar != nil && drop.sectionHover == section }
    (drop.hover, drop.overBar, drop.sectionHover) = (hover, 1, section)
    tick(true)
    #expect(lit())
    tick(false)   // la risalita
    #expect(lit())
    drop.source = .folder(UUID())
    tick(false)
    #expect(lit())
    drop.source = nil
    drop.inserting = 1
    tick(false)
    #expect(lit())
    drop.inserting = 0
    tick(false)
    #expect(drop.hover == nil && drop.overBar == nil && drop.sectionHover == nil)
}

// Dove cadrebbe la sezione in mano il Dock apre il suo posto: lei e lo spazio della sua linea; senza, il Dock è com'era.
@MainActor @Test func aDockMakesRoomForTheSectionInHand() {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), editing = Editing()
    editing.begin(); defer { editing.end() }
    let box = DockBox(zone: .middle, sections: w(.apps, .folders, .shelf, .nowPlaying))
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    func height(_ room: (at: Int, height: CGFloat)?) -> CGFloat {
        NSHostingView(rootView: DockBoxView(box: box, state: BarState(), side: .left, icons: icons, settings: s, drop: DockDrop(settings: s),
                                           editing: editing, room: room).environment(\.barScale, 52.0 / 38)).fittingSize.height
    }
    let plain = height(nil), u = dockUnit * 52 / 38
    for at in [0, 2, 4] { #expect(abs(height((at, 40)) - plain - (40 + 13 * u + 2 * u)) < 0.5) }
}

// La prova a occhio (SECTION_DRAG_SHOTS=cartella): il Dock dell'autore in modifica, a sinistra fermo, a destra con Cartelle
// in mano (attenuata al suo posto) e il suo posto aperto in fondo, dopo In riproduzione.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SECTION_DRAG_SHOTS"] != nil)) func sectionDragShots() async throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SECTION_DRAG_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), editing = Editing()
    editing.begin(); defer { editing.end() }
    let box = DockBox(zone: .middle, sections: w(.apps, .folders, .shelf, .nowPlaying))
    s.docks = [box]
    let state = BarState()
    state.dock = NSWorkspace.shared.runningApplications.filter { $0.icon != nil }.prefix(3).enumerated()
        .map { AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)") }
    let still = DockDrop(settings: s), moving = DockDrop(settings: s)
    moving.source = .section(.widget(.folders))
    let scale: CGFloat = 52.0 / 38, icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    for (file, dark) in [("sezione-in-mano-scuro", true), ("sezione-in-mano-chiaro", false)] {
        let fill = dark ? Color(red: 13 / 255, green: 14 / 255, blue: 20 / 255) : Color(red: 0.93, green: 0.93, blue: 0.95)
        func dock(_ drop: DockDrop, _ room: (at: Int, height: CGFloat)?) -> some View {
            DockBoxView(box: box, state: state, side: .left, icons: icons, settings: s, drop: drop, editing: editing, room: room)
                .background { RoundedRectangle(cornerRadius: dockRadius * scale).fill(fill).offset(x: -0.5 * dockUnit * scale) }
                .environment(\.barScale, scale).modifier(SideLook()).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: 52).padding(.leading, 2).frame(width: 90, alignment: .leading)
        }
        let view = HStack(alignment: .top, spacing: 0) { dock(still, nil); dock(moving, (4, 31 * dockUnit * scale)) }.padding(16)
        let backdrop = dark ? NSColor(srgbRed: 1 / 255, green: 2 / 255, blue: 8 / 255, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)
        try await shot(view, backdrop: backdrop, to: out.appendingPathComponent("\(file).png"))
    }
}

// I tipi dei trascinamenti nostri (una cartella del Dock, una sezione) sono dichiarati nell'Info.plist: macOS non riconosce
// un tipo inventato e non dichiarato, e la barra non riceveva niente (26/10, dal vivo: dalla galleria «quando mollo sparisce»).
@Test func ourDragTypesAreDeclared() throws {
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
    let declared = (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
    #expect(Set(declared).isSuperset(of: [DockDrop.folderType.identifier, DockDrop.sectionType.identifier]))
}
