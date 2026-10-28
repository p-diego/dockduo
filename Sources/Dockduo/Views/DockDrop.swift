import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Trascinare sul Dock e dal Dock (spec dock §2, §3, §5). Sul Dock: file e cartelle dal Finder, nelle sezioni del Dock su
// cui lasci (dockDropRule); le cartelle fra le cartelle nel punto del rilascio, il resto sulla mensola; intanto si vedono
// la linea, la casella della mensola vuota e il posto che si apre fra le cartelle. Dal Dock: una cartella cambia posto o,
// rilasciata altrove, esce dal Dock; un file della mensola esce come il file vero e resta sulla mensola. Solo
// riferimenti: qui nessun file si sposta, si copia o si cancella.

// Dove cade un rilascio: sulla mensola, o fra le cartelle davanti a quella con quell'id (nil: in fondo).
enum DockSpot: Equatable { case shelf, folders(before: UUID?) }

// Fra le cartelle (le loro cornici dall'alto, nell'ordine del Dock): prima di tutte quelle col centro sotto il puntatore.
// Sopra le app o sulla linea: la prima.
func folderDropIndex(y: CGFloat, folderFrames: [CGRect]) -> Int { folderFrames.filter { $0.midY < y }.count }

// Dalla cima della prima voce della mensola in giù è la mensola; `shelfTop` nil (un Dock senza Mensola, o una cartella del
// Dock che cambia posto): sempre fra le cartelle. `folders` nil, un Dock senza Cartelle: sempre sulla mensola, anche
// sopra la sua prima voce, mai fra le cartelle di un altro Dock (dockDropRule).
func dockSpot(y: CGFloat, folders: [(id: UUID, frame: CGRect)]?, shelfTop: CGFloat?) -> DockSpot {
    guard let folders else { return .shelf }
    if let shelfTop, y >= shelfTop { return .shelf }
    let k = folderDropIndex(y: y, folderFrames: folders.map(\.frame))
    return .folders(before: k < folders.count ? folders[k].id : nil)
}

// Dove va un rilascio di file e cartelle su un Dock, secondo le sue sezioni (spec dock-contenitori §6): le cartelle fra
// le sue Cartelle (il posto lo dà dockSpot: lasciate sulla Mensola vanno lì, come prima), se non ci sono sulla sua
// Mensola; i file sulla sua Mensola, se non c'è da nessuna parte. Lo prende se qualcosa ha dove andare: di un rilascio
// misto su un Dock senza Mensola restano le cartelle, uno di soli file lì è rifiutato; un Dock senza Cartelle né Mensola
// non prende niente.
func dockDropRule(hasFolders: Bool, hasShelf: Bool, carriesFolders: Bool, carriesFiles: Bool)
    -> (accept: Bool, foldersTo: DockSpot?, filesTo: DockSpot?) {
    let folders: DockSpot? = !carriesFolders ? nil : hasFolders ? .folders(before: nil) : hasShelf ? .shelf : nil
    let files: DockSpot? = carriesFiles && hasShelf ? .shelf : nil
    return (folders != nil || files != nil, folders, files)
}

extension DockBox {
    var hasFolders: Bool { sections.contains(.widget(.folders)) }
    var hasShelf: Bool { sections.contains(.widget(.shelf)) }
}

// I Dock che prendono un trascinamento, prima di sapere cosa porta (poi dockDropRule): dal Finder quelli con Cartelle o
// Mensola; una cartella del Dock solo quelli con le Cartelle, dove cambia posto (negli altri torna al suo); un file della
// mensola nessuno, non si riordinano. Una sezione ha il suo rilascio (sectionTarget).
func dockTakes(_ box: DockBox, from source: DockDrop.Source?) -> Bool {
    switch source {
    case nil: box.hasFolders || box.hasShelf
    case .folder: box.hasFolders
    case .file, .section: false
    }
}

