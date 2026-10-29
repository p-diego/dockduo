import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Il Dock a barra 52 ha le misure di quello di macOS (25/10, rimisurate senza la riga scura attorno al vetro): largo 45,
// alto 7 + 31 per icona + 2 fra le icone + 7; angoli 15,5.
@MainActor @Test func theDockHasTheMacOSDockMetricsAtWidth52() throws {
    _ = NSApplication.shared
    let apps = threeApps()
    try #require(apps.count == 3)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let size = dockView([.apps], apps: apps, settings: Dockduo.Settings(defaults: d)).fittingSize
    #expect(abs(size.width - 45) < 0.25 && abs(size.height - (7 + 3 * 31 + 2 * 2 + 7)) < 0.25)
    let toPoints: CGFloat = 52.0 / 38   // barScale a barra 52
    #expect(abs(dockRadius * toPoints - 15.5) < 0.01)   // gli angoli del Dock di macOS
}

// Review Focus 2: un aspetto solo, quello del Dock di macOS (spec dock-degli-agenti §5). Le scelte di Aspetto di prima (un
// tema, il margine, il carattere) restano salvate ma non si leggono più: il Dock ha la misura di fabbrica, la barra sta a 2
// dal bordo (la capsula del Dock a 5, come quella di macOS) e il chiaro o lo scuro è quello del Mac.
@MainActor @Test func theLookIsTheDefaultOne() throws {
    _ = NSApplication.shared
    let apps = threeApps()
    try #require(apps.count == 3)
    let (d, name) = fresh(), (f, other) = fresh()
    defer { d.removePersistentDomain(forName: name); f.removePersistentDomain(forName: other) }
    d.set("nord", forKey: "dockduo.barStyle"); d.set(9.0, forKey: "dockduo.edgeMargin"); d.set("rounded", forKey: "dockduo.barFont")
    let saved = Dockduo.Settings(defaults: d), factory = Dockduo.Settings(defaults: f)
    #expect(dockView([.apps], apps: apps, settings: saved).fittingSize == dockView([.apps], apps: apps, settings: factory).fittingSize)
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    func bar(_ s: Dockduo.Settings) -> CGRect { sideBarFrame(screen: screen, side: s.barSide, width: s.sideWidth, edge: barEdge, top: 33) }
    #expect(bar(saved) == bar(factory) && bar(saved).minX == 2)
    #expect(palette(dark: false) == clearLight && palette(dark: true) == nil)
    #expect(d.string(forKey: "dockduo.barStyle") == "nord" && d.double(forKey: "dockduo.edgeMargin") == 9)   // restano, non lette
}

// Da macOS 27.2 il vetro privato del Dock c'è (dockGlass): se un aggiornamento lo toglie o ne cambia la forma, il Dock
// torna al .clear e questa prova lo dice.
@Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)) func theMacOSDockGlassIsThere() {
    #expect(dockGlass != nil)
}

@Observable private final class Tiles { var count = 45 }   // le app di theDocksSettleInTheBarWithText

// Tre app vere con un'icona (l'icona viene dal pid: senza, la riga è vuota).
private func threeApps() -> [AppEntry] {
    NSWorkspace.shared.runningApplications.filter { $0.icon != nil }.prefix(3).enumerated().map {
        AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)")
    }
}

// Un Dock con quelle sezioni a barra 52, le app nello stato della barra, cartelle e mensola da `settings` (una suite sua).
@MainActor private func dockView(_ sections: [WidgetID], apps: [AppEntry] = [], settings: Dockduo.Settings, state: BarState = BarState(),
                                 hover: DockHover? = nil, drop: DockDrop = .shared, display: CGDirectDisplayID = 1,
                                 axis: BarAxis = .vertical) -> NSHostingView<some View> {
    state.dock = apps
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    let box = DockBox(zone: .middle, sections: sections.map(BarItem.widget))
    return NSHostingView(rootView: DockBoxView(box: box, state: state, side: .left, icons: icons, settings: settings, drop: drop,
                                               display: display, hover: hover)
        .environment(\.barScale, 52.0 / 38).environment(\.barAxis, axis))
}

