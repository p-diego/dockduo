import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Il Dock in modifica (spec impostazioni-nel-dock §1, §2, §4). Le prove che accendono la modifica condivisa
// (Editing.shared) sono sincrone sul main: nessun'altra prova la vede accesa. Quelle che disegnano il Dock ne danno uno loro.

private func w(_ ids: WidgetID...) -> [BarItem] { ids.map(BarItem.widget) }

// Le righe di un menu: "|" per una riga di separazione, se no il titolo.
@MainActor private func lines(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "|" : $0.title } }

@MainActor private func choose(_ item: NSMenuItem?) { _ = (item?.target as? NSObject)?.perform(item?.action, with: item) }

// Tre app vere con un'icona (l'icona viene dal pid: senza, la riga è vuota).
private func threeApps() -> [AppEntry] {
    NSWorkspace.shared.runningApplications.filter { $0.icon != nil }.prefix(3).enumerated().map {
        AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)")
    }
}

// Il Dock dell'autore: App aperte, Cartelle, Mensola, In riproduzione; nessuna cartella, mensola vuota, niente in riproduzione.
private func authorDock(_ s: Dockduo.Settings) {
    s.docks = [DockBox(zone: .middle, sections: w(.apps, .folders, .shelf, .nowPlaying))]
}

// Una vista a barra 52 in una finestra mai mostrata (per la scala dello schermo e per gli hitTest).
@MainActor private func inWindow(_ view: some View) -> (NSView, NSWindow) {
    let host = NSHostingView(rootView: view.environment(\.barScale, 52.0 / 38))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return (host, window)
}

// Un Dock così, in una finestra mai mostrata.
@MainActor private func hosted(_ box: DockBox, state: BarState, settings: Dockduo.Settings, editing: Editing) -> (NSView, NSWindow) {
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    return inWindow(DockBoxView(box: box, state: state, side: .left, icons: icons, settings: settings, editing: editing))
}

// Chi prende un clic di quel tipo, col ⌘ o senza, nel punto `p` della vista dall'alto. L'evento (lo legge hitTest) si dà
// direttamente come quello di adesso, come in everyRightClickInADockEndsInSettings; chi chiama lo azzera alla fine.
@MainActor private func hit(_ host: NSView, _ window: NSWindow, _ type: NSEvent.EventType, _ p: CGPoint,
                            command: Bool = false) throws -> NSView? {
    let event = try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: command ? .command : [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    NSApp.setValue(event, forKey: "currentEvent")
    let at = NSPoint(x: p.x, y: host.isFlipped ? p.y : host.bounds.height - p.y)
    return host.hitTest(host.convert(at, to: host.superview))
}

private final class EditPanel: NSPanel, EditWindow {}   // come la galleria (Task 4)

// Le viste dei clic delle sezioni (SectionMenuView) dentro una vista, con la loro cornice nella vista dall'alto.
@MainActor private func sectionViews(_ view: NSView, in host: NSView) -> [(view: SectionMenuView, frame: CGRect)] {
    let mine: [(view: SectionMenuView, frame: CGRect)] = (view as? SectionMenuView).map { v in
        let r = v.convert(v.bounds, to: host)
        return [(v, CGRect(x: r.minX, y: host.isFlipped ? r.minY : host.bounds.height - r.maxY, width: r.width, height: r.height))]
    } ?? []
    return mine + view.subviews.flatMap { sectionViews($0, in: host) }
}

// Review Focus 1: il Dock dell'autore in modifica. Fuori dalla modifica Cartelle, Mensola e In riproduzione vuote non si
// vedono; in modifica si vedono tutte e quattro, ognuna col suo bordo, il suo "−" e il suo menu (la sua vista dei clic);
// uscendo tornano invisibili e il Dock è quello di prima.
@MainActor @Test func emptySectionsShowOnlyWhileEditing() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    let state = BarState()
    state.dock = threeApps()
    try #require(!state.dock.isEmpty)
    func shown() -> [Bool] { s.docks[0].sections.map { barItemShows($0, state: state, settings: s) } }
    #expect(shown() == [true, false, false, false])
    Editing.shared.begin()
    #expect(shown() == [true, true, true, true])
    Editing.shared.end()
    #expect(shown() == [true, false, false, false])

    // Disegnato: in modifica quattro blocchi, ognuno con la sua vista dei clic; fuori nessuna, e il Dock alto come le sole app.
    let off = Editing(), on = Editing()
    on.begin(); defer { on.end() }
    let (resting, w1) = hosted(s.docks[0], state: state, settings: s, editing: off)
    let (editing, w2) = hosted(s.docks[0], state: state, settings: s, editing: on)
    let apps = hosted(DockBox(zone: .middle, sections: w(.apps)), state: state, settings: s, editing: off)
    #expect(sectionViews(resting, in: resting).isEmpty && sectionViews(editing, in: editing).map(\.view.item) == s.docks[0].sections)
    #expect(resting.fittingSize == apps.0.fittingSize && editing.fittingSize.height > resting.fittingSize.height)
    withExtendedLifetime([w1, w2, apps.1]) {}
}