// Dove cadrebbe una sezione trascinata sulla barra (in modifica), dall'altezza `y` nello spazio "bar", sulle cornici a riposo
// dei Dock e delle loro sezioni, in ordine (.null: non si vede). Dentro un Dock al posto fra le sue sezioni, come fra le
// cartelle (folderDropIndex); fuori dai Dock un Dock nuovo nella zona di quell'altezza (`zones`: i terzi della barra, come
// il ⌘-trascina), dopo i Dock della zona sopra il puntatore. Fuori dalla barra niente.
func sectionTarget(at y: CGFloat, docks: [(box: DockBox, frame: CGRect, sections: [CGRect])], zones: [Zone: CGRect]) -> SectionTarget? {
    func spans(_ r: CGRect) -> Bool { !r.isNull && r.minY <= y && y <= r.maxY }
    if let d = docks.first(where: { spans($0.frame) }) { return .into(dock: d.box.id, index: folderDropIndex(y: y, folderFrames: d.sections)) }
    guard let zone = Zone.allCases.first(where: { zones[$0].map(spans) ?? false }) else { return nil }
    let above = docks.filter { $0.box.zone == zone }.lastIndex { !$0.frame.isNull && $0.frame.midY < y }
    return .newDock(zone: zone, index: above.map { $0 + 1 } ?? 0)
}

// Il Dock sotto un trascinamento sulla barra, fra quelli che lo prendono (`docks`), sulle cornici a riposo (`resting`,
// spazio "bar": senza nessun trascinamento sopra). Quello che ce l'ha già lo tiene finché il puntatore sta nella sua
// cornice a riposo o in quella di adesso (`current`): allungandosi, e ricentrato dalla zona, non lo perde da solo.
func hoveredDock(at p: CGPoint, docks: [UUID], resting: [UUID: CGRect], current: [UUID: CGRect], hovered: UUID?) -> UUID? {
    // All'altezza del Dock, su tutta la larghezza della barra: anche accanto alla capsula, nel margine, conta come sopra.
    func spans(_ r: CGRect?) -> Bool { r.map { $0.minY <= p.y && p.y <= $0.maxY } ?? false }
    if let hovered, docks.contains(hovered), spans(resting[hovered]) || spans(current[hovered]) { return hovered }
    return docks.first { spans(resting[$0]) }
}

extension Settings {
    // Dove cadrebbe un rilascio a quell'altezza in quel Dock (dockSpot), sulle cornici a riposo delle sue voci (`resting`,
    // spazio "bar") e nelle sue sezioni: senza Cartelle sulla mensola, e non si apre nessun posto; senza Mensola, e per la
    // cartella che cambia posto, sempre fra le cartelle. Se no la mensola comincia dalla sua prima voce, o dalla casella
    // vuota; vuota e senza la casella a riposo, dove finisce il Dock a riposo: è lì che la casella lo allunga.
    func dropSpot(in box: DockBox, y: CGFloat, resting: [UUID: CGRect], moving: UUID?) -> DockSpot {
        let folders = dockFolders.filter { $0.shown && $0.id != moving }
        let first = resting[dockShelf.first(where: \.shown)?.id ?? DockDrop.emptyShelf] ?? .null
        return dockSpot(y: y, folders: box.hasFolders ? folders.map { ($0.id, resting[$0.id] ?? .null) } : nil,
                        shelfTop: moving != nil || !box.hasShelf ? nil : first.isNull ? resting[box.id]?.maxY : first.minY)
    }

    // Un rilascio di file e cartelle: i riferimenti si fanno fuori dal main (dockDropItems), qui si inseriscono e basta.
    // Le cartelle nel posto, una dopo l'altra; il resto sulla mensola, se il Dock ce l'ha (`shelf`, dockDropRule).
    @MainActor func dropOnDock(_ urls: [URL], at spot: DockSpot, shelf: Bool = true) async {
        let items = await dockDropItems(urls, onShelf: spot == .shelf)
        if case .folders(let anchor) = spot {
            var at = folderSlot(before: anchor)
            for item in items.folders { at = addFolder(item, at: at) + 1 }
        }
        if shelf, !items.shelf.isEmpty { addToShelf(items.shelf) }
    }

    // Il posto davanti a quella cartella nella lista intera, dove ci sono anche quelle nascoste di un disco staccato.
    func folderSlot(before anchor: UUID?) -> Int { dockFolders.firstIndex { $0.id == anchor } ?? dockFolders.count }
}