// La linea sta fra due sezioni consecutive che mostrano qualcosa, mai in cima o in fondo (spec dock-contenitori §3): 2 + 31
// per ogni voce in più e 15 per ogni linea (6 + 1 + 6 fra i 2 attorno, misurata sul Dock di macOS). Una sezione vuota non
// si vede e non porta linee: una voce non ancora risolta o su un disco staccato non c'è. Mentre si trascina sul Dock la
// mensola vuota ha la sua casella tratteggiata, e conta come piena. Le altre sezioni sono larghe quanto l'interno del Dock.
@MainActor @Test func linesGoBetweenShownSections() throws {
    _ = NSApplication.shared
    let apps = threeApps()
    try #require(apps.count == 3)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-pill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let item = try #require(makeDockItem(dir))
    let file = dir.appendingPathComponent("nota.txt")
    try "ciao".write(to: file, atomically: true, encoding: .utf8)
    let other = try #require(makeDockItem(file))
    var unresolved = item; unresolved.url = nil
    var unmounted = unresolved; unmounted.hidden = true
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    func height(_ folders: [DockItem] = [], _ shelf: [DockItem] = [], apps: [AppEntry] = apps, dragging: Bool = false) -> CGFloat {
        s.dockFolders = folders; s.dockShelf = shelf
        // Un trascinamento sopra questa capsula, senza cartelle: niente posto aperto.
        let hover = dragging ? DockHover(dock: UUID(), display: 0, spot: .shelf, folders: false) : nil
        return dockView([.apps, .folders, .shelf], apps: apps, settings: s, hover: hover).fittingSize.height
    }
    let bare: CGFloat = 7 + 3 * 31 + 2 * 2 + 7
    #expect(abs(height([item], [other]) - (bare + 2 * (2 + 31) + 2 * 15)) < 0.5)   // anche fra cartelle e mensola
    #expect(abs(height([], [other]) - (bare + 2 + 31 + 15)) < 0.5)   // senza cartelle una linea sola
    #expect(abs(height([item]) - (bare + 2 + 31 + 15)) < 0.5)
    #expect(abs(height([item], apps: []) - (7 + 31 + 7)) < 0.25)   // senza app niente linea: starebbe in cima da sola
    #expect(abs(height() - bare) < 0.5)
    #expect(abs(height([unresolved], [unmounted]) - bare) < 0.5)
    #expect(abs(height(dragging: true) - (bare + 2 + 31 + 15)) < 0.5)   // la casella tratteggiata della mensola vuota
    #expect(abs(height([], [other], dragging: true) - (bare + 2 + 31 + 15)) < 0.5)   // mensola piena: niente casella
    // In riproduzione, una pillola di prima, dentro il Dock: larga 31 come le icone, dopo la sua linea.
    let state = BarState()
    state.track = Track(player: .music, title: "Song", artist: "Artist", playing: false)
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    let playing = NSHostingView(rootView: BarItemView(id: .widget(.nowPlaying), state: state, icons: icons)
        .environment(\.mergedPill, true).environment(\.barScale, 52.0 / 38 * inDockScale)).fittingSize
    #expect(abs(playing.width - 31) < 0.5)
    let both = dockView([.apps, .nowPlaying], apps: apps, settings: s, state: state).fittingSize
    #expect(abs(both.width - 45) < 0.25 && abs(both.height - (bare + 2 + 15 + playing.height)) < 0.5)
}

// In basso il Dock è lo stesso, steso (spec app conclusa §3.2): le caselle in fila, largo quanto di lato era alto e alto
// 45; la fascia della linea (6 + 1 + 6) sta lungo la fila, e In riproduzione è larga 31 come le icone.
@MainActor @Test func theBottomDockLiesDown() throws {
    _ = NSApplication.shared
    let apps = threeApps()
    try #require(apps.count == 3)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), state = BarState()
    state.track = Track(player: .music, title: "Song", artist: "Artist", playing: false)
    let bare: CGFloat = 7 + 3 * 31 + 2 * 2 + 7
    let alone = dockView([.apps], apps: apps, settings: s, axis: .horizontal).fittingSize
    #expect(abs(alone.width - bare) < 0.5 && abs(alone.height - 45) < 0.25)
    let both = dockView([.apps, .nowPlaying], apps: apps, settings: s, state: state, axis: .horizontal).fittingSize
    #expect(abs(both.width - (bare + 2 + 15 + 31)) < 0.5 && abs(both.height - 45) < 0.25)
}

// Review Focus 2: un Dock senza niente da mostrare non prende posto, né capsula né linee (nessuna cartella, mensola vuota,
// o un Dock appena fatto nelle Impostazioni, senza sezioni).
@MainActor @Test func aDockWithNothingToShowTakesNoRoom() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), state = BarState()
    let gone = DockItem(id: UUID(), bookmark: Data([1, 2, 3]), url: nil, hidden: false)
    s.dockFolders = [gone]; s.dockShelf = [gone]
    #expect(!barItemShows(.widget(.folders), state: state, settings: s) && !barItemShows(.widget(.shelf), state: state, settings: s))
    #expect(dockView([.folders, .shelf], settings: s, state: state).fittingSize.height == 0)
    #expect(dockView([], settings: s, state: state).fittingSize.height == 0)
    // Nella zona, fatta come in SideBarView (inBar, e la cornice registrata da dentro il Dock): il Dock vuoto fra due Dock
    // non lascia un distacco in più. Con la cornice misurata da fuori la zona era 16 più alta (99 contro 115 a barra 52).
    state.track = Track(player: .music, title: "Song", artist: "Artist", playing: false)
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    let scale: CGFloat = 52.0 / 38
    func zone(_ docks: [[WidgetID]]) -> CGFloat {
        let boxes = docks.map { DockBox(zone: .middle, sections: $0.map(BarItem.widget)) }
        return NSHostingView(rootView: VStack(spacing: 6 * scale) {
            ForEach(boxes) { DockBoxView(box: $0, state: state, side: .left, icons: icons, settings: s).inBar(grab: nil, pointer: 0, axis: .vertical) }
        }.environment(\.barScale, scale)).fittingSize.height
    }
    let one = zone([[.nowPlaying]])
    // Entro un punto: fuori da una finestra (1×) l'altezza si arrotonda al punto in su.
    #expect(one > 0 && abs(zone([[.nowPlaying], [.folders, .shelf], [], [.nowPlaying]]) - (2 * one + 6 * scale)) < 1)
}