// Review Focus 4: si esce in tutti i modi e i monitor se ne vanno con la modifica. Entrare due volte li mette una volta,
// uscire due volte non fa niente. Esc chiude solo in una finestra della modifica (la barra, la galleria), non nel "Scegli…"
// dello Stato, dove annulla il pannello, né in un'altra finestra nostra. Un clic chiude solo fuori da dockduo (in un'altra
// app, sulla scrivania), sinistro o destro, mai in una finestra nostra. Da fuori arrivano solo i clic: niente monitor
// globale dei tasti, che chiederebbe il permesso di Monitoraggio dell'input. I monitor sono due: quello di dentro (Esc e
// clic) e quello di fuori.
@MainActor @Test func editingEndsEverywhere() {
    _ = NSApplication.shared
    let e = Editing.shared
    e.begin(on: 7)
    #expect(e.on && e.display == 7 && e.monitorsInstalled == 2)
    e.begin()
    #expect(e.monitorsInstalled == 2 && e.display == 7)
    e.end()
    #expect(!e.on && e.display == nil && e.monitorsInstalled == 0)
    e.end()
    #expect(!e.on && e.monitorsInstalled == 0)

    let edit = EditPanel(), panel = NSPanel(), window = NSWindow()
    #expect(endsEditing(key: 53, local: true, window: edit) && !endsEditing(key: 0, local: true, window: edit))
    #expect(!endsEditing(key: 53, local: true, window: panel) && !endsEditing(key: 53, local: true, window: window))
    #expect(endsEditing(key: nil, local: false, window: nil))   // un clic in un'altra app o sulla scrivania
    #expect(Editing.outsideClicks == [.leftMouseDown, .rightMouseDown])   // anche il tasto destro
    for w in [edit, panel, window] as [NSWindow] { #expect(!endsEditing(key: nil, local: true, window: w)) }   // in una nostra
}

// Ogni menu della barra finisce con Modifica Dock… sopra Impostazioni… (spec §1): app, cartella, file della mensola e
// linea del Dock, staccati dalle loro voci; quello del vetro del Dock non ha altro, quindi niente riga in cima.
// Modifica Dock… accende la modifica.
@MainActor @Test func everyBarMenuEndsWithEditDock() {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    let s = Dockduo.Settings(defaults: d)
    let url = URL(fileURLWithPath: "/tmp/dockduo-nota.txt")
    // Tenute qui: le voci tengono il loro bersaglio debole.
    let views: [RightClickMenuView] = [AppMenuView(app: AppEntry(name: "Notes", pid: 9, windowID: 3, bundle: "com.notes"), state: BarState()),
                                       DockItemMenuView(id: UUID(), url: url, folder: true, settings: s),
                                       DockItemMenuView(id: UUID(), url: url, folder: false, settings: s),
                                       DockLineMenuView(settings: s, dock: dock, update: { .idle })]
    for view in views { #expect(lines(view.menu()).suffix(3) == ["|", "Edit Dock…", "Settings"]) }
    let glass = DockMenuView().menu()
    #expect(lines(glass) == ["Edit Dock…", "Settings"])
    choose(glass.items.first)
    #expect(Editing.shared.on)
    Editing.shared.end()
}

// §4: un clic su una sezione in modifica apre le sue opzioni, quelle della sua schermata di prima, e in fondo Togli dal Dock.
// Le spunte dicono le impostazioni e le cambiano; lo Stato ha "Il click apre" (l'app di adesso, Scegli…, Nessuna) e
// "Mostra il nome della rete…" solo senza la Posizione.
@MainActor @Test func eachSectionHasItsOptions() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    func menu(_ id: WidgetID, noLocation: Bool = false) -> NSMenu { sectionMenu(.widget(id), settings: s, noLocation: noLocation) }
    for id in [WidgetID.apps, .folders, .shelf] {
        #expect(lines(menu(id)) == ["Show names on hover", "|", "Remove from Dock"] && menu(id).items[0].state == .off)
    }
    choose(menu(.folders).items[0])
    #expect(s.dockHoverNames && menu(.apps).items[0].state == .on)
    #expect(lines(menu(.workspaces)) == ["Front app name on the active workspace", "|", "Remove from Dock"])
    #expect(menu(.workspaces).items[0].state == .on)
    choose(menu(.workspaces).items[0])
    #expect(!s.showFrontAppName)
    #expect(lines(menu(.nowPlaying)) == ["Large artwork in the menu", "|", "Remove from Dock"] && menu(.nowPlaying).items[0].state == .on)
    choose(menu(.nowPlaying).items[0])
    #expect(!s.bigArtwork)

    #expect(lines(menu(.status)) == ["Click opens", "|", "Remove from Dock"])
    #expect(lines(menu(.status, noLocation: true)) == ["Click opens", "Show network name…", "|", "Remove from Dock"])
    s.clockApp = "com.apple.finder"   // c'è su ogni Mac
    var opens = menu(.status).items[0].submenu
    #expect(opens.map(lines)?.suffix(2) == ["Choose…", "None"] && opens?.items.count == 3)
    #expect(opens?.items.map(\.state) == [.on, .off, .off] && opens?.items[0].title == appName(bundle: "com.apple.finder"))
    choose(opens?.items.last)
    #expect(s.clockApp.isEmpty)
    opens = menu(.status).items[0].submenu
    #expect(opens.map(lines) == ["Choose…", "None"] && opens?.items.map(\.state) == [.off, .on])
}

// Le finestre aperte in modifica non finiscono dietro la galleria (sta sopra le finestre): lo "Scegli…" dello Stato tiene la
// modifica e va un gradino sopra la galleria; Configurazione iniziale… e Informazioni su dockduo la chiudono prima.
@MainActor @Test func windowsOpenedWhileEditingStayInFront() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let editing = Editing()
    let gallery = GalleryPanel(editing: editing, state: BarState(), settings: Dockduo.Settings(defaults: d))
    editing.gallery = gallery
    editing.begin()
    let panel = NSPanel()
    editing.opensWindow(keepingEditing: panel)
    #expect(editing.on && panel.level.rawValue == gallery.level.rawValue + 1)
    editing.opensWindow()
    #expect(!editing.on && editing.monitorsInstalled == 0 && gallery.alphaValue == 0)
}