// Una cartella del Dock (o una sezione, in modifica) che nessun Dock ha preso esce dal Dock solo rilasciata lontano da ogni
// barra (`bars`, le loro finestre sullo schermo, una per schermo): oltre un passo del Dock tutto attorno, come in macOS, dove
// va trascinata via perché si tolga. Più vicino (il margine accanto alla capsula, fra le pillole, su un altro widget, su un
// Dock che non la prende, anche sull'altro schermo) resta al suo posto. Annullata con Esc resta (DockDrop.ended).
func folderDragRemoves(_ operation: NSDragOperation, at point: CGPoint, bars: [CGRect]) -> Bool {
    operation.isEmpty && !bars.contains { bar in
        let margin = bar.width * 33 / 52   // un passo del Dock (31 + 2) alla larghezza della barra
        return bar.insetBy(dx: -margin, dy: -margin).contains(point)
    }
}

// Cosa può farne chi riceve una voce del Dock. La cartella, e la sezione, solo cambiare posto nella barra: fuori da dockduo
// nessuno può spostarla, copiarla o buttarla (sul foglio del trascinamento c'è solo un tipo nostro, non il file). Il file
// della mensola come dal Finder: decide chi lo riceve (copia, sposta, alias, Cestino).
func dockDragMask(_ source: DockDrop.Source?, _ context: NSDraggingContext) -> NSDragOperation {
    switch source {
    case .folder, .section: context == .withinApplication ? .move : []
    case .file: [.copy, .link, .generic, .move, .delete]
    case nil: []
    }
}

@Observable final class DockDrop: NSObject, NSDraggingSource {
    static let shared = DockDrop()
    static let folderType = UTType(exportedAs: "app.dockduo.dock-folder")
    static let sectionType = UTType(exportedAs: "com.dockduo.section")   // una sezione, in modifica: sul foglio il suo token
    static let barTypes = [UTType.fileURL, folderType, sectionType]   // quello che prende il rilascio della barra (SideBarView)
    static let emptyShelf = UUID()   // la casella della mensola vuota, fra le cornici delle voci

    // Il Dock sotto un trascinamento (DockDropDelegate), uno per volta su tutte le barre: si allunga lui, sulla barra del
    // suo schermo. Intanto niente nomi al passaggio (DockName); quello che si vede lo decide la capsula sotto il
    // trascinamento. La barra la tiene fuori il puntatore, che le sta sopra.
    var hover: DockHover?
    var active: Bool { hover != nil }
    // La sezione in mano sopra una barra: dove le si apre il posto (room), uno per volta su tutte le barre.
    var sectionHover: SectionHover?
    // Cosa porta il trascinamento dal Finder (carries): si sa solo dopo, fuori dal main, e fino ad allora vale come preso.
    var carried: (folders: Bool, files: Bool)?
    // Un trascinamento dal Finder sopra la barra (DockDropDelegate): intanto i Dock con Cartelle o Mensola si vedono anche
    // vuoti, e ci si può lasciare sopra (autore, 25/10). L'entrata lo accende, l'uscita e il rilascio lo spengono.
    // shortcut: uno per tutte le barre, quindi i Dock vuoti compaiono anche su quelle degli altri schermi; se dà fastidio,
    // tenere lo schermo della barra (SidePlace.display) invece di un sì.
    var overBar = false
    // Un trascinamento in corso, di chiunque (il Finder o noi): col tasto premuto e la tavola del trascinamento cambiata da
    // quando era su. Intanto la striscia della barra ha un velo quasi invisibile (SideBarView): macOS fa passare quello che
    // sta sopra i punti trasparenti a chi c'è sotto, i trascinamenti come i clic, e vicino al bordo e agli angoli del Dock
    // che cambia misura lo faceva entrare e uscire a raffica (misurato il 25/10). Coi clic resta trasparente.
    private(set) var dragAround = false
    // Un file o una cartella del Finder in mano, ovunque sullo schermo: la mensola vuota mostra già la sua casella, così
    // arrivando sul Dock non cambia più niente sotto il puntatore (autore, 25/10: «quando inizio a draggare un file compare
    // la drop zone»). Un testo o una voce del Dock no.
    private(set) var fileDrag = false
    private var idleDragCount = NSPasteboard(name: .drag).changeCount
    private var wasPressed = false
    private var pressWatch: Timer?
    // Un rilascio dal Finder che sta ancora inserendo le sue voci (performDrop): il posto aperto resta finché arrivano.
    var inserting = 0   // i rilasci dal Finder ancora in corso (due possono accavallarsi)
    // Il battito, solo per la barra vera (le prove fanno a meno): 0,1 s, anche durante i trascinamenti (.common).
    func watchDrags() {
        guard pressWatch == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.dragTick(pressed: NSEvent.pressedMouseButtons & 1 != 0, count: { NSPasteboard(name: .drag).changeCount },
                           files: { NSPasteboard(name: .drag).types?.contains(.fileURL) == true })
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        pressWatch = t
    }