// Il tasto destro dentro un Dock ha sempre in fondo Modifica Dock… e Impostazioni… (spec impostazioni-nel-dock §1): sull'icona
// di un'app, nel Dock o in una pillola spazio, il suo menu, sopra quello del Dock; sulla pillola spazio fuori dalle sue icone
// e sul margine della capsula, che non ne hanno uno loro, il menu con solo quelle due. Un clic sinistro non lo prende nessun
// menu: va al Dock (clic, trascinamenti, ⌘-trascina). Il Dock in una finestra mai mostrata; l'evento del
// tasto (lo legge RightClickMenuView.hitTest) si dà direttamente come quello di adesso, senza passare dalla coda degli
// eventi: prenderlo da lì (nextEvent) chiudeva il processo delle prove a metà, con le altre ancora in corso.
@MainActor @Test func everyRightClickInADockEndsInSettings() throws {
    _ = NSApplication.shared
    let apps = threeApps()
    try #require(apps.count == 3)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let state = BarState()
    state.reports = [SpaceReport(workspace: Workspace(name: "1", isFocused: false), apps: [apps[0]])]
    let host = dockView([.apps, .workspaces], apps: apps, settings: Dockduo.Settings(defaults: d), state: state)
    let size = host.fittingSize
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    defer { NSApp.setValue(nil, forKey: "currentEvent") }
    func hit(_ type: NSEvent.EventType, _ y: CGFloat) throws -> NSView? {   // y dalla cima della capsula
        let event = try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        NSApp.setValue(event, forKey: "currentEvent")
        try #require(NSApp.currentEvent?.type == type)
        let p = NSPoint(x: size.width / 2, y: host.isFlipped ? y : size.height - y)
        return host.hitTest(host.convert(p, to: host.superview))
    }
    // Le icone delle app (le tre del Dock, poi quella nella pillola spazio), dalla cima della capsula.
    func icons(_ view: NSView) -> [ClosedRange<CGFloat>] {
        let r = view.convert(view.bounds, to: host)
        let top: CGFloat = host.isFlipped ? r.minY : size.height - r.maxY
        return (view is AppMenuView ? [top...top + r.height] : []) + view.subviews.flatMap(icons)
    }
    let tiles = icons(host)
    try #require(tiles.count == 4)
    let icon: CGFloat = tiles[0].lowerBound + 10, inSpace: CGFloat = tiles[3].lowerBound + 10
    let space: CGFloat = tiles[3].lowerBound - 10   // la pillola, sul suo nome sopra l'icona
    let margin: CGFloat = 3, bottom = size.height - 3   // i margini della capsula, in cima e in fondo
    #expect(try hit(.rightMouseDown, icon) is AppMenuView && hit(.rightMouseDown, inSpace) is AppMenuView)
    for y in [space, margin, bottom] { #expect(try hit(.rightMouseDown, y) is DockMenuView) }
    #expect(DockMenuView().menu().items.map(\.title) == ["Edit Dock…", "Settings"])
    let line = tiles[2].upperBound + 2 + 6.5   // la linea dopo le app, al centro dei suoi 6 + 1 + 6: il suo menu
    #expect(try hit(.rightMouseDown, line) is DockLineMenuView)
    for y in [icon, inSpace, space, margin, bottom, line] { #expect(!(try hit(.leftMouseDown, y) is RightClickMenuView)) }
}

// Il Dock da cui trascini la sua sola cartella non sparisce (con lui sparirebbe il rilascio, e non la rimetteresti lì):
// resta col suo posto aperto. In un Dock con altro da mostrare il posto si chiude lontano dal Dock, come prima. La casella
// tratteggiata solo in un Dock con la Mensola.
@MainActor @Test func theDockStaysWhileItsOnlyFolderIsDragged() throws {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-pill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("nota.txt")
    try "ciao".write(to: file, atomically: true, encoding: .utf8)
    let item = try #require(makeDockItem(dir)), other = try #require(makeDockItem(file))
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    s.dockFolders = [item]; s.dockShelf = [other]
    let one: CGFloat = 7 + 31 + 7, drop = DockDrop(settings: s)   // non quello della barra: la tiene fuori (BarHold)
    func height(_ sections: [WidgetID], hover: DockHover? = nil) -> CGFloat {
        dockView(sections, settings: s, hover: hover, drop: drop).fittingSize.height
    }
    #expect(abs(height([.folders]) - one) < 0.25)
    // Il posto per le cartelle che arrivano si apre dove dice la barra (DockHover.spot): in fondo un passo in più, sulla
    // mensola niente.
    let end = DockHover(dock: UUID(), display: 0, spot: .folders(before: nil), folders: true)
    #expect(abs(height([.folders], hover: end) - (one + 33)) < 0.25)
    var onShelf = end; onShelf.spot = .shelf
    #expect(abs(height([.folders], hover: onShelf) - one) < 0.25)
    drop.source = .folder(item.id)
    #expect(abs(height([.folders]) - one) < 0.25)
    #expect(abs(height([.folders, .shelf]) - one) < 0.25)   // resta la mensola, senza linea
    drop.source = nil
    s.dockFolders = []; s.dockShelf = []
    let hover = DockHover(dock: UUID(), display: 0, spot: .shelf, folders: false)
    #expect(height([.folders], hover: hover) == 0 && height([.shelf], hover: hover) > 0)
}

// Un Dock con la sola Mensola o le sole Cartelle, vuote, non si vede; mentre trascini dal Finder sopra la barra (overBar)
// sì, con la casella tratteggiata della mensola o il posto aperto delle cartelle, così ci si può lasciare sopra (autore,
// 25/10). Un Dock senza Cartelle né Mensola resta com'è. Il trascinamento è quello della prova, non quello della barra.
@MainActor @Test func emptyDropDocksShowWhileAFileIsOverTheBar() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), drop = DockDrop(settings: s)
    func height(_ sections: [WidgetID]) -> CGFloat { dockView(sections, settings: s, drop: drop).fittingSize.height }
    let empty: [[WidgetID]] = [[.shelf], [.folders], [.folders, .shelf]], one: CGFloat = 7 + 31 + 7
    #expect(empty.allSatisfy { height($0) == 0 })
    drop.overBar = 1
    #expect(empty.allSatisfy { abs(height($0) - one) < 0.25 })   // una casella sola: la mensola, o il posto delle cartelle
    #expect(height([]) == 0 && height([.nowPlaying]) == 0)
    // Un Dock che si vede già resta com'è: la casella della mensola solo trascinandoci sopra (spec dock §3).
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-over-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    s.dockFolders = [try #require(makeDockItem(dir))]
    #expect(abs(height([.folders, .shelf]) - one) < 0.25)
}

// Review Focus 3: con zone più alte della barra tutti i Dock si restringono insieme, una volta sola, e poi stanno nella
// barra (il giro vero di FittedZones, fuori dallo schermo: misure, barFit, disegno dopo). Prima del 25/10 le misure fatte
// alla scala di prima, divise per quella nuova, la facevano ballare finché SwiftUI smetteva, con la barra che sbordava.
@MainActor @Test func theDocksShrinkOnceAndStayInTheBar() throws {
    _ = NSApplication.shared
    final class Seen { var scales: [CGFloat] = [] }
    let seen = Seen(), bar: CGFloat = 1000, scale: CGFloat = 52.0 / 38
    let base: [Zone: CGFloat] = [.top: 100, .middle: 1300, .bottom: 100]   // in punti a scala 1: con i distacchi 1516
    let view = FittedZones(bar: bar, scale: scale) { z, s in
        let _ = seen.scales.append(s)
        Color.clear.frame(width: 10, height: base[z]! * s / scale)
    }
    let host = NSHostingView(rootView: view.frame(width: 52, height: bar))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 52, height: bar), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    for _ in 0..<60 {   // più dei 0,3 s dell'animazione
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let natural = base.values.reduce(0, +) + 2 * 6 * scale, fit = barFit(bar: bar, natural: natural)
    let last = try #require(seen.scales.last)
    #expect(fit < 1 && abs(last - scale * fit) < 0.0001)
    #expect(Set(seen.scales.map { ($0 * 1000).rounded() }).count == 2)   // a scala piena, poi una volta sola quella giusta
    #expect(natural * last / scale <= bar)   // tutto nella barra
}

// Col testo della barra, che cresce a passi di un punto intero, vicino a un passo l'altezza a scala 1 cambia con la scala:
// i Dock si assestano lo stesso, e sempre dentro la barra; quando le app se ne vanno tornano grandi. Il giro vero di
// FittedZones, con caselle e nomi in scala come nei Dock (barra 1000: 45 e 52 app, poi 15, poi 5).
@MainActor @Test func theDocksSettleInTheBarWithText() throws {
    _ = NSApplication.shared
    final class Seen { var scales: [CGFloat] = []; var heights: [Zone: CGFloat] = [:] }
    let seen = Seen(), tiles = Tiles(), bar: CGFloat = 1000, scale: CGFloat = 52.0 / 38, u = dockUnit
    let view = FittedZones(bar: bar, scale: scale) { z, s in
        let _ = seen.scales.append(s)
        VStack(spacing: 6 * s) {
            if z == .middle {
                VStack(spacing: 2 * u * s) {
                    ForEach(0..<tiles.count, id: \.self) { _ in Color.gray.frame(width: 31 * u * s, height: 31 * u * s) }
                }
                .padding(.vertical, 7 * u * s)
            }
            VStack(spacing: 6 * s) { ForEach(0..<5, id: \.self) { Text("W\($0)").font(.system(size: 13 * s)).fixedSize() } }
                .padding(.vertical, 12 * s)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { seen.heights[z] = $0 }
    }
    let host = NSHostingView(rootView: view.frame(width: 52, height: bar))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 52, height: bar), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    func run(_ passes: Int) {
        for _ in 0..<passes { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    for count in [45, 52, 15, 5] {
        tiles.count = count
        run(50)
        let settled = try #require(seen.scales.last), from = seen.scales.count
        run(30)
        #expect(seen.scales[from...].allSatisfy { $0 == settled }, "\(count) app: la scala non si ferma")
        #expect(seen.heights.values.reduce(0, +) + 2 * 6 * settled <= bar + 0.5, "\(count) app: fuori dalla barra")
        if count == 5 { #expect(settled == scale) }   // c'è posto: di nuovo grandi
    }
}

// Il nome al passaggio del mouse a 6 dal vetro del Dock, come in macOS: a barra 52 la capsula (45, mezzo punto verso il
// bordo: da 3 a 48) sta 4 dentro il lato interno della barra, quindi il nome 2 fuori; a destra lo stesso a specchio (da 4
// a 49); in basso lo stesso, girato: il lato interno è la cima della barra (da 4 a 49 in altezza). Col Dock rimpicciolito
// la capsula sta più dentro (qui larga 26 × 52/38, al centro): il nome non entra nella barra.
@Test func theDockNameSitsSixFromTheDockGlass() {
    let left = CGRect(x: 3, y: 100, width: 45, height: 31), right = left.offsetBy(dx: 1, dy: 0)
    #expect(abs(dockNameGap(anchor: left, barWidth: 52, side: .left) - 2) < 0.001)
    #expect(abs(dockNameGap(anchor: right, barWidth: 52, side: .right) - 2) < 0.001)
    #expect(abs(dockNameGap(anchor: alongBar(right, .horizontal), barWidth: 52, side: .bottom) - 2) < 0.001)
    let narrow: CGFloat = 26 * 52 / 38, shrunk = CGRect(x: (52 - narrow) / 2, y: 100, width: narrow, height: 31)
    #expect(dockNameGap(anchor: shrunk, barWidth: 52, side: .left) == 0)
    #expect(dockNameGap(anchor: shrunk, barWidth: 52, side: .right) == 0)
    #expect(dockNameGap(anchor: alongBar(shrunk, .horizontal), barWidth: 52, side: .bottom) == 0)
}

// Trascinare la linea del Dock lo ridimensiona come in macOS: il bordo interno della capsula segue il puntatore. A barra 52
// la capsula è 45 al centro, quindi il suo bordo fa 97/104 di punto per punto di barra: 9,33 verso il centro = +10. A
// destra a specchio; verso il bordo più piccolo; a numeri interi e fra 38 e 150 (le icone grandi come nel Dock di macOS al massimo). Un Dock rimpicciolito (scala a metà) è più
// stretto della barra e il suo bordo si muove meno: lo stesso trascinamento allarga di più.
@Test func draggingTheLineResizesTheDock() {
    let scale: CGFloat = 52.0 / 38
    func drag(_ dx: CGFloat, _ side: Side, dy: CGFloat = 0, scale: CGFloat = scale) -> Double {
        lineDragWidth(start: 52, scale: scale, delta: CGSize(width: dx, height: dy), side: side)
    }
    #expect(drag(9.33, .left) == 62 && drag(-9.33, .right) == 62)
    #expect(drag(-9.33, .left) == 42 && drag(9.33, .right) == 42)
    #expect(drag(0.3, .left) == 52 && drag(0, .left, dy: 30) == 52)   // di lato su e giù non conta
    #expect(drag(1000, .left) == 150 && drag(-100, .left) == 38)
    #expect(drag(10, .left, scale: scale / 2) == 66)   // il bordo a (1 + 22,5/52)/2 per punto
}

// In basso la linea si trascina in su e in giù (spec app conclusa §3.2), sullo schermo: in su più grande, in giù più
// piccola, con gli stessi passi e limiti dei lati; di lato non conta.
@Test func theBottomResizeGoesUp() {
    let scale: CGFloat = 52.0 / 38
    func up(_ dy: CGFloat, dx: CGFloat = 0) -> Double {
        lineDragWidth(start: 52, scale: scale, delta: CGSize(width: dx, height: dy), side: .bottom)
    }
    #expect(up(9.33) == 62 && up(-9.33) == 42)
    #expect(up(20) == 73 && up(-20) == 38)
    #expect(up(1000) == 150 && up(0, dx: 50) == 52)
}

// Riduci usando è l'impostazione del Dock di macOS (com.apple.dock, mineffect): senza, il genio.
@Test func theMinimizeEffectIsTheMacOSDockOne() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    #expect(minimizeEffect(d) == "genie")
    d.set("scale", forKey: "mineffect")
    #expect(minimizeEffect(d) == "scale")
}

// Il tasto destro sulla linea del Dock: il menu della linea del Dock di macOS, senza Ingrandimento e senza In basso. Le voci
// seguono lo stato (il nascondi, il lato, l'effetto) e le prime due cambiano le impostazioni. Riduci usando
// qui non si sceglie: scriverebbe nel Dock vero e lo farebbe ripartire. In fondo Modifica Dock… e Impostazioni…, come ogni
// menu della barra.
@MainActor @Test func theDockLineMenuIsTheMacOSOne() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    let s = Dockduo.Settings(defaults: d)
    let view = DockLineMenuView(settings: s, dock: dock)   // tenuta qui: le voci la tengono debole, come target
    func shown() -> (titles: [String], hiding: NSMenuItem, sides: [NSMenuItem], effects: [NSMenuItem], last: NSMenuItem?) {
        let items = view.menu().items
        return (items.map(\.title), items[0], items[1].submenu?.items ?? [], items[2].submenu?.items ?? [], items.last)
    }
    var menu = shown()
    #expect(menu.titles == ["Turn Hiding On", "Position on Screen", "Minimize Using", "NSMenuItem", "", "Edit Dock…", "Settings"])
    #expect(menu.sides.map(\.state) == [.on, .off, .off, .off, .off])
    #expect(menu.effects.map(\.title) == ["Genie Effect", "Scale Effect"] && menu.effects.map(\.state) == [.on, .off])
    s.autohide = true; s.barSide = .right; dock.set("scale", forKey: "mineffect")
    menu = shown()
    #expect(menu.hiding.title == "Turn Hiding Off")
    #expect(menu.sides.map(\.state) == [.off, .off, .off, .off, .on] && menu.effects.map(\.state) == [.off, .on])
    func choose(_ item: NSMenuItem) { _ = (item.target as? NSObject)?.perform(item.action, with: item) }
    choose(menu.hiding)
    choose(menu.sides[0])
    #expect(!s.autohide && s.barSide == .left)
}

// Posizione sullo schermo anche senza AeroSpace (spec app conclusa §2.3): nulla nel cambio di lato ha bisogno di lui.
@MainActor @Test func positionWorksWithoutAerospace() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), state = BarState()
    state.spaceProblem = .notInstalled
    let sides = dockLineItems(settings: s, dock: nil, state: state).first { $0.title == "Position on Screen" }?.submenu?.items ?? []
    #expect(sides.map(\.title) == ["Left", "Bottom", "The macOS Dock is here", "Move the macOS Dock Right", "Right"])
    _ = (sides.last?.target as? NSObject)?.perform(sides.last?.action, with: sides.last)
    #expect(s.barSide == .right)
}

