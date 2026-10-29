import SwiftUI

// Il Dock (spec dock-contenitori §1-3): la capsula del Dock di macOS con dentro le sue sezioni, nell'ordine scelto, e la
// linea fra due sezioni consecutive che mostrano qualcosa, mai in cima o in fondo. Una sezione vuota non si vede e non
// porta linee; un Dock senza niente da mostrare non prende posto. Quando la barra non li tiene, SideBarView rimpicciolisce
// tutti i Dock insieme (barFit): basta dare loro una scala più piccola.
// App aperte, cartelle e mensola sono le caselle del Dock di macOS (24-25/10). Le app: quelle che hanno un'icona nel Dock
// di macOS, una per app e in ordine di apertura (dockApps), con le icone grandi e senza nomi; attenuate quelle senza
// finestre a schermo, come tra le nascoste; click = l'app davanti (showApp), click destro = il suo menu (AppIconView). Il
// numero rosso nell'angolo è quello che l'app mette sulla sua icona nel Dock (Badges.swift). Cartelle e mensola: solo le
// voci risolte e su un disco montato. Le altre sezioni sono le pillole di prima, senza il loro sfondo (\.mergedPill),
// larghe quanto l'interno del Dock (inDockScale) e alte almeno quanto una sua casella (Pill).
// Trascinare sul Dock e dal Dock: DockDrop.swift; il rilascio è della barra, a cui la capsula dà le cornici delle sue voci
// e da cui riceve il trascinamento sopra di lei (hover), con dove cadrebbe: lì apre il posto. Il Dock dello Stato non ha
// capsula: è l'elemento libero sullo sfondo, come l'iPhone Duo (spec impostazioni-nel-dock, decisione 5).
// In modifica (Editing, spec impostazioni-nel-dock §2) ogni sezione è un blocco col suo bordo e il suo "−" (EditFrame), anche
// vuota (EmptySectionBox), e al posto delle linee resta il loro spazio. Una sezione trascinata (DockDrop.movingSection)
// resta al suo posto attenuata finché non la lasci; dove cadrebbe in questo Dock si apre il suo posto (`room`).
struct DockBoxView: View {
    let box: DockBox
    let state: BarState
    let mirrored: Bool   // barra a destra: il bordo dello schermo è a destra
    let icons: IconDragHooks
    // Dove stanno la capsula e le sue cartelle e i suoi file nello spazio "bar" (il ⌘-trascina e i rilasci, SideBarView).
    // Da qui dentro: una vista che la misura da fuori darebbe al Dock vuoto un posto alto zero, e la zona gli darebbe il
    // distacco.
    var onFrame: (CGRect) -> Void = { _ in }
    var onTile: (UUID, CGRect) -> Void = { _, _ in }
    var onSection: (BarItem, CGRect) -> Void = { _, _ in }   // le sezioni, per il rilascio di una sezione (sectionTarget)
    var settings = Settings.shared   // cartelle e mensola (le prove ne danno uno loro)
    @Environment(\.barScale) private var scale
    var drop = DockDrop.shared   // il trascinamento della barra (le prove ne danno uno loro)
    var display: CGDirectDisplayID = 0   // lo schermo della sua barra: i Dock vuoti compaiono solo dove sta il trascinamento
    var hover: DockHover?   // un trascinamento sopra questa capsula (DockDrop.hover; le prove lo danno da qui)
    var editing = Editing.shared   // la modifica (le prove ne danno una loro)
    // La sezione in mano cadrebbe qui: davanti alla sezione `at` (oltre la fine = in fondo), alta `height` (SideBarView).
    var room: (at: Int, height: CGFloat)?

    var body: some View {
        if box.isStatus {
            // In modifica col margine di una capsula (7): il bordo e il "−" ci stanno anche in cima alla barra.
            StatusElement(state: state, mirrored: mirrored)
                .modifier(EditFrame(item: .widget(.status), on: editing.on, settings: settings,
                                    shift: (mirrored ? 0.5 : -0.5) * dockUnit * scale))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { onSection(.widget(.status), $0) }
                .opacity(drop.movingSection == .widget(.status) ? lifted : 1)
                .foregroundStyle(.white)   // il bordo sullo sfondo, bianco come lo Stato
                .padding(.vertical, editing.on ? 7 * dockUnit * scale : 0)
                .animation(.smooth(duration: 0.3), value: editing.on)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { onFrame($0) }
                .transition(.blurReplace)
        } else {
            capsule
        }
    }