    // Un battito di watchDrags (le prove lo chiamano da sé): `pressed` il tasto sinistro; `count`, il numero della tavola del
    // trascinamento, e `files`, se sopra ci sono file, la leggono solo quando servono. La tavola si chiede al sistema a ogni
    // lettura: col tasto su e fermo non si legge, il numero di riposo si prende alla risalita.
    // shortcut: un trascinamento intero fra due battiti (giù, via e su in meno di 0,1 s) lascia il numero di riposo vecchio, e
    // alla pressione dopo il velo (e, se portava file, la casella della mensola) si accende per quella pressione sola; se
    // capita, rileggerlo anche da fermi, una volta al secondo.
    func dragTick(pressed: Bool, count: () -> Int, files: () -> Bool) {
        let settled = !pressed && !wasPressed   // su già al battito prima
        if !pressed, wasPressed { idleDragCount = count() }
        wasPressed = pressed
        let now = pressed && count() != idleDragCount
        if now != dragAround { dragAround = now }
        // Un file o una cartella presi fuori da dockduo: la casella della mensola compare subito (autore, 25/10).
        let fileNow = now && source == nil && files()
        if fileNow != fileDrag { fileDrag = fileNow }
        // Un trascinamento la cui uscita si è persa (dropExited mai arrivato): col tasto su e niente in mano non ce n'è
        // nessuno, quindi si spegne quello che spegne leave(). Solo dal secondo battito col tasto su: il tasto si legge già
        // su prima che il rilascio dal Finder arrivi (performDrop), che intanto ha avuto il suo giro. Non durante un
        // inserimento: lo spegne lui, a voci arrivate.
        guard settled, source == nil, inserting == 0 else { return }
        if hover != nil { hover = nil }
        if overBar { overBar = false }
        if sectionHover != nil { sectionHover = nil }
    }
    // La voce del Dock che stai trascinando: una cartella (via dal suo posto finché non la lasci), un file della mensola o, in
    // modifica, una sezione (dalla barra, attenuata al suo posto finché non la lasci, o dalla galleria).
    enum Source: Equatable { case folder(UUID), file(UUID), section(BarItem) }
    var source: Source? { didSet { hold() } }
    var moving: UUID? { if case .folder(let id) = source { id } else { nil } }
    var movingSection: BarItem? { if case .section(let item) = source { item } else { nil } }
    // Le barre accese, sullo schermo (folderDragRemoves): lette quando servono, così una uscita durante il trascinamento
    // (nascondi automatico) ha già la sua cornice. Le prove ne danno di loro.
    var bars: () -> [CGRect] = { NSApp.windows.compactMap { ($0 as? SidePanel).flatMap { $0.active ? $0.frame : nil } } }
    // La pressione del mouse da cui è partito l'ultimo trascinamento (il numero che macOS dà a giù, trascinato e su della
    // stessa pressione): il suo rilascio non è un clic. Un clic nuovo ha un altro numero, quindi non resta mai appeso.
    private var liftedPress: Int?
    let settings: Settings

    init(settings: Settings = .shared) { self.settings = settings }

    // Col nascondi automatico la barra resta fuori mentre si trascina una sua voce, anche lontano (BarHold). Solo quello
    // dell'app: quelli delle prove non toccano la barra.
    private func hold() {
        guard self === Self.shared else { return }
        BarHold.shared.dragging = source != nil
    }