@MainActor private func positionItems(_ s: Dockduo.Settings, dock: UserDefaults?, moveDock: @escaping (Side) -> Void = { _ in }) -> [NSMenuItem] {
    dockLineItems(settings: s, dock: dock, state: BarState(), moveDock: moveDock).first { $0.title == "Position on Screen" }?.submenu?.items ?? []
}

// Posizione sullo schermo ha i tre lati nell'ordine del menu di macOS (spec app conclusa §3.1).
@MainActor @Test func positionHasThreeSidesInMacOSOrder() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    dock.set("left", forKey: "orientation")
    let s = Dockduo.Settings(defaults: d); s.barSide = .right
    let titles = positionItems(s, dock: dock).map(\.title).filter { ["Left", "Bottom", "Right"].contains($0) }
    #expect(titles == ["Left", "Bottom", "Right"])
}

// Il lato del Dock di macOS è spento, con la riga grigia e la voce che lo sposta sul primo lato libero (spec §3.4); se la barra
// è già lì, il lato resta spuntato e spento con le stesse righe. La voce dà il lato a moveDock: le prove non toccano il Dock vero.
@MainActor @Test func theMacOSDocksSideIsBlocked() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    let s = Dockduo.Settings(defaults: d)   // barra a sinistra
    var moved: [Side] = []
    var items = positionItems(s, dock: dock) { moved.append($0) }   // orientation mancante = in basso
    #expect(items.map(\.title) == ["Left", "Bottom", "The macOS Dock is here", "Move the macOS Dock Right", "Right"])
    #expect(items.map(\.isEnabled) == [true, false, false, true, true])
    _ = (items[3].target as? NSObject)?.perform(items[3].action, with: items[3])
    #expect(moved == [.right])
    dock.set("left", forKey: "orientation")
    items = positionItems(s, dock: dock) { moved.append($0) }
    #expect(items.map(\.title) == ["Left", "The macOS Dock is here", "Move the macOS Dock to the Bottom", "Bottom", "Right"])
    #expect(items[0].state == .on && !items[0].isEnabled && items[2].isEnabled)
    _ = (items[2].target as? NSObject)?.perform(items[2].action, with: items[2])
    #expect(moved == [.right, .bottom])
    #expect(freeSideForMacDock(chosen: .bottom, current: .left) == .right && freeSideForMacDock(chosen: .left, current: .left) == .bottom)
    #expect(macDockSide(dock) == .left && macDockSide(nil) == .bottom)
}