    @ViewBuilder private var capsule: some View {
        // La cartella che stai trascinando lascia il suo posto (si apre dove cadrebbe; fuori dal Dock si chiude).
        let folders = settings.dockFolders.filter { $0.shown && $0.id != drop.moving }, shelf = settings.dockShelf.filter(\.shown)
        // La casella della mensola vuota sopra questa capsula (spec dock §3) e, mentre trascini dal Finder sopra la barra
        // (overBar), anche lontano da lei, ma solo in un Dock che altrimenti non si vedrebbe: così un Dock con la sola
        // Mensola vuota compare e ci si può lasciare sopra (autore, 25/10: «Appare trascinando»), e gli altri restano come
        // sono. Lontano dalla barra no. Il posto che si apre per una cartella fa vedere le cartelle anche senza
        // (dock-contenitori §3: conta come piena).
        let hidden = !box.sections.contains(where: shows)
        let emptyShelf = (hover != nil || drop.fileDrag == display || drop.overBar == display && hidden) && shelf.isEmpty
        // Se la cartella che trascini era tutto quello che il suo Dock mostrava, il suo posto resta aperto anche lontano:
        // il Dock non sparisce, e con lui il rilascio, e la puoi rimettere lì. Così, dal Finder sopra la barra, anche le
        // Cartelle vuote di un Dock senza Mensola.
        let alone = drop.moving != nil && box.hasFolders && hidden
        let open = alone || (drop.overBar == display || drop.fileDrag == display) && hidden && box.hasFolders && !box.hasShelf && folders.isEmpty
        let gap = hover.flatMap(gapBefore) ?? (open ? foldersEnd : nil)
        // Le sezioni che si vedono, e se il Dock si vede: la regola è questa sola (la barra non ne ha un'altra). In modifica
        // tutte: quella senza niente da mostrare è la sua casella vuota.
        let full = { (item: BarItem) in
            barItemHasContent(item, state: state, settings: settings, drop: drop) || item == .widget(.folders) && gap == foldersEnd
                || item == .widget(.shelf) && emptyShelf
        }
        let shown = box.sections.filter { editing.on || full($0) }
        if !shown.isEmpty {
            BarStack(spacing: 2 * dockUnit) {
                ForEach(shown, id: \.self) { item in
                    if let room, room.at == shown.firstIndex(of: item) { roomSpace(room.height) }
                    if item != shown.first {
                        if editing.on { Color.clear.frame(height: dockLine * scale) }   // il posto della linea
                        else { DockSeparator(settings: settings).transition(.opacity) }
                    }
                    Group {
                        if full(item) {
                            section(item, folders: folders, shelf: shelf, gap: gap, emptyShelf: emptyShelf)
                        } else {
                            switch item { case .widget(let w): EmptySectionBox(id: w) }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { onSection(item, $0) }
                    .modifier(EditFrame(item: item, on: editing.on, empty: !full(item), settings: settings))
                    .opacity(item == drop.movingSection ? lifted : 1)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                if let room, room.at >= shown.count { roomSpace(room.height) }
            }
            .pill(padding: 7 * dockUnit, dock: true)
            .overlay(MenuAnchor { DockMenuView() })   // il tasto destro dove nessuna sezione ha un suo menu
            // Il Dock che sparisce sotto un trascinamento non resta acceso.
            .onDisappear { if hover != nil { drop.hover = nil; drop.overBar = nil } }
            // Larga 45 al centro della barra da 52 starebbe a 5,5 dal bordo dello schermo (2 + 3,5); quella di macOS è a 5:
            // mezzo punto verso il bordo.
            .offset(x: (mirrored ? 0.5 : -0.5) * dockUnit * scale)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { onFrame($0) }
            .transition(.blurReplace)
            .animation(.smooth(duration: 0.3), value: state.dock)
            .animation(.smooth(duration: 0.3), value: [folders, shelf])
            .animation(.smooth(duration: 0.3), value: shown)
            .animation(.smooth(duration: 0.3), value: emptyShelf)
            .animation(.smooth(duration: 0.3), value: gap)
            .animation(.smooth(duration: 0.3), value: editing.on)
            .animation(.smooth(duration: 0.3), value: room?.at)
        }
    }

    // Il posto della sezione in mano: lei e lo spazio della sua linea.
    private func roomSpace(_ height: CGFloat) -> some View {
        Color.clear.frame(height: height + dockLine * scale).transition(.opacity)
    }

    // Una sezione. Le caselle del Dock a 31, 2 fra l'una e l'altra; le altre alla scala che porta i loro 26 nei 31 dentro
    // la capsula.
    @ViewBuilder private func section(_ item: BarItem, folders: [DockItem], shelf: [DockItem], gap: UUID?, emptyShelf: Bool) -> some View {
        let step = 33 * dockUnit * scale   // il passo del Dock (31 + 2), per il posto che si apre
        switch item {
        case .widget(.apps):
            BarStack(spacing: 2 * dockUnit) {
                ForEach(state.dock, id: \.pid) { app in
                    AppIconView(app: app, showName: false, size: dockIcon, action: { showApp(app) })
                        .opacity(app.dimmed ? 0.6 : 1)
                        .overlay(alignment: .topTrailing) { if let label = state.badges[app.pid] { DockBadge(label: label) } }
                        .modifier(DockName(name: app.name))
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
        case .widget(.folders):
            BarStack(spacing: 2 * dockUnit) {
                ForEach(folders) { fileTile($0, folder: true, above: gap == $0.id ? step : 0) }
                if gap == foldersEnd { Color.clear.frame(height: dockIcon * scale) }   // il posto in fondo alle cartelle
            }
        case .widget(.shelf):
            BarStack(spacing: 2 * dockUnit) {
                ForEach(shelf) { fileTile($0, folder: false, above: 0) }
                // Andata via, non conta più (DockDrop.dropSpot): a riposo c'è solo in un Dock che si vede trascinando.
                if emptyShelf {
                    tile(DockDrop.emptyShelf, above: 0) { EmptyShelfTile() }.transition(.opacity)
                        .onDisappear { onTile(DockDrop.emptyShelf, .null) }
                }
            }
        default:
            BarItemView(id: item, state: state, icons: icons)
                .environment(\.mergedPill, true)
                .environment(\.barScale, scale * inDockScale)
        }
    }

    @ViewBuilder private func fileTile(_ item: DockItem, folder: Bool, above: CGFloat) -> some View {
        if let url = item.url {
            tile(item.id, above: above) { DockFileTile(item: item, url: url, folder: folder) }
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    // Una cartella o un file: dà la sua cornice alla barra (senza il posto aperto sopra di lei) e, se il posto della
    // cartella trascinata si apre davanti a lei, scende di `above` (un passo del Dock), come se ci fosse una voce in più.
    private func tile(_ id: UUID, above: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { onTile(id, $0) }
            .padding(.top, above)
    }

    private func shows(_ item: BarItem) -> Bool { barItemShows(item, state: state, settings: settings, drop: drop, editing: editing) }

    // Davanti a quale cartella si apre il posto: solo se arrivano cartelle e non sulla mensola (il posto lo dà la barra,
    // DockDrop.dropSpot). In fondo alle cartelle è foldersEnd: prima della linea che le separa dalla mensola.
    private func gapBefore(_ hover: DockHover) -> UUID? {
        guard hover.folders, case .folders(let before) = hover.spot else { return nil }
        return before ?? foldersEnd
    }
}

// La barra non resta mai senza niente da cliccare (spec impostazioni-nel-dock §2, autore 27/10: «Resta una capsula vuota»):
// fuori dalla modifica, se nessuna sezione di nessun Dock si vede (nessun Dock, o solo sezioni vuote; lo Stato acceso si vede
// sempre), al centro c'è la capsula vuota del Dock (EmptyBarCapsule). La regola è quella dei Dock (barItemHasContent), con
// due attese che vengono dai dati, non dal tempo: all'avvio la barra deve aver letto (le app al primo giro del Poller, da cui
// i rapporti degli spazi non sono mai vuoti; i segnalibri di cartelle e mensola risolti; la prima lettura di In riproduzione, che
// è AppleScript e arriva dopo), così la capsula non compare e
// scompare mentre le sezioni arrivano; e trascinando un file (dal Finder o dal Dock) un Dock con Cartelle o Mensola mostra
// dove lasciarlo (DockBoxView), quindi lei gli lascia il posto. In modifica si vedono le sezioni vuote: lei no.
@MainActor func emptyBarCapsuleShows(docks: [DockBox], state: BarState, settings: Settings = .shared, drop: DockDrop = .shared,
                                     display: CGDirectDisplayID, editing: Editing? = nil) -> Bool {
    let read = !state.reports.isEmpty && !(settings.dockFolders + settings.dockShelf).contains { $0.url == nil && !$0.hidden }
        && (state.trackRead || !settings.isOn(.nowPlaying))
    let dropping = (drop.source != nil || drop.fileDrag == display || drop.overBar == display) && docks.contains { $0.hasFolders || $0.hasShelf }
    return read && !dropping && !(editing ?? .shared).on
        && !docks.contains { $0.sections.contains { barItemHasContent($0, state: state, settings: settings, drop: drop) } }
}

// La capsula vuota: il vetro del Dock attorno a una casella vuota, largo e coi margini di un Dock con una voce, sulla sua
// colonna. Il tasto destro è quello del vetro del Dock (Modifica Dock…, Impostazioni); un clic entra in modifica sullo
// schermo della sua barra. Il vetro prende i clic come quello del Dock.
struct EmptyBarCapsule: View {
    let display: CGDirectDisplayID?
    let mirrored: Bool
    var editing = Editing.shared   // le prove ne danno una loro
    @Environment(\.barScale) private var scale

    var body: some View {
        Color.clear.frame(height: dockIcon * scale)
            .pill(padding: 7 * dockUnit, dock: true)
            .overlay(MenuAnchor { DockMenuView() })
            .offset(x: (mirrored ? 0.5 : -0.5) * dockUnit * scale)   // come la capsula del Dock
            .onTapGesture(perform: click)
            .accessibilityElement().accessibilityLabel(Text("Edit Dock…")).accessibilityAddTraits(.isButton)
    }

    func click() { editing.begin(on: display) }
}

// Il tasto destro dentro un Dock ha sempre in fondo Modifica Dock… e Impostazioni… (spec impostazioni-nel-dock §1): dove la
// sezione sotto il puntatore non ha un suo menu (una pillola spazio fuori dalle sue icone, i margini e il vetro della
// capsula) il menu è solo quello. Sta sopra tutta la capsula: dietro non riceverebbe niente, perché SwiftUI dà il punto alla
// vista più in alto e il vetro e le sezioni prendono i click (misurato il 25/10, everyRightClickInADockEndsInSettings). Dove
// c'è il menu di una sezione non prende il tasto, e il punto scende a quello.
final class DockMenuView: RightClickMenuView {
    override func menu() -> NSMenu {
        let menu = NSMenu()
        addEditItems(to: menu, from: self)
        return menu
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, let root = window?.contentView, let at = superview?.convert(point, to: nil) else { return hit }
        return sectionMenu(in: root, at: at) == nil ? hit : nil
    }
}

// Il menu di una sezione sotto quel punto della finestra, se c'è.
private func sectionMenu(in view: NSView, at point: NSPoint) -> NSView? {
    if view is RightClickMenuView, !(view is DockMenuView), !view.isHiddenOrHasHiddenAncestor,
       view.convert(view.bounds, to: nil).contains(point) { return view }
    return view.subviews.lazy.compactMap { sectionMenu(in: $0, at: point) }.first
}

// Le voci della linea del Dock di macOS che dockduo ha (autore, 25/10): Nascondi, la posizione sullo schermo senza In basso
// (la barra sta solo di lato; anche senza AeroSpace, spec app conclusa §2.3) e Riduci usando del Dock di macOS
// (useMinimizeEffect) e Dimensione (la larghezza della barra, in fondo). Niente Ingrandimento: dockduo non ce l'ha. Le stesse nel menu della linea e in cima a Impostazioni ›,
// che si apre da ogni punto della barra (autore, 28/10: «DEVE essere uguale»): la linea non c'è con una sezione sola. Dicono
// lo stato di quando il menu si apre.
@MainActor func dockLineItems(settings: Settings, dock: UserDefaults?, state: BarState = .shared) -> [NSMenuItem] {
    let effect = dock.map(minimizeEffect) ?? "genie"
    return hidingItems(settings, state) + [
        choices(String(localized: "Position on Screen"), [(String(localized: "Left"), Side.left), (String(localized: "Right"), .right)],
                current: settings.barSide) { settings.barSide = $0 },
        choices(String(localized: "Minimize Using"), [(String(localized: "Genie Effect"), "genie"), (String(localized: "Scale Effect"), "scale")],
                current: effect) { if $0 != effect { useMinimizeEffect($0) } },
        menuViewItem(NSHostingView(rootView: SizeRow(settings: settings)), height: 28),
    ]
}

// Nascondi: l'interruttore dell'utente; senza spazio per la barra (barHides) al suo posto una riga grigia con la spunta e il
// motivo in breve, e l'interruttore resta com'era. Senza un file dell'utente anche la voce che lo crea.
@MainActor private func hidingItems(_ settings: Settings, _ state: BarState) -> [NSMenuItem] {
    guard let problem = state.spaceProblem else {
        return [ActionItem(String(localized: settings.autohide ? "Turn Hiding Off" : "Turn Hiding On")) { settings.autohide.toggle() }]
    }
    let reason = switch problem {
    case .notInstalled: String(localized: "AeroSpace isn't installed")
    case .notOpen: String(localized: "AeroSpace isn't open")
    case .noUserConfig: String(localized: "AeroSpace has no config file of its own")
    case .unknownForm: String(localized: "AeroSpace's gaps are in a form dockduo can't edit")
    case .rejected: String(localized: "AeroSpace rejected the gaps")
    }
    let lines = [greyLine(String(localized: "Hidden: no space reserved"), on: true), greyLine(reason)]
    guard problem == .noUserConfig else { return lines }
    return lines + [ActionItem(String(localized: "Create AeroSpace Config")) { createAerospaceConfigAndSync() }]
}

// Una voce col suo sottomenu: una scelta per valore, col segno su quella di adesso.
@MainActor private func choices<V: Equatable>(_ title: String, _ options: [(title: String, value: V)], current: V,
                                              _ choose: @escaping (V) -> Void) -> NSMenuItem {
    let submenu = NSMenu()
    for option in options { submenu.addItem(ActionItem(option.title, on: option.value == current) { choose(option.value) }) }
    return submenuItem(title, submenu)
}

// Il menu della linea del Dock di macOS: le sue voci (dockLineItems) e in fondo Modifica Dock… e Impostazioni › come ogni
// menu della barra.
final class DockLineMenuView: RightClickMenuView {
    private let settings: Settings
    private let dock: UserDefaults?   // com.apple.dock (le prove ne danno uno loro)
    private let update: @MainActor () -> Updater.State   // lo stato dell'aggiornamento (le prove ne danno uno loro)
    init(settings: Settings, dock: UserDefaults? = UserDefaults(suiteName: "com.apple.dock"),
         update: @escaping @MainActor () -> Updater.State = { Updater.shared.state }) {
        (self.settings, self.dock, self.update) = (settings, dock, update)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    // Il cursore a frecce sopra la linea, come nel Dock di macOS: la barra non diventa mai la finestra attiva e dockduo
    // non è l'app davanti, quindi serve un'area che lo chieda sempre (.activeAlways) e il permesso di cambiarlo da dietro
    // (allowCursorInBackground, all'avvio). pointerStyle di SwiftUI lì non bastava (autore, 25/10: «il cursore non cambia»).
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }
    // Le sole frecce, senza la barretta in mezzo, come sulla linea del Dock di macOS (autore, 25/10).
    private var resizeCursor: NSCursor { .frameResize(position: settings.barSide == .left ? .right : .left, directions: .all) }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func menu() -> NSMenu {
        let menu = NSMenu()
        addUpdate(to: menu)
        dockLineItems(settings: settings, dock: dock).forEach(menu.addItem)
        addEditItems(to: menu, from: self)
        return menu
    }

    // In cima, staccato, l'aggiornamento (Updater.swift; spec dock-degli-agenti §3: era in cima al menu delle mascotte) com'è
    // adesso, perché il menu non cambia da aperto; niente da offrire, niente voce.
    private func addUpdate(to menu: NSMenu) {
        switch update() {
        case .available(let r):
            menu.addItem(NSMenuItem(String(localized: "Update to \(r.version)"), #selector(updateItem), target: self))
        case .downloading(let r):
            menu.addItem(NSMenuItem(title: String(localized: "Downloading \(r.version)…"), action: nil, keyEquivalent: ""))   // senza azione: grigia
        case .failed:
            menu.addItem(NSMenuItem(String(localized: "Update failed · download the DMG"), #selector(openReleasePage), target: self))
        case .idle, .upToDate:
            return
        }
        menu.addItem(.separator())
    }

    @objc private func updateItem() { Task { await Updater.shared.install() } }
    @objc private func openReleasePage() { DispatchQueue.main.async { NSWorkspace.shared.open(latestReleasePage) } }
}

private let foldersEnd = UUID()   // il posto in fondo alle cartelle, dove si apre per una cartella che arriva
let lifted = 0.4   // l'opacità della sezione trascinata, al suo posto finché non la lasci

// Le misure del Dock di macOS (autore, 25/10: «copia lo stile del dock»), lette su una cattura a 2× col Dock a 31 pt (la sua
// grandezza nelle impostazioni dell'autore): icone 31 (il disegno è ~25, il resto è il margine trasparente dell'icona), 2
// fra le icone, 7 dal bordo della capsula alle icone su tutti e quattro i lati, quindi larga 45 (31 + 14), e angoli 15,5
// (metà dell'icona). Il bordo è dove comincia il vetro: la riga scura da 1 px attorno sta fuori, come quella che disegna
// il nostro vetro (rimisurato il 25/10: la prima misura, 46 e 7,5, la contava; gli angoli dal profilo degli angoli in
// basso, riga per riga, contro il nostro vetro a raggi da 12 a 17). In punti a barra larga 52 (il default), in scala con
// la barra come le altre pillole: × larghezza/52.
// shortcut: le proporzioni sono misurate sul Dock a 31 e scalano con la barra; la barra nuova parte da quel Dock (widthForDockTiles), ma le misure non si rifanno se cambia.
let dockUnit: CGFloat = 38.0 / 52   // da punti a barra 52 a unità della barra (barScale = larghezza/38)
let dockWidth = 45 * dockUnit
let dockRadius = 15.5 * dockUnit
let dockIcon = 31 * dockUnit   // il lato delle icone: una casella del Dock
let dockLine = 13 * dockUnit   // la fascia della linea fra due sezioni (DockSeparator): 6 + 1 + 6
// Le pillole di prima sono larghe 26: dentro il Dock, nella scala che le porta ai 31 dell'interno della capsula (45 - 7 - 7).
let inDockScale: CGFloat = dockIcon / 26

// La linea di separazione del Dock di macOS, misurata sulla stessa cattura (2×, Dock a 31, 25/10): spessa 1, lunga 33 e
// al centro della capsula, il chiaro del testo al 27 % (77,79,91 sul vetro a 11,14,26: +65 su ogni canale). Fra l'ultima
// app e la prima voce dopo ci sono 17 invece di 2: 8 sopra la linea, 1 la linea, 8 sotto (la voce dopo si ritrova dal
// disegno della cartella, che finisce 4 sopra il fondo del suo posto come quella che dà il Finder a 31). Coi 2 fra le
// voci attorno: 6 + 1 + 6. Lo spessore a pixel interi (almeno 1), se no in un'altra scala è un filo sfocato; l'altezza
// resta 13. È la linea fra due sezioni del Dock (DockBoxView).
// Come quella di macOS (autore, 25/10): il tasto destro apre il suo menu (DockLineMenuView) e trascinarla ridimensiona il
// Dock (lineDragWidth), col cursore delle misure a destra e sinistra. Li prende tutta la sua fascia, 6 + 1 + 6 larga quanto
// la capsula. Col ⌘ il trascinamento è quello della barra, che sposta il Dock: qui niente.
private struct DockSeparator: View {
    let settings: Settings
    @Environment(\.barScale) private var scale
    @Environment(\.displayScale) private var pixels
    // Larghezza, scala e puntatore di quando il trascinamento è cominciato, e se ridimensiona (senza ⌘). Si azzera da sé
    // alla fine, anche di un gesto interrotto.
    @GestureState private var start: (width: Double, scale: CGFloat, x: CGFloat, resizes: Bool)?

    var body: some View {
        let u = dockUnit * scale
        Rectangle().fill(.foreground.opacity(0.27))
            .frame(width: 33 * u, height: max(1, (u * pixels).rounded()) / pixels)
            .padding(.top, 6 * u)
            .frame(height: dockLine * scale, alignment: .top)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(resize)
            .overlay(MenuAnchor { DockLineMenuView(settings: settings) })
    }

    // Il puntatore si legge sullo schermo: la barra a destra si allarga verso sinistra, e nel pannello il punto di partenza
    // scapperebbe con lei. Al primo passo la barra non si è ancora mossa: lì il trascinamento dice dov'era all'inizio.
    private var resize: some Gesture {
        DragGesture(minimumDistance: 2).updating($start) { v, start, _ in
            let x = NSEvent.mouseLocation.x
            if start == nil { start = (settings.sideWidth, scale, x - v.translation.width, !NSEvent.modifierFlags.contains(.command)) }
            guard let s = start, s.resizes else { return }
            let width = lineDragWidth(start: s.width, scale: s.scale, dx: x - s.x, side: settings.barSide)
            if width != settings.sideWidth { settings.sideWidth = width }
        }
    }
}

// La larghezza della barra trascinando la linea del Dock di `dx` punti sullo schermo (verso destra in più): verso il centro
// dello schermo più grande, verso il bordo più piccolo, a numeri interi e nei suoi limiti (sideWidths). Come
// nel Dock di macOS il bordo interno del Dock segue il puntatore: la capsula è al centro della barra, larga dockWidth per la
// sua scala (quella dell'inizio, già ristretta se la barra non tiene i Dock), quindi il bordo fa (1 + capsula/barra) / 2
// di punto per punto di barra.
func lineDragWidth(start: Double, scale: CGFloat, dx: CGFloat, side: Side) -> Double {
    let toCentre = side == .left ? dx : -dx, edge = (1 + dockWidth * scale / start) / 2
    return clamped((start + toCentre / edge).rounded(), to: sideWidths, default: start)
}

// Riduci usando del Dock di macOS: l'effetto scelto in com.apple.dock (mineffect); senza, il genio, quello di fabbrica.
func minimizeEffect(_ dock: UserDefaults) -> String { dock.string(forKey: "mineffect") ?? "genie" }

// Sceglierlo cambia l'impostazione del Dock di macOS e lo fa ripartire, perché la legga (autore, 25/10: «Sì, la tengo»).
// Fuori dal main (shell aspetta); se la scrittura non riesce il Dock resta com'è. Solo dal menu: le prove non la chiamano.
func useMinimizeEffect(_ effect: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        guard shell("/usr/bin/defaults", ["write", "com.apple.dock", "mineffect", "-string", effect]) != nil else { return }
        _ = shell("/usr/bin/killall", ["Dock"])
    }
}

// Una cartella o un file: l'icona che le dà il Finder, nello stesso posto da 31 delle app (sulla cattura il passo è lo
// stesso, 31 + 2; il disegno della cartella è 29 × 23 dentro i 31, come lo dà il Finder) e con la loro ombra. L'icona si
// chiede fuori dal thread principale: per un disco di rete bloccato resta vuoto il posto, non la barra.
// Si trascina (DockDrop.lift): una cartella cambia posto o esce dal Dock, un file esce come il file vero. Il gesto è
// simultaneo, come quello delle icone negli spazi: il clic e il ⌘-trascina della barra restano. Clic = la apre, tasto
// destro = il suo menu (DockItemMenu), come le app.
private struct DockFileTile: View {
    let item: DockItem
    let url: URL
    let folder: Bool
    @Environment(\.barScale) private var scale
    @State private var icon: NSImage?
    @State private var name: String?   // il nome che le dà il Finder (Download, Scrivania), per DockName

    var body: some View {
        Group { if let icon { Image(nsImage: icon).resizable() } else { Color.clear } }
            .frame(width: dockIcon * scale, height: dockIcon * scale)
            .shadow(color: .black.opacity(0.3), radius: 2 * scale)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { v in
                DockDrop.shared.lift(item, folder: folder, icon: icon, grab: v.startLocation, size: dockIcon * scale)
            })
            // Il clic la apre (la cartella nel Finder), con `open` come il resto della barra; appena si muove è il
            // trascinamento, e il suo rilascio non la apre (DockDrop.liftedPress).
            .simultaneousGesture(TapGesture().onEnded { if !DockDrop.shared.releasesLift() { open(url.path) } })
            .overlay(DockItemMenu(id: item.id, url: url, folder: folder))   // sopra: riceve il click destro, inoltra i sinistri
            .modifier(DockName(name: name))
            .task(id: url) {
                let found = await finderIconAndName(url)
                // un caricamento vecchio (l'url è cambiato nel frattempo) non deve coprire quello nuovo
                if !Task.isCancelled { (icon, name) = (found.icon, found.name) }
            }
    }
}

// Il nome al passaggio del mouse su un'app, una cartella o un file, come nel Dock di macOS (spec dock §5), se acceso nelle
// opzioni di App aperte, Cartelle o Mensola (SectionMenu): subito e finché il puntatore è sull'icona, nel
// pannello dei testi di lato (DockNameLabel).
// Mai mentre trascini sul Dock, da lui o col ⌘ le pillole, né con un menu della barra aperto; e lì il passaggio si azzera:
// durante un trascinamento o un menu AppKit non dice quando il puntatore se ne va, e il nome tornerebbe dopo, appeso.
// L'uscita aspetta un attimo (0,05 s): attraversando i 2 pt fra due icone il nome non lampeggia, come nel Dock di macOS;
// intanto la voce dopo lo prende. L'ancora è larga quanto la capsula: il nome si misura dal suo vetro
// (dockNameGap). Un solo id per barra: passando da una voce all'altra il nome cambia, e chi se ne va lo toglie solo se è
// ancora il suo (testo e cornice); rientrando, la voce lo riprende (claim) anche se la sua uscita non era ancora partita o
// la barra l'aveva tolto. Un'uscita persa la rimedia la barra (SidePanel.dropStaleDockName).
private struct DockName: ViewModifier {
    let name: String?
    @State private var hovering = false
    @State private var leaving: DispatchWorkItem?
    @State private var entered = 0   // ogni entrata chiede di nuovo il nome

    func body(content: Content) -> some View {
        let drop = DockDrop.shared
        let busy = drop.active || drop.source != nil || BarHold.shared.menuOpen || SideDrag.shared.current != nil
        content
            .onHover { inside in
                leaving?.cancel()
                if inside { hovering = true; entered += 1 } else { debounce(&leaving, after: 0.05) { hovering = false } }
            }
            .onChange(of: busy) { _, now in if now { leaving?.cancel(); hovering = false } }
            .frame(maxWidth: .infinity)
            .sideLabel(id: SideLabels.dock, text: hovering && !busy && Settings.shared.dockHoverNames ? name : nil, style: .dockName,
                       claim: entered)
    }
}

// Il nome al passaggio del mouse del Dock di macOS, misurato il 25/10 su una cattura a 2× dell'autore, puntatore su App
// Store e Dock a sinistra (lì il Dock è a 33: passo 35, vetro largo 47; nel Dock di macOS il nome non cresce col Dock,
// quindi qui resta in punti e non segue la larghezza della barra). Una capsula alta 26 (righe 924-975), tonda del tutto; il
// nome in SF a 14 regolare (le otto lettere di "App Store" cadono sulle stesse colonne di un 14 regolare disegnato da noi),
// bianco al 95 % (244-245 sopra 33 e sopra 55); 13 per lato fra vetro e testo (macOS arrotonda la larghezza al punto: a
// destra mezzo punto in più, qui no). Mezzo punto sopra il centro della voce (capsula 924-975, icona 924-977) e il testo
// mezzo punto sopra il centro della capsula (la base delle lettere 36 pixel sotto la sua cima, non 37). A 6 dal vetro del
// Dock (dockNameGap). Il fondo è vetro, più chiaro di quello del Dock: ~32 sopra quello che ha dietro (33,38,47 sul blu a
// 1,2,8; 55,56,58 sul grigio a 25,26,27; il Dock sullo stesso blu +12), l'orlo chiaro sopra e sotto e la riga scura di
// lato: il .regular di Liquid Glass, chiaro o scuro come la barra. Col chiaro il testo è il nero delle etichette (non
// misurato). Un nome lungo si tronca in fondo: la capsula resta nel pannello dei testi (360). Gli agenti sull'app la usano col
// testo nel colore dello stato (`color`) dove si legge su questo vetro (contrasto WCAG ≥ 4,5:1, sul suo
// fondo misurato), altrimenti nel colore del nome: sul vetro chiaro il giallo e il verde scendono a 1,1–1,3:1.
struct DockNameLabel: View {
    let text: String
    var color: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = scheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.85)
        let glass = scheme == .dark ? Color(red: 33 / 255, green: 38 / 255, blue: 47 / 255) : Color(red: 0.94, green: 0.945, blue: 0.955)
        let name = Text(text).font(.system(size: 14)).lineLimit(1)
            .foregroundStyle(color.map { Dockduo.contrast($0, glass) >= 4.5 ? $0 : ink } ?? ink)
        ViewThatFits(in: .horizontal) { name.fixedSize(); name.truncationMode(.tail).frame(width: 300, alignment: .leading) }
            .offset(y: -0.5)
            .padding(.horizontal, 13).frame(height: 26)
            .glassEffect(.regular, in: Capsule())
    }
}

// Dal lato interno della barra al nome di una voce del Dock: 6 dal vetro del Dock, come in macOS (pixel 104-115 della
// cattura, fra i due vetri). `anchor` è la capsula all'altezza della voce, nello spazio "bar"; il pannello dei testi comincia
// al lato interno della barra, quindi il vuoto è 6 meno quanto la capsula sta dentro la barra (a barra 52: 4, quindi 2).
// Mai dentro la barra: col Dock rimpicciolito la capsula sta più dentro e il nome si appoggia al bordo.
func dockNameGap(anchor: CGRect, barWidth: CGFloat, opensLeft: Bool) -> CGFloat {
    max(0, 6 - (opensLeft ? anchor.minX : barWidth - anchor.maxX))
}

// La mensola vuota mentre trascini sul Dock (spec dock §3): una casella tratteggiata grande quanto il disegno di un'icona
// (25 dentro i 31), con gli angoli delle icone di macOS e il chiaro della linea, un filo più deciso.
private struct EmptyShelfTile: View {
    @Environment(\.barScale) private var scale

    var body: some View {
        let u = dockUnit * scale
        RoundedRectangle(cornerRadius: 5.6 * u, style: .continuous)
            .strokeBorder(.foreground.opacity(0.5), style: StrokeStyle(lineWidth: 1 * u, dash: [3 * u, 2 * u]))
            .frame(width: 25 * u, height: 25 * u)
            .frame(width: dockIcon * scale, height: dockIcon * scale)
    }
}

// Il vetro del Dock di macOS (autore, 25/10): il vetro privato "dock" di SwiftUI con l'opzione privata che lo forza
// nell'aspetto attivo, perché la barra non è mai una finestra attiva e lì ogni vetro si disegna piatto. Misurato il 25/10
// sopra la stessa scrivania (fascia vuota di lato, parte scura): 20-21 su 255 contro i 20-22 del Dock vero; il .clear
// pubblico e la variante 2 di NSGlassEffectView (identici fra loro) 37-38 da inattivi e 49 da attivi. Tecnica vista in
// DockDoor (Utilities/LiquidGlass.swift), riscritta: i getter privati per nome; il loro _Glass (40 byte su macOS 27.2) in un
// contenitore più grande; prima di toccarlo la sua forma, letta dal valore intatto (campi, misure, e da lì dove stanno le
// opzioni aggiunte e tolte); poi il bit aggiunto e tolto, riletto per controllo, e Glass(explicit:), una volta sola. Prima di
// macOS 27, un simbolo che manca, un'altra forma o un controllo che fallisce: nil, e il Dock resta col .clear pubblico.
// shortcut: API private di SwiftUI e la disposizione di _Glass, ricontrollare dopo ogni aggiornamento di macOS.
let dockGlass: Glass? = {
    guard #available(macOS 27, *) else { return nil }
    let symbols = ["$s7SwiftUI6_GlassV4dockACvgZ", "$s7SwiftUI6_GlassV14VariantOptionsV21forceActiveAppearanceAEvgZ",
                   "$s7SwiftUI5GlassV8explicitAcA01_C0V_tcfC"]
    guard symbols.allSatisfy({ dlsym(dlopen(nil, RTLD_NOW), $0) != nil }),
          let type = _typeByName("7SwiftUI6_GlassV"), let optionType = _typeByName("7SwiftUI6_GlassV14VariantOptionsV"),
          layout(type).size == 40, layout(type).alignment <= MemoryLayout<GlassBytes>.alignment, layout(optionType).size == 8,
          layout(optionType).alignment == 8   // le opzioni si leggono come UInt64: offset multipli di 8
    else { return nil }
    var glass = privateDockGlass()
    guard let at = optionOffsets(glass, type, optionType) else { return nil }
    let bit = withUnsafeBytes(of: privateForceActive()) { $0.load(as: UInt64.self) }
    guard bit.nonzeroBitCount == 1 else { return nil }
    withUnsafeMutableBytes(of: &glass) { raw in
        raw.storeBytes(of: raw.load(fromByteOffset: at.added, as: UInt64.self) | bit, toByteOffset: at.added, as: UInt64.self)
        raw.storeBytes(of: raw.load(fromByteOffset: at.removed, as: UInt64.self) & ~bit, toByteOffset: at.removed, as: UInt64.self)
    }
    let variant = Mirror(reflecting: reflected(glass, type)).children.first?.value
    func option(_ name: String) -> UInt64? {
        let raw = variant.flatMap { Mirror(reflecting: $0).descendant(name, "rawValue") }
        return (raw as? Int).map { UInt64(bitPattern: Int64($0)) } ?? raw as? UInt64
    }
    guard option("addedOptions") == bit, option("removedOptions") == 0 else { return nil }
    return privateGlass(explicit: glass)
}()

// Dove stanno le opzioni aggiunte e tolte nel _Glass intatto, se ha la forma che conosciamo: variant (primo campo, quindi
// al byte 0) e storage; dentro variant ruolo "dock", lista, opzioni aggiunte e tolte da 8 byte. Le posizioni vengono dalle
// misure dei campi, una dopo l'altra con il loro allineamento, e devono tornare con la misura di variant.
private func optionOffsets(_ glass: GlassBytes, _ glassType: Any.Type, _ optionType: Any.Type) -> (added: Int, removed: Int)? {
    let top = Mirror(reflecting: reflected(glass, glassType)).children
    guard top.map(\.label) == ["variant", "storage"], let variant = top.first?.value else { return nil }
    let fields = Mirror(reflecting: variant).children
    guard fields.map(\.label) == ["role", "plist", "addedOptions", "removedOptions"],
          String(describing: fields.first!.value) == "dock" else { return nil }
    var offset = 0, offsets: [String: Int] = [:]
    for field in fields {
        let t = type(of: field.value), (size, alignment) = layout(t)
        offset = (offset + alignment - 1) / alignment * alignment
        if field.label!.hasSuffix("Options") {
            guard t == optionType, size == 8 else { return nil }
            offsets[field.label!] = offset
        }
        offset += size
    }
    guard offset == layout(type(of: variant)).size, let added = offsets["addedOptions"], let removed = offsets["removedOptions"],
          max(added, removed) + 8 <= layout(glassType).size else { return nil }
    return (added, removed)
}

// Il _Glass nei byte, copiato come valore del suo tipo (solo dopo i controlli di misura e allineamento).
private func reflected(_ glass: GlassBytes, _ type: Any.Type) -> Any {
    func read<T>(_: T.Type) -> Any { withUnsafeBytes(of: glass) { $0.load(as: T.self) } }
    return _openExistential(type, do: read)
}

private func layout(_ type: Any.Type) -> (size: Int, alignment: Int) {
    func measure<T>(_: T.Type) -> (size: Int, alignment: Int) { (MemoryLayout<T>.size, MemoryLayout<T>.alignment) }
    return _openExistential(type, do: measure)
}

// Più grande di _Glass: i getter privati ci scrivono il loro valore.
private struct GlassBytes { var words = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0)) }
@_weakLinked @_silgen_name("$s7SwiftUI6_GlassV4dockACvgZ") private func privateDockGlass() -> GlassBytes
@_weakLinked @_silgen_name("$s7SwiftUI6_GlassV14VariantOptionsV21forceActiveAppearanceAEvgZ") private func privateForceActive() -> GlassBytes
@_weakLinked @_silgen_name("$s7SwiftUI5GlassV8explicitAcA01_C0V_tcfC") private func privateGlass(explicit: GlassBytes) -> Glass

// Il numero rosso, appena fuori dall'angolo dell'icona; un'etichetta vuota è il solo pallino. Largo al più quanto l'icona:
// un testo lungo si tronca in fondo, come nel Dock. Non prende i click: vanno all'icona sotto.
private struct DockBadge: View {
    let label: String
    @Environment(\.barScale) private var scale

    var body: some View {
        Text(label).font(.system(size: 9 * scale, weight: .bold)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, label.count > 1 ? 3 * scale : 0)
            .frame(minWidth: 12 * scale, minHeight: 12 * scale)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .frame(width: dockIcon * scale, alignment: .trailing)   // propone la larghezza dell'icona: il pallino resta stretto sul testo
            .offset(x: 4 * scale, y: -4 * scale)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}