    // Al primo movimento su una voce (DockFileTile) il trascinamento passa ad AppKit, come dal Finder: dentro il gesto
    // l'evento corrente è quello del mouse trascinato, con la sua finestra (misurato il 25/10). Col ⌘ è il ⌘-trascina
    // dei Dock: niente, anche se il ⌘ si lascia a metà (SideDrag è già partito). `grab`: dove hai preso l'icona, che
    // resta lì sotto il puntatore.
    func lift(_ item: DockItem, folder: Bool, icon: NSImage?, grab: CGPoint, size: CGFloat) {
        guard source == nil, SideDrag.shared.current == nil, let url = item.url, let event = NSApp.currentEvent,
              event.type == .leftMouseDragged, !event.modifierFlags.contains(.command), let window = event.window,
              let view = window.contentView else { return }
        let writer: NSPasteboardWriting
        if folder {
            let mark = NSPasteboardItem()
            mark.setString(item.id.uuidString, forType: NSPasteboard.PasteboardType(Self.folderType.identifier))
            writer = mark
        } else {
            writer = url as NSURL
        }
        let drag = NSDraggingItem(pasteboardWriter: writer)
        let at = view.convert(event.locationInWindow, from: nil)   // la vista della barra ha la y in giù, come SwiftUI
        drag.setDraggingFrame(CGRect(x: at.x - grab.x, y: at.y - grab.y, width: size, height: size), contents: icon)
        source = folder ? .folder(item.id) : .file(item.id)
        liftedPress = event.eventNumber
        _ = view.beginDraggingSession(with: [drag], event: event, source: self)
    }

    // In modifica, al primo movimento su una sezione (SectionMenuView) o, dalla galleria, su una sua casella: il trascinamento
    // passa ad AppKit come per le cartelle, con sul foglio il token della sezione e come immagine quello che si vede lì nella
    // finestra (la sezione col suo bordo). Col ⌘ è il ⌘-trascina dei Dock: niente.
    func lift(section item: BarItem, from view: NSView, event: NSEvent) {
        guard source == nil, SideDrag.shared.current == nil, !event.modifierFlags.contains(.command) else { return }
        let mark = NSPasteboardItem()
        mark.setString(item.token, forType: NSPasteboard.PasteboardType(Self.sectionType.identifier))
        let drag = NSDraggingItem(pasteboardWriter: mark)
        drag.setDraggingFrame(view.bounds, contents: snapshot(view))
        source = .section(item)
        _ = view.beginDraggingSession(with: [drag], event: event, source: self)
    }

    // Vero se il clic su una voce (DockFileTile) è il rilascio del trascinamento partito da quella pressione; il segno si
    // consuma qui.
    func releasesLift() -> Bool {
        guard let press = liftedPress, NSApp.currentEvent?.eventNumber == press else { return false }
        liftedPress = nil
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dockDragMask(source, context)
    }

    // Come nel Dock di macOS: una cartella (o una sezione) lasciata vicino a una barra torna al suo posto scorrendo, lontano
    // sparisce lì (esce dal Dock, folderDragRemoves). Si decide a ogni movimento, col punto dove la lasceresti.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        if moving != nil || movingSection != nil {
            session.animatesToStartingPositionsOnCancelOrFail = !folderDragRemoves([], at: screenPoint, bars: bars())
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ended(operation, at: screenPoint)
    }

    // La cartella che stai trascinando, rilasciata su un Dock: al suo nuovo posto.
    func dropped(at spot: DockSpot) {
        guard let id = moving else { return }
        if case .folders(let anchor) = spot { settings.moveFolder(id: id, to: settings.folderSlot(before: anchor)) }
        source = nil
    }

    // La sezione che stai trascinando, lasciata sulla barra (dalla barra o dalla galleria): al suo posto (Settings.place).
    func dropped(at target: SectionTarget) {
        guard let item = movingSection else { return }
        settings.place(item, at: target)
        source = nil
    }

    // Dove si apre il posto per la sezione in mano: dove cadrebbe davvero (sectionLanding). Nessuno dove lasciarla non
    // cambierebbe niente, come sul suo posto, da dove parte: lì la barra resta ferma sotto il puntatore.
    func room(at target: SectionTarget) -> SectionTarget? {
        guard let item = movingSection else { return nil }
        func look(_ docks: [DockBox]) -> [[[BarItem]]] { Zone.allCases.map { z in docks.filter { $0.zone == z }.map(\.sections) } }
        let docks = settings.docks
        return look(sectionPlaced(item, at: target, docks: docks)) == look(docks) ? nil : sectionLanding(item, at: target, docks: docks)
    }

    // Un trascinamento dal Finder che quel Dock rifiuta (dockDropRule), quando si sa cosa porta.
    func refuses(_ box: DockBox) -> Bool {
        carried.map { !dockDropRule(hasFolders: box.hasFolders, hasShelf: box.hasShelf, carriesFolders: $0.folders,
                                    carriesFiles: $0.files).accept } ?? false
    }

    // Fine del trascinamento, al punto del rilascio (sullo schermo). Una cartella che nessun Dock ha preso, lontano dalle
    // barre, esce dal Dock come in macOS: si toglie il riferimento, la cartella vera resta dov'è; vicino torna al suo
    // posto. Così una sezione, in modifica (spec impostazioni-nel-dock §2). Annullato con Esc (`cancelled`: il tasto è
    // ancora giù, un rilascio l'ha già alzato) resta, anche lontano. Un file della mensola lasciato dove lo prendono
    // (spostato, allegato, nel Cestino) esce dalla mensola; con ⌥, la copia del Finder, resta (autore, 25/10: «dopo che ho
    // spostato il file deve sparire dalla dropzone», ⌥ come il Finder). Rifiutato o annullato resta. Il file lo sposta o lo
    // copia chi lo riceve, mai dockduo.
    func ended(_ operation: NSDragOperation, at point: CGPoint, copying: Bool = NSEvent.modifierFlags.contains(.option),
               cancelled: Bool = NSEvent.pressedMouseButtons & 1 != 0) {
        let away = !cancelled && folderDragRemoves(operation, at: point, bars: bars())
        if let id = moving, away { settings.removeFolder(id: id) }
        if let item = movingSection, away { settings.removeSection(item) }
        if case .file(let id) = source, !operation.isEmpty, !copying { settings.removeFromShelf(id: id) }
        source = nil
        sectionHover = nil   // anche se la barra non ha saputo dell'uscita: il posto aperto non resta
    }
}