// Review Focus 3: la barra in basso e di nuovo di lato non perde nulla (Dock, larghezza, margini dell'utente di AeroSpace).
@MainActor @Test func goingToTheBottomAndBackKeepsEverything() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    let (docks, width) = (s.docks, s.sideWidth)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.toml")
    let mine = "gaps.outer.left = 5\ngaps.outer.bottom = 7\n"
    try mine.write(to: file, atomically: true, encoding: .utf8)
    func gap(_ side: Side) -> String? {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").first { $0.hasPrefix("gaps.outer.\(side.rawValue) =") }.map(String.init)
    }
    func go(_ side: Side) {
        s.barSide = side
        #expect(writeGaps(side: side, edge: 2, width: 60, autohide: false, to: file, defaults: d, reload: { _ in true }) == nil)
    }
    go(.bottom)
    #expect(gap(.bottom)?.hasPrefix("gaps.outer.bottom = 69") == true)   // 7 + 2 + 60
    go(.left)
    #expect(gap(.left)?.hasPrefix("gaps.outer.left = 67") == true && gap(.bottom)?.hasPrefix("gaps.outer.bottom = 7") == true)
    #expect(s.docks == docks && s.sideWidth == width && s.barSide == .left)
}

// L'aggiornamento in cima al menu della linea, staccato dalle altre voci (spec dock-degli-agenti §3: era in cima al menu
// delle mascotte), com'è quando il menu si apre: da scaricare, in scaricamento (grigia), fallito (il DMG); senza niente da
// offrire il menu comincia da Nascondi.
@MainActor @Test func theLineMenuOffersTheUpdateOnTop() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    let r = Release(version: "0.40", page: URL(string: "https://github.com/p-diego/dockduo/releases/tag/v0.40")!,
                    zip: URL(string: "https://github.com/p-diego/dockduo/releases/download/v0.40/dockduo-0.40.zip")!)
    var update = Updater.State.available(r)
    let view = DockLineMenuView(settings: Dockduo.Settings(defaults: d), dock: dock, update: { update })
    func top() -> [String] { view.menu().items.prefix(3).map(\.title) }
    #expect(top() == ["Update to 0.40", "", "Turn Hiding On"])
    #expect(view.menu().items[0].target === view && view.menu().items[1].isSeparatorItem)
    update = .downloading(r)
    #expect(top() == ["Downloading 0.40…", "", "Turn Hiding On"] && view.menu().items[0].action == nil)
    update = .failed("x")
    #expect(top() == ["Update failed · download the DMG", "", "Turn Hiding On"])
    update = .upToDate
    #expect(top().first == "Turn Hiding On")
}