// Il "−" e Togli dal Dock tolgono la sezione: il Dock tiene le altre; tolta l'ultima, il Dock sparisce (la regola dei Dock).
@MainActor @Test func removingASectionKeepsTheRestOfTheDock() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    s.docks.append(DockBox(zone: .bottom, sections: w(.workspaces)))
    choose(sectionMenu(.widget(.folders), settings: s, noLocation: false).items.last)
    #expect(s.docks.map(\.sections) == [w(.apps, .shelf, .nowPlaying), w(.workspaces)])
    s.removeSection(.widget(.workspaces))
    #expect(s.docks.map(\.sections) == [w(.apps, .shelf, .nowPlaying)])
}

// macOS manda i clic dei punti trasparenti a chi c'è sotto: in modifica la barra ha il velo (SideBarView). Dentro la barra,
// un clic (sinistro o destro) su una sezione va alla sua vista dei clic, sopra le app, le cartelle e la casella vuota, che
// così non si aprono; sul "−", che sporge dal bordo, va al "−"; col ⌘ al ⌘-trascina della barra. Lo Stato, quasi tutto
// trasparente, uguale.
@MainActor @Test func clicksInEditModeReachTheSection() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    let state = BarState()
    state.dock = threeApps()
    try #require(state.dock.count == 3)
    let editing = Editing()
    editing.begin(); defer { editing.end() }
    defer { NSApp.setValue(nil, forKey: "currentEvent") }
    let (host, window) = hosted(s.docks[0], state: state, settings: s, editing: editing)
    let blocks = sectionViews(host, in: host)
    try #require(blocks.count == 4)
    for (view, frame) in blocks {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        #expect(try hit(host, window, .leftMouseDown, middle) === view && hit(host, window, .rightMouseDown, middle) === view)
        #expect(try !(hit(host, window, .leftMouseDown, middle, command: true) is RightClickMenuView))
        let badge = try hit(host, window, .leftMouseDown, CGPoint(x: frame.minX + 3, y: frame.minY + 3))
        #expect(badge != nil && !(badge is RightClickMenuView))
    }
    let (stato, statoWindow) = hosted(DockBox(zone: .top, sections: w(.status)), state: state, settings: s, editing: editing)
    let ring = try #require(sectionViews(stato, in: stato).first)
    let inRing = CGPoint(x: ring.frame.midX, y: ring.frame.maxY - 8), onTime = CGPoint(x: ring.frame.midX, y: ring.frame.minY + 8)
    #expect(try hit(stato, statoWindow, .leftMouseDown, inRing) === ring.view)
    // Col ⌘ il clic passa oltre lo Stato, anche il destro: non lo prende il suo menu (né l'ora, che aprirebbe il Calendario).
    #expect(try !(hit(stato, statoWindow, .rightMouseDown, onTime, command: true) is RightClickMenuView))
    withExtendedLifetime([window, statoWindow]) {}
}