// Un trascinamento di sezione sopra una barra (DockDrop.sectionHover): dove le si apre il posto (DockDrop.room) e su che
// schermo.
struct SectionHover: Equatable {
    let target: SectionTarget
    let display: CGDirectDisplayID
}

// Un trascinamento sopra un Dock (DockDrop.hover): quale, sulla barra di che schermo (ogni schermo ha il suo Dock, con lo
// stesso id), dove cadrebbe un rilascio (dropSpot) e se arrivano cartelle (allora fra le cartelle si apre il loro posto).
struct DockHover: Equatable {
    let dock: UUID
    let display: CGDirectDisplayID
    var spot: DockSpot
    var folders: Bool
}

// Il rilascio su una barra: uno solo, sul suo fondo (SideBarView), che non si muove mai sotto il puntatore. Prima ogni
// capsula aveva il suo: allungata e ricentrata dalla zona perché le si trascinava sopra, ne usciva da sola, tornava
// com'era e il puntatore ci rientrava (25/10, il Dock tremava). Il Dock sotto il puntatore e dove ci cadrebbe li dà
// `target`, sulle cornici a riposo (hoveredDock, dropSpot); fuori dai Dock non si lascia niente. Di quello che parte dal
// Dock solo la cartella, su un Dock con le Cartelle (dockTakes), e la sezione, in modifica, dove dice `section`
// (sectionTarget): dentro un Dock o fra i Dock.
struct DockDropDelegate: DropDelegate {
    let drop: DockDrop
    let display: CGDirectDisplayID   // lo schermo della barra
    let target: (CGPoint) -> (box: DockBox, spot: DockSpot)?
    var section: (CGPoint) -> SectionTarget? = { _ in nil }

    func validateDrop(info: DropInfo) -> Bool { drop.source == nil || drop.moving != nil || drop.movingSection != nil }