// La prova a occhio del nome del Dock (DOCK_NAME_SHOT=cartella): a 2×, sul blu scuro della cattura dell'autore, il nome di
// App Store accanto a un Dock a barra 52, con la barra a 2 dal bordo (barEdge): da mettere accanto alla cattura vera e
// confrontare pixel per pixel. Fuori dallo schermo il vetro non si disegna: sotto al nome una capsula piena del chiaro
// misurato (+32), e il Dock un riquadro del suo colore misurato, solo per vederne i bordi.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCK_NAME_SHOT"] != nil)) func dockNameShot() throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOCK_NAME_SHOT"]!)
    let capsule = CGRect(x: 3, y: 0, width: 45, height: 45)   // un Dock di una voce, nello spazio "bar"
    let view = HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 15.5).fill(Color(red: 13 / 255, green: 14 / 255, blue: 20 / 255))
            .frame(width: capsule.width, height: capsule.height).padding(.leading, capsule.minX).frame(width: 52, alignment: .leading)
        DockNameLabel(text: "App Store").background(Capsule().fill(.white.opacity(0.128)))
            .padding(.leading, dockNameGap(anchor: capsule, barWidth: 52, side: .left))
    }
    .padding(.leading, 2).padding(.vertical, 20).frame(width: 420, alignment: .leading)
    .background(Color(red: 1 / 255, green: 2 / 255, blue: 8 / 255)).environment(\.colorScheme, .dark)
    // In una finestra mai mostrata, per la scala dello schermo: senza finestra il testo si disegna a 1× e si ingrandisce.
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    try #require(rep.pixelsWide == Int(host.bounds.width) * 2, "serve uno schermo a 2×, come la cattura")
    host.cacheDisplay(in: host.bounds, to: rep)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("dock-name.png"))
}