// In modifica un clic non apre e non alterna niente, col ⌘ o senza (un'app, un file, uno spazio, l'ora dello Stato, In
// riproduzione): il contenuto della sezione non prende clic. Senza ⌘ va alla vista dei clic della sezione (il suo menu); col
// ⌘ passa oltre la sezione, alla barra sotto, che col ⌘ trascina i Dock. Il tocco di SwiftUI non si vede da un hitTest (la
// vista di SwiftUI risponde per tutti i suoi punti); lo si vede da una vista AppKit dentro il contenuto, che segue la stessa
// regola: qui un menu al tasto destro, come quelli delle app e dello Stato. Fuori dalla modifica il clic è suo, ⌘ o no.
@MainActor @Test func aClickInEditModeNeverReachesTheSection() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    defer { NSApp.setValue(nil, forKey: "currentEvent") }
    final class Inside: RightClickMenuView {}
    func tile(editing: Bool) -> (NSView, NSWindow) {
        inWindow(Color.red.frame(width: 31, height: 31).overlay(MenuAnchor { Inside() })
            .modifier(EditFrame(item: .widget(.nowPlaying), on: editing, settings: s)).padding(10))
    }
    let middle = CGPoint(x: 25.5, y: 25.5)
    let (on, onWindow) = tile(editing: true), (off, offWindow) = tile(editing: false)
    for command in [false, true] {
        #expect(try hit(off, offWindow, .rightMouseDown, middle, command: command) is Inside)
        let taken = try hit(on, onWindow, .rightMouseDown, middle, command: command)
        #expect(command ? !(taken is RightClickMenuView) : taken is SectionMenuView)
    }
    withExtendedLifetime([onWindow, offWindow]) {}
}