    // Dal Finder quello che porta si sa solo dopo, fuori dal main: intanto vale come preso.
    func dropEntered(info: DropInfo) {
        drop.carried = nil
        if drop.source == nil { drop.overBar = true }
        aim(info.location)
        guard drop.source == nil else { return }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            let carried = await carries(providers)
            drop.carried = carried
            drop.hover?.folders = carried.folders
        }
    }

    // Dal Finder è una copia: chi trascina non perde mai il suo file (e qui si tiene solo il riferimento). Una cartella
    // del Dock cambia solo posto. Quello che il Dock sotto rifiuta torna indietro.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if drop.movingSection != nil { return DropProposal(operation: aimSection(info.location) ? .move : .cancel) }
        guard let box = aim(info.location) else { return DropProposal(operation: .cancel) }
        return DropProposal(operation: drop.refuses(box) ? .forbidden : drop.moving != nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) { leave() }

    // Il Dock sotto il puntatore, e intanto il trascinamento sopra di lui: cambiato solo se cambia (se no a ogni movimento
    // si ridisegnerebbe la barra).
    @discardableResult private func aim(_ p: CGPoint) -> DockBox? {
        if drop.movingSection != nil { aimSection(p); return nil }
        let t = target(p)
        let hover = t.map { DockHover(dock: $0.box.id, display: display, spot: $0.spot,
                                      folders: drop.moving != nil || drop.carried?.folders == true) }
        if drop.hover != hover { drop.hover = hover }
        return t?.box
    }

    // La sezione in mano: il posto si apre dove cadrebbe (DockDrop.room), cambiato solo se cambia. Vero se lì può cadere.
    @discardableResult private func aimSection(_ p: CGPoint) -> Bool {
        let t = section(p)
        let hover = t.flatMap(drop.room).map { SectionHover(target: $0, display: display) }
        if drop.sectionHover != hover { drop.sectionHover = hover }
        return t != nil
    }

    private func leave() {
        drop.hover = nil
        drop.overBar = false
        drop.sectionHover = nil
    }

    // Il posto aperto si chiude quando le voci sono già al loro posto, nella stessa animazione.
    func performDrop(info: DropInfo) -> Bool {
        if drop.movingSection != nil {
            let t = section(info.location)
            if let t { drop.dropped(at: t) }
            leave()
            return t != nil
        }
        guard let t = target(info.location), !drop.refuses(t.box) else { leave(); return false }
        guard drop.moving == nil else {
            drop.dropped(at: t.spot)
            leave()
            return true
        }
        // Le cartelle dove dice il posto (dropSpot), i file dove li manda dockDropRule: senza Mensola restano fuori.
        let files = dockDropRule(hasFolders: t.box.hasFolders, hasShelf: t.box.hasShelf, carriesFolders: false,
                                 carriesFiles: true).filesTo
        let providers = info.itemProviders(for: [.fileURL])
        drop.inserting += 1   // intanto il battito (dragTick) non spegne il posto aperto
        Task { @MainActor in
            await drop.settings.dropOnDock(await fileURLs(providers), at: t.spot, shelf: files != nil)
            drop.inserting -= 1
            leave()
        }
        return true
    }
}

// Quello che si vede in quel punto della finestra, anche sotto la vista (la sezione sotto SectionMenuView): l'immagine che
// segue il puntatore.
private func snapshot(_ view: NSView) -> NSImage? {
    guard let root = view.window?.contentView else { return nil }
    let rect = view.convert(view.bounds, to: root)
    guard let rep = root.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    root.cacheDisplay(in: rect, to: rep)
    let image = NSImage(size: rect.size)
    image.addRepresentation(rep)
    return image
}

// Se fra quello che arriva ci sono cartelle (alias e link compresi, dockDropSplit) e file: async non isolata, quindi
// fuori dal main, come gli URL.
private func carries(_ providers: [NSItemProvider]) async -> (folders: Bool, files: Bool) {
    let split = dockDropSplit(await fileURLs(providers), onShelf: false)
    return (!split.folders.isEmpty, !split.shelf.isEmpty)
}

// Cartelle e file del rilascio (dockDropSplit), ognuno col suo segnalibro: leggono il disco, quindi async non isolata,
// fuori dal main come carries. Una voce che non si registra (sparita nel frattempo) non c'è, e non prende un posto.
private func dockDropItems(_ urls: [URL], onShelf: Bool) async -> (folders: [DockItem], shelf: [DockItem]) {
    let split = dockDropSplit(urls, onShelf: onShelf)
    return (split.folders.compactMap(makeDockItem), split.shelf.compactMap(makeDockItem))
}

// Gli URL dei file trascinati, nell'ordine del trascinamento: NSItemProvider li dà fuori dal main, uno per voce.
private func fileURLs(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers {
        let url = await withCheckedContinuation { done in _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) } }
        if let url, url.isFileURL { urls.append(url) }
    }
    return urls
}