// La prova a occhio dei Dock (DOCK_SHOTS=cartella): a 2×, due barre di lato larghe 52 e alte quanto la cattura del Dock di
// macOS (riferimenti/macos-dock-sinistra-2x.png, 440 × 2214 pixel), da mettere accanto. Quella dell'autore dopo il passaggio
// ({"top": ["dock"]}: il Dock in cima) e una con tre Dock: in cima gli spazi, al centro app · cartelle · mensola, in fondo
// In riproduzione. Le zone dove le mette la barra (sideZoneTops). Fuori dallo schermo il vetro non si disegna: sotto ogni
// capsula un riquadro del colore misurato del Dock sul blu scuro della cattura, solo per vederne i bordi. Solo cartelle
// temporanee e /Applications: nessun file dell'autore; le impostazioni su una suite a parte.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCK_SHOTS"] != nil)) func dockBoxShots() async throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOCK_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-shots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("Progetti"), note = root.appendingPathComponent("Note.txt")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try "x".write(to: note, atomically: true, encoding: .utf8)
    s.dockFolders = [URL(fileURLWithPath: "/Applications"), projects].compactMap(makeDockItem)
    s.dockShelf = [note].compactMap(makeDockItem)
    let apps = NSWorkspace.shared.runningApplications.filter { $0.icon != nil }.prefix(12).enumerated()
        .map { AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)") }
    let state = BarState()
    state.dock = apps
    state.track = Track(player: .music, title: "Song", artist: "Artist", playing: true)
    state.reports = ["1", "2", "3", "4"].enumerated().map { i, n in
        // Nessuno a fuoco: la lente dello spazio attivo è vetro, e fuori dallo schermo il vetro svuota il Dock attorno.
        SpaceReport(workspace: Workspace(name: n, isFocused: false), apps: Array(apps.dropFirst(i).prefix(1)))
    }
    let three = [DockBox(zone: .top, sections: [.widget(.workspaces)]),
                 DockBox(zone: .middle, sections: [.widget(.apps), .widget(.folders), .widget(.shelf)]),
                 DockBox(zone: .bottom, sections: [.widget(.nowPlaying)])]
    // E i tre Dock con lo Stato acceso, nel suo Dock in cima (spec impostazioni-nel-dock §7): senza capsula sotto.
    for (file, docks) in [("dock-autore", migratedDocks(zones: ["top": ["dock"]])), ("dock-tre", three),
                          ("dock-stato", docksWithStatus(three, statusElement: true))] {
        try await barShot(docks, state: state, settings: s, to: out.appendingPathComponent("\(file).png"))
    }
}