// La barra non resta mai senza niente da cliccare (spec §2, autore 27/10: «Resta una capsula vuota»): fuori dalla modifica,
// se nessuna sezione di nessun Dock si vede (nessun Dock, o solo sezioni vuote), al centro la capsula vuota del Dock. Le
// app che si vedono la tolgono, e anche lo Stato acceso; in modifica non c'è (si vedono le sezioni vuote). All'avvio aspetta
// che la barra abbia letto (il primo giro del Poller, i segnalibri di cartelle e mensola): non compare e scompare mentre le
// sezioni arrivano. Trascinando un file, i Dock con Cartelle o Mensola mostrano dove lasciarlo e lei lascia il posto a loro.
// Un clic entra in modifica sullo schermo della sua barra.
@MainActor @Test func anEmptyBarKeepsACapsuleToClick() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    s.docks[0].sections.removeFirst()   // tolte le App aperte: Cartelle, Mensola e In riproduzione, tutte vuote
    let state = BarState(), drop = DockDrop(settings: s), editing = Editing()
    func shows() -> Bool { emptyBarCapsuleShows(docks: s.docks, state: state, settings: s, drop: drop, display: 1, editing: editing) }
    #expect(!shows())   // la barra non ha ancora letto
    state.trackRead = true   // In riproduzione ha già letto: lettore fermo, nessun brano
    state.reports = [SpaceReport(workspace: Workspace(name: "1", isFocused: true), apps: [])]
    #expect(shows())
    s.docks = []
    #expect(shows())
    authorDock(s)
    #expect(shows())   // le App aperte, ma ancora nessuna app
    state.dock = [AppEntry(name: "Finder", pid: 1, windowID: 0, bundle: "com.apple.finder")]
    #expect(!shows())
    state.dock = []
    s.docks.append(DockBox(zone: .top, sections: w(.status)))
    #expect(!shows())   // lo Stato si vede sempre
    s.docks.removeLast()
    editing.begin(); defer { editing.end() }
    #expect(!shows())
    editing.end()
    s.dockFolders = [DockItem(id: UUID(), bookmark: Data([1]), url: nil, hidden: false)]   // un segnalibro non ancora risolto
    #expect(!shows())
    s.dockFolders[0].hidden = true   // risolto, non si raggiunge (disco staccato, rete muta): non si vede
    #expect(shows())
    drop.overBar = 1   // un file dal Finder sopra la barra: il Dock con Cartelle e Mensola mostra dove lasciarlo
    #expect(!shows())
    s.docks = [DockBox(zone: .middle, sections: w(.nowPlaying))]   // nessun Dock che lo prende: la capsula resta
    #expect(shows())

    // Il tasto destro è il menu del vetro del Dock; il sinistro arriva al suo tocco (nessun menu lo prende), che entra in modifica.
    let capsule = EmptyBarCapsule(display: 3, side: .left, editing: editing)
    let (host, window) = inWindow(capsule)
    defer { NSApp.setValue(nil, forKey: "currentEvent") }
    let middle = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
    #expect(try hit(host, window, .rightMouseDown, middle) is DockMenuView && !(hit(host, window, .leftMouseDown, middle) is RightClickMenuView))
    capsule.click()
    #expect(editing.on && editing.display == 3)
    withExtendedLifetime(window) {}
}