@MainActor private func barShot(_ docks: [DockBox], state: BarState, settings: Dockduo.Settings, to url: URL) async throws {
    let height: CGFloat = 1107, scale: CGFloat = 52.0 / 38
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    func zone(_ z: Zone) -> some View {
        VStack(spacing: 6 * scale) {
            ForEach(docks.filter { $0.zone == z }) { box in
                DockBoxView(box: box, state: state, side: .left, icons: icons, settings: settings)
                    .background { if !box.isStatus { RoundedRectangle(cornerRadius: dockRadius * scale).fill(Color(red: 13 / 255, green: 14 / 255, blue: 20 / 255)).offset(x: -0.5 * dockUnit * scale) } }
            }
        }
        .environment(\.barScale, scale).modifier(SideLook()).environment(\.colorScheme, .dark)
    }
    let h = Zone.allCases.map { NSHostingView(rootView: zone($0)).fittingSize.height }
    let tops = sideZoneTops(bar: height, top: h[0], middle: h[1], bottom: h[2], gap: 6 * scale)
    let bar = ZStack(alignment: .top) { zone(.top); zone(.middle).offset(y: tops.middle); zone(.bottom).offset(y: tops.bottom) }
        .frame(width: 52, height: height, alignment: .top)
        .padding(.leading, 2).frame(width: 220, height: height, alignment: .leading)   // a 2 dal bordo, come la barra (barEdge)
    // In una finestra mai mostrata, per la scala dello schermo (2×, come la cattura).
    let host = NSHostingView(rootView: bar)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .seconds(0.5))   // le icone di cartelle e file arrivano da fuori dal main
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    try #require(rep.pixelsWide == Int(host.bounds.width) * 2, "serve uno schermo a 2×, come la cattura")
    host.cacheDisplay(in: host.bounds, to: rep)
    // Il blu scuro della cattura sotto, a mano: lo sfondo della vista più esterna qui non si disegna (resta trasparente).
    let flat = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
    let all = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    NSColor(srgbRed: 1 / 255, green: 2 / 255, blue: 8 / 255, alpha: 1).setFill()
    all.fill()
    rep.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try #require(flat.representation(using: .png, properties: [:])).write(to: url)
}

// I Dock vuoti compaiono solo sullo schermo dove sta il trascinamento dal Finder (A = 1), non sulle barre degli altri (B = 2);
// spostando il puntatore sull'altro schermo si scambiano.
@MainActor @Test func emptyDocksShowOnlyOnThePointersScreen() {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), drop = DockDrop(settings: s)
    func height(_ display: CGDirectDisplayID) -> CGFloat { dockView([.shelf], settings: s, drop: drop, display: display).fittingSize.height }
    func drag(on display: CGDirectDisplayID) { drop.dragTick(pressed: true, count: { 9 }, files: { true }, screen: { display }) }
    drop.dragTick(pressed: false, count: { 1 }, files: { true }, screen: { 1 })   // il numero di riposo
    drag(on: 1)
    #expect(height(1) > 0 && height(2) == 0)
    drag(on: 2)
    #expect(height(1) == 0 && height(2) > 0)
}