// La prova a occhio del Dock in modifica (EDIT_SHOTS=cartella), in scuro e in chiaro: a 2×, la stessa barra larga 52 fuori e
// dentro la modifica, una accanto all'altra. Il Dock dell'autore (cinque app aperte; Cartelle, Mensola e In riproduzione
// vuote) e lo Stato in cima. Fuori dallo schermo il vetro non si disegna: sotto ogni capsula un riquadro del colore del Dock,
// come in dockBoxShots, solo per vederne i bordi. Le impostazioni su una suite a parte, la modifica è una sua.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["EDIT_SHOTS"] != nil)) func editShots() async throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EDIT_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    s.docks = docksWithStatus([DockBox(zone: .middle, sections: w(.apps, .folders, .shelf, .nowPlaying))], statusElement: true)
    let state = BarState()
    state.dock = NSWorkspace.shared.runningApplications.filter { $0.icon != nil }.prefix(5).enumerated()
        .map { AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)") }
    (state.battery, state.wifi) = (Battery(percent: 74, charging: false), WiFi(on: true, bars: 2, vpn: false))
    let off = Editing(), on = Editing()
    on.begin(); defer { on.end() }
    let scale: CGFloat = 52.0 / 38, height: CGFloat = 760
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    func zone(_ z: Zone, _ editing: Editing, dark: Bool) -> some View {
        let fill = dark ? Color(red: 13 / 255, green: 14 / 255, blue: 20 / 255) : Color(red: 0.93, green: 0.93, blue: 0.95)
        let glass = RoundedRectangle(cornerRadius: dockRadius * scale).fill(fill).offset(x: -0.5 * dockUnit * scale)
        return VStack(spacing: 6 * scale) {
            ForEach(s.docks(in: z)) { box in
                DockBoxView(box: box, state: state, side: .left, icons: icons, settings: s, editing: editing)
                    .background { if !box.isStatus { glass } }
            }
            if z == .middle, emptyBarCapsuleShows(docks: s.docks, state: state, settings: s, drop: DockDrop(settings: s), display: 1, editing: editing) {
                EmptyBarCapsule(display: nil, side: .left, editing: editing).background { glass }
            }
            if z == .bottom, editing.on { EditDoneButton() }
        }
        .environment(\.barScale, scale).modifier(SideLook()).environment(\.colorScheme, dark ? .dark : .light)
    }
    func bar(_ editing: Editing, dark: Bool) -> some View {
        let h = Zone.allCases.map { NSHostingView(rootView: zone($0, editing, dark: dark)).fittingSize.height }
        let tops = sideZoneTops(bar: height, top: h[0], middle: h[1], bottom: h[2], gap: 6 * scale)
        return ZStack(alignment: .top) {
            zone(.top, editing, dark: dark); zone(.middle, editing, dark: dark).offset(y: tops.middle)
            zone(.bottom, editing, dark: dark).offset(y: tops.bottom)
        }
            .frame(width: 52, height: height, alignment: .top)
            .padding(.leading, 2).frame(width: 140, alignment: .leading)   // a 2 dal bordo, come la barra (barEdge)
    }
    func backdrop(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1 / 255, green: 2 / 255, blue: 8 / 255, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)
    }
    for (file, dark) in [("modifica-scuro", true), ("modifica-chiaro", false)] {
        try await shot(HStack(spacing: 0) { bar(off, dark: dark); bar(on, dark: dark) }, backdrop: backdrop(dark),
                       to: out.appendingPathComponent("\(file).png"))
    }
    // La barra vuota (autore, 27/10): tolte le App aperte, con Cartelle, Mensola e In riproduzione vuote resta la capsula.
    // Fuori dalla modifica e in modifica, dove si vedono le sezioni vuote.
    state.reports = [SpaceReport(workspace: Workspace(name: "1", isFocused: true), apps: [])]
    s.docks = [DockBox(zone: .middle, sections: w(.folders, .shelf, .nowPlaying))]
    for (file, dark) in [("capsula-vuota", true), ("capsula-vuota-chiaro", false)] {
        try await shot(HStack(spacing: 0) { bar(off, dark: dark); bar(on, dark: dark) }, backdrop: backdrop(dark),
                       to: out.appendingPathComponent("\(file).png"))
    }
}

// All'avvio In riproduzione si legge con AppleScript e arriva dopo: finché non è tornata la lettura la capsula vuota non
// compare (poi sparirebbe con la nota); tornata e senza brano (lettore fermo), c'è.
@MainActor @Test func theEmptyCapsuleWaitsForNowPlaying() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d), state = BarState(), drop = DockDrop(settings: s)
    s.docks = [DockBox(zone: .middle, sections: w(.nowPlaying))]
    state.reports = [SpaceReport(workspace: Workspace(name: "1", isFocused: true), apps: [])]
    func shows() -> Bool { emptyBarCapsuleShows(docks: s.docks, state: state, settings: s, drop: drop, display: 1, editing: Editing()) }
    #expect(!shows())
    state.trackRead = true
    #expect(shows())
}
