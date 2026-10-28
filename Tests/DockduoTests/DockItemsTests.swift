import AppKit
import Testing
@testable import Dockduo

// Solo cartelle temporanee e suite nuove: mai file veri dell'autore.
private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-items-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func file(_ dir: URL, _ name: String, _ text: String = "ciao") -> URL {
    let u = dir.appendingPathComponent(name); try! text.write(to: u, atomically: true, encoding: .utf8); return u
}
private func folder(_ dir: URL, _ name: String) -> URL {
    let u = dir.appendingPathComponent(name); try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
}
private func real(_ u: URL?) -> String? { u?.resolvingSymlinksInPath().path }
// Il giro del Poller (resolveDockItemsInBackground) senza la coda: stessa risoluzione e stessa fusione, sul posto. E
// aggiungere per URL come un rilascio (dockDropItems) senza la divisione: il segnalibro qui, poi l'inserimento vero.
extension Settings {
    func refreshDockItems() { publishResolved(dockFolders.map(resolve), dockShelf.map(resolve)) }
    @discardableResult func addFolder(_ url: URL, at index: Int) -> Int? { makeDockItem(url).map { addFolder($0, at: index) } }
    func addToShelf(_ urls: [URL]) { addToShelf(urls.compactMap(makeDockItem)) }
}

@Test func foldersAddMoveAndDedupe() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let a = folder(root, "a"), b = folder(root, "b"), c = folder(root, "c")
    s.addFolder(a, at: 0); s.addFolder(b, at: 1); s.addFolder(c, at: 99)
    #expect(s.dockFolders.map { real($0.url) } == [a, b, c].map { real($0) })
    s.addFolder(c, at: 0)   // già presente: si sposta, non raddoppia
    #expect(s.dockFolders.map { real($0.url) } == [c, a, b].map { real($0) })
    let idA = s.dockFolders[1].id
    s.moveFolder(id: idA, to: 0)
    #expect(s.dockFolders.map { real($0.url) } == [a, c, b].map { real($0) })
    s.removeFolder(id: idA)
    #expect(s.dockFolders.count == 2)
}

@Test func shelfAddAndDedupe() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let f1 = file(root, "1.txt"), f2 = file(root, "2.txt")
    s.addToShelf([f1, f2, f1])
    s.addToShelf([f2])
    #expect(s.dockShelf.map { real($0.url) } == [f1, f2].map { real($0) })
    s.removeFromShelf(id: s.dockShelf[0].id)
    #expect(s.dockShelf.count == 1)
}

@Test func aMovedFileStillResolves() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let f = file(root, "old.txt")
    let item = makeDockItem(f)!
    let moved = root.appendingPathComponent("new.txt")
    try! FileManager.default.moveItem(at: f, to: moved)
    let r = resolve(item)
    #expect(real(r.url) == real(moved) && !r.hidden)
}

// Una voce si toglie quando il file se n'è andato davvero: nel Cestino, o cancellato con la sua cartella che si legge.
// Quando la cartella non si raggiunge (qui chiusa, come una condivisione montata ma muta dopo il risveglio) resta, nascosta,
// e torna quando torna il percorso. Dopo il giro nessuna conta come "non ancora letta" (url nil e non nascosta) per la
// capsula della barra vuota (emptyBarCapsuleShows).
@Test func onlyAGoneFileRemovesAnItem() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let locked = folder(root, "locked")
    let gone = file(root, "gone.txt"), trashed = file(root, "trashed.txt"), kept = file(root, "kept.txt"), far = file(locked, "far.txt")
    s.addToShelf([gone, trashed, kept, far])
    try! FileManager.default.removeItem(at: gone)
    let trash = folder(root, ".Trashes")
    try! FileManager.default.moveItem(at: trashed, to: trash.appendingPathComponent("trashed.txt"))
    try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    s.refreshDockItems()
    #expect(s.dockShelf.map { real($0.url) } == [real(kept), nil] && s.dockShelf.map(\.hidden) == [false, true])
    #expect(!s.dockShelf.contains { $0.url == nil && !$0.hidden })
    #expect(Settings(defaults: d).dockShelf.count == 2)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    s.refreshDockItems()
    #expect(s.dockShelf.map { real($0.url) } == [real(kept), real(far)] && s.dockShelf.allSatisfy(\.shown))
}

@Test func dropSplitSendsAppsAndFilesToTheShelf() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let dir = folder(root, "dir"), app = folder(root, "Foo.app"), f = file(root, "f.txt")
    // Una cartella .app è un pacchetto solo se ha un Info.plist.
    try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try! "<plist/>".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    let split = dockDropSplit([dir, app, f], onShelf: false)
    #expect(split.folders == [dir] && split.shelf == [app, f])
    let all = dockDropSplit([dir, app, f], onShelf: true)
    #expect(all.folders.isEmpty && all.shelf == [dir, app, f])
}

@Test func removingAnItemNeverTouchesTheFile() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let f = file(root, "keep.txt", "contenuto"), dir = folder(root, "dir")
    let inside = file(dir, "inner.txt", "dentro")
    s.addToShelf([f]); s.addFolder(dir, at: 0)
    s.removeFromShelf(id: s.dockShelf[0].id); s.removeFolder(id: s.dockFolders[0].id)
    s.refreshDockItems()
    #expect(try! String(contentsOf: f, encoding: .utf8) == "contenuto")
    #expect(try! String(contentsOf: inside, encoding: .utf8) == "dentro")
}

@Test func itemsSurviveANewSettings() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let dir = folder(root, "dir"), f = file(root, "f.txt")
    s.addFolder(dir, at: 0); s.addToShelf([f])
    let t = Settings(defaults: d)
    #expect(t.dockFolders.map(\.id) == s.dockFolders.map(\.id) && t.dockShelf.map(\.id) == s.dockShelf.map(\.id))
    // Caricate ma non ancora risolte (all'avvio il disco non si tocca sul main): il refresh le risolve.
    #expect(t.dockFolders[0].url == nil && t.dockShelf[0].url == nil)
    // Non ancora risolte si riconoscono dal percorso registrato nel segnalibro (senza toccare il disco): niente doppioni.
    t.addToShelf([f]); t.addFolder(dir, at: 1)
    #expect(t.dockShelf.count == 1 && t.dockFolders.count == 1 && t.dockFolders[0].url == nil)
    t.refreshDockItems()
    #expect(real(t.dockFolders[0].url) == real(dir) && real(t.dockShelf[0].url) == real(f))
}

@Test func aStaleBookmarkIsWrittenBack() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let f = file(root, "old.txt")
    s.addToShelf([f])
    let before = s.dockShelf[0].bookmark
    try! FileManager.default.moveItem(at: f, to: root.appendingPathComponent("new.txt"))
    s.refreshDockItems()
    #expect(s.dockShelf[0].bookmark != before)
    #expect(Settings(defaults: d).dockShelf[0].bookmark == s.dockShelf[0].bookmark)
}

@Test func aLinkToAFolderCountsAsAFolder() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let dir = folder(root, "dir"), link = root.appendingPathComponent("link")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
    #expect(dockDropSplit([link], onShelf: false).folders == [link])
}

// Trascinare sul Dock e dal Dock (spec dock §2, §3, §5; DockDrop.swift).

// Fra le cartelle si cade prima di tutte quelle col centro sotto il puntatore: sopra le app o sulla linea la prima, sotto
// l'ultima in fondo. Il passo del Dock: 31 + 2.
@Test func dropIndexBetweenFolders() {
    let frames = (0..<3).map { CGRect(x: 7, y: 100 + 33 * CGFloat($0), width: 31, height: 31) }
    #expect(folderDropIndex(y: 10, folderFrames: frames) == 0)       // sulle app
    #expect(folderDropIndex(y: 110, folderFrames: frames) == 0)      // metà alta della prima
    #expect(folderDropIndex(y: 120, folderFrames: frames) == 1)      // metà bassa della prima
    #expect(folderDropIndex(y: 165, folderFrames: frames) == 2)
    #expect(folderDropIndex(y: 500, folderFrames: frames) == 3)      // sotto l'ultima
    #expect(folderDropIndex(y: 50, folderFrames: []) == 0)
}

// Dalla cima della prima voce della mensola in giù è la mensola; sopra, fra le cartelle davanti a quella dell'indice
// (in fondo: nessuna). Una cartella del Dock che cambia posto (shelfTop nil) resta sempre fra le cartelle.
@Test func aDropSpotIsTheShelfOrBeforeAFolder() {
    let a = UUID(), b = UUID()
    let folders = [(id: a, frame: CGRect(x: 7, y: 100, width: 31, height: 31)), (id: b, frame: CGRect(x: 7, y: 133, width: 31, height: 31))]
    #expect(dockSpot(y: 20, folders: folders, shelfTop: 166) == .folders(before: a))
    #expect(dockSpot(y: 140, folders: folders, shelfTop: 166) == .folders(before: b))
    #expect(dockSpot(y: 160, folders: folders, shelfTop: 166) == .folders(before: nil))
    #expect(dockSpot(y: 166, folders: folders, shelfTop: 166) == .shelf)
    #expect(dockSpot(y: 300, folders: folders, shelfTop: nil) == .folders(before: nil))
    #expect(dockSpot(y: 20, folders: [], shelfTop: 100) == .folders(before: nil))
}

// Il rilascio: le cartelle nel posto, una dopo l'altra; i file e le app sulla mensola; una cartella già nel Dock si sposta
// (anche più giù di dov'era), non raddoppia; sulla mensola va tutto, cartelle comprese. Nessun file si muove.
@MainActor @Test func aDropOnTheDockPutsFoldersInPlaceAndTheRestOnTheShelf() async {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let a = folder(root, "a"), b = folder(root, "b"), c = folder(root, "c"), e = folder(root, "e"), f = file(root, "f.txt")
    let app = folder(root, "Foo.app")
    try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try! "<plist/>".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    s.addFolder(a, at: 0); s.addFolder(b, at: 1)
    let idB = s.dockFolders[1].id
    await s.dropOnDock([c, f, e, app], at: .folders(before: idB))
    #expect(s.dockFolders.map { real($0.url) } == [a, c, e, b].map { real($0) })
    #expect(s.dockShelf.map { real($0.url) } == [f, app].map { real($0) })
    await s.dropOnDock([a], at: .folders(before: idB))   // c'era già, più su: va davanti a b, non raddoppia
    #expect(s.dockFolders.map { real($0.url) } == [c, e, a, b].map { real($0) })
    await s.dropOnDock([b], at: .folders(before: nil))
    #expect(s.dockFolders.map { real($0.url) } == [c, e, a, b].map { real($0) })
    let g = folder(root, "g")
    await s.dropOnDock([g, f], at: .shelf)
    #expect(s.dockFolders.count == 4 && s.dockShelf.map { real($0.url) } == [f, app, g].map { real($0) })
    #expect(try! String(contentsOf: f, encoding: .utf8) == "ciao" && FileManager.default.fileExists(atPath: g.path))
}

// Review Focus 4 (spec dock-contenitori §6): un Dock prende un rilascio solo se ha Cartelle o Mensola. Le cartelle vanno
// fra le sue Cartelle (il posto preciso lo dà dockSpot), se non ci sono sulla sua Mensola; i file sulla sua Mensola, se
// non c'è da nessuna parte: di un rilascio misto restano le cartelle, uno di soli file è rifiutato. Nessun file si muove.
@MainActor @Test func dropsFollowTheDocksSections() async {
    let among = DockSpot.folders(before: nil)
    // Cartelle e Mensola del Dock, cartelle e file nel rilascio → lo prende, dove vanno le cartelle, dove i file.
    let cases: [(Bool, Bool, Bool, Bool, Bool, DockSpot?, DockSpot?)] = [
        (false, false, true, false, false, nil, nil),
        (false, false, false, true, false, nil, nil),
        (false, false, true, true, false, nil, nil),
        (true, false, true, false, true, among, nil),
        (true, false, false, true, false, nil, nil),
        (true, false, true, true, true, among, nil),
        (false, true, true, false, true, .shelf, nil),
        (false, true, false, true, true, nil, .shelf),
        (false, true, true, true, true, .shelf, .shelf),
        (true, true, true, false, true, among, nil),
        (true, true, false, true, true, nil, .shelf),
        (true, true, true, true, true, among, .shelf),
    ]
    for c in cases {
        let rule = dockDropRule(hasFolders: c.0, hasShelf: c.1, carriesFolders: c.2, carriesFiles: c.3)
        #expect(rule.accept == c.4 && rule.foldersTo == c.5 && rule.filesTo == c.6, "\(c)")
    }
    // Il posto (dockSpot): in un Dock senza Cartelle sempre la mensola, anche sopra la sua prima voce (nel margine della
    // capsula), mai fra le cartelle di un altro Dock; con le Cartelle lì si va in cima alle cartelle.
    #expect(dockSpot(y: 3, folders: nil, shelfTop: 7) == .shelf && dockSpot(y: 3, folders: nil, shelfTop: nil) == .shelf)
    #expect(dockSpot(y: 3, folders: [], shelfTop: 7) == among)
    // Su un Dock senza Mensola: del rilascio misto restano le cartelle, di quello di soli file niente; i file veri restano.
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let a = folder(root, "a"), f = file(root, "f.txt", "contenuto"), inside = file(a, "inner.txt", "dentro")
    await s.dropOnDock([a, f], at: among, shelf: false)
    await s.dropOnDock([f], at: among, shelf: false)
    #expect(s.dockFolders.map { real($0.url) } == [real(a)] && s.dockShelf.isEmpty)
    #expect(try! String(contentsOf: f, encoding: .utf8) == "contenuto")
    #expect(try! String(contentsOf: inside, encoding: .utf8) == "dentro")
}

// Il Dock sotto un trascinamento sulla barra (DockDropDelegate) si decide sulle cornici a riposo, nello spazio "bar": quello
// che ce l'ha già lo tiene finché il puntatore sta nella sua cornice a riposo o in quella di adesso, anche allungato e
// ricentrato (i numeri del Dock che tremava, 25/10: da y 409 alto 249 a y 383,5 alto 300), e anche dove ora copre il
// vicino. Senza nessuno sotto conta solo quella a riposo. Lo prendono i Dock con Cartelle o Mensola; una cartella del Dock
// solo quelli con le Cartelle, un file della mensola nessuno.
@Test func theDockUnderADragKeepsItWhileItGrows() {
    let dock = DockBox(zone: .middle, sections: [.widget(.apps), .widget(.folders), .widget(.shelf)])
    let apps = DockBox(zone: .middle, sections: [.widget(.apps)]), shelf = DockBox(zone: .middle, sections: [.widget(.shelf)])
    let rest = CGRect(x: 3, y: 409, width: 45, height: 249), grown = CGRect(x: 3, y: 383.5, width: 45, height: 300)
    let resting = [dock.id: rest, apps.id: CGRect(x: 3, y: 300, width: 45, height: 100), shelf.id: CGRect(x: 3, y: 664, width: 45, height: 45)]
    let taking = [apps, dock, shelf].filter { dockTakes($0, from: nil) }.map(\.id)
    #expect(taking == [dock.id, shelf.id])
    func under(_ y: CGFloat, now: CGRect, hovered: UUID?) -> UUID? {
        hoveredDock(at: CGPoint(x: 26, y: y), docks: taking, resting: resting, current: resting.merging([dock.id: now]) { $1 },
                    hovered: hovered)
    }
    #expect(under(646.4, now: rest, hovered: nil) == dock.id && under(646.4, now: grown, hovered: dock.id) == dock.id)
    #expect(under(395, now: grown, hovered: dock.id) == dock.id && under(670, now: grown, hovered: dock.id) == dock.id)
    #expect(under(395, now: grown, hovered: nil) == nil && under(670, now: rest, hovered: nil) == shelf.id)
    #expect(under(380, now: grown, hovered: dock.id) == nil && under(690, now: grown, hovered: dock.id) == shelf.id)
    #expect(under(350, now: rest, hovered: nil) == nil)   // il Dock delle sole app, nella sua cornice
    // Accanto alla capsula, nel margine della barra, conta l'altezza (dal 25/10 la barra prende il trascinamento tutta).
    #expect(hoveredDock(at: CGPoint(x: 51, y: 646.4), docks: taking, resting: resting, current: resting, hovered: nil) == dock.id)
    #expect(hoveredDock(at: CGPoint(x: 0.5, y: 646.4), docks: taking, resting: resting, current: resting, hovered: nil) == dock.id)
    #expect([apps, dock, shelf].filter { dockTakes($0, from: .folder(UUID())) }.map(\.id) == [dock.id])
    #expect(![apps, dock, shelf].contains { dockTakes($0, from: .file(UUID())) })
}

// Dove cadrebbe il rilascio si decide sulle cornici a riposo delle voci (dropSpot): lo stesso puntatore dà lo stesso posto
// prima e dopo che il Dock si allunga e si ricentra; sulle cornici di adesso, salite di 25,5, cadrebbe dopo la seconda
// cartella (il secondo giro che poteva far tremare il Dock). La mensola vuota senza la sua casella a riposo comincia dove
// finisce il Dock a riposo: la casella lo allunga lì; con la casella a riposo (un Dock che si vede solo trascinando) dalla
// casella. La cartella del Dock che cambia posto mai sulla mensola.
@Test func theDropSpotStaysWhileTheDockGrows() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d), a = UUID(), b = UUID()
    s.dockFolders = [a, b].map { DockItem(id: $0, bookmark: Data(), url: URL(fileURLWithPath: "/"), hidden: false) }
    let box = DockBox(zone: .middle, sections: [.widget(.apps), .widget(.folders), .widget(.shelf)])
    let rest = CGRect(x: 3, y: 409, width: 45, height: 249), grown = CGRect(x: 3, y: 383.5, width: 45, height: 300)
    var resting = [box.id: rest, a: CGRect(x: 10, y: 580, width: 31, height: 31), b: CGRect(x: 10, y: 613, width: 31, height: 31)]
    func spot(_ y: CGFloat, moving: UUID? = nil) -> DockSpot { s.dropSpot(in: box, y: y, resting: resting, moving: moving) }
    #expect(spot(620) == .folders(before: b))
    #expect(hoveredDock(at: CGPoint(x: 26, y: 620), docks: [box.id], resting: resting, current: [box.id: grown], hovered: box.id) == box.id)
    #expect(spot(620) == .folders(before: b))   // allungato: le cornici a riposo sono quelle di prima
    let now = [a, b].map { (id: $0, frame: resting[$0]!.offsetBy(dx: 0, dy: grown.minY - rest.minY)) }
    #expect(dockSpot(y: 620, folders: now, shelfTop: nil) == .folders(before: nil))
    #expect(spot(657) == .folders(before: nil) && spot(658) == .shelf && spot(670, moving: a) == .folders(before: nil))
    resting[DockDrop.emptyShelf] = CGRect(x: 10, y: 646, width: 31, height: 31)
    #expect(spot(650) == .shelf)
    resting[DockDrop.emptyShelf] = .null   // la casella se n'è andata
    #expect(spot(650) == .folders(before: nil))
}

// Una cartella del Dock trascinata e rilasciata lontano dalle barre, dove nessun Dock la prende, esce dal Dock (solo il
// riferimento: la cartella resta dov'è); rilasciata accanto a una barra, anche su un Dock dell'altro schermo che non la
// prende, resta al suo posto; rilasciata su un Dock cambia posto. Un file della mensola trascinato fuori resta lì.
@Test func aFolderDraggedOffTheDockIsRemovedAndOneDroppedOnItMoves() {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let a = folder(root, "a"), b = folder(root, "b"), c = folder(root, "c"), f = file(root, "f.txt")
    for (i, u) in [a, b, c].enumerated() { s.addFolder(u, at: i) }
    s.addToShelf([f])
    let ids = s.dockFolders.map(\.id)
    let drop = DockDrop(settings: s)
    drop.bars = { [CGRect(x: 0, y: 0, width: 52, height: 1000), CGRect(x: 1000, y: 0, width: 52, height: 1000)] }   // due schermi
    drop.source = .folder(ids[0])
    #expect(drop.moving == ids[0])
    drop.dropped(at: .folders(before: ids[2]))   // fra b e c
    drop.ended(.move, at: CGPoint(x: 26, y: 500))
    #expect(s.dockFolders.map(\.id) == [ids[1], ids[0], ids[2]] && drop.source == nil)
    drop.source = .folder(ids[2])
    drop.ended([], at: CGPoint(x: 70, y: 500), cancelled: false)   // accanto alla barra: resta
    #expect(s.dockFolders.map(\.id) == [ids[1], ids[0], ids[2]] && drop.source == nil)
    drop.source = .folder(ids[2])
    drop.ended([], at: CGPoint(x: 1026, y: 500), cancelled: false)   // su un Dock senza Cartelle dell'altro schermo: resta
    #expect(s.dockFolders.map(\.id) == [ids[1], ids[0], ids[2]] && drop.source == nil)
    drop.source = .folder(ids[2])
    drop.ended([], at: CGPoint(x: 400, y: 500), cancelled: false)   // lontano: esce dal Dock
    #expect(s.dockFolders.map(\.id) == [ids[1], ids[0]] && FileManager.default.fileExists(atPath: c.path))
    // Un file della mensola: annullato resta; copiato con ⌥ resta; spostato (o allegato) esce dalla mensola. Il file vero
    // resta dov'è: lo muove chi lo riceve, qui nessuno.
    let shelfID = s.dockShelf[0].id
    drop.source = .file(shelfID)
    drop.ended([], at: CGPoint(x: 400, y: 500), copying: false, cancelled: false)
    #expect(s.dockShelf.count == 1 && drop.source == nil)
    drop.source = .file(shelfID)
    drop.ended(.copy, at: CGPoint(x: 400, y: 500), copying: true)
    #expect(s.dockShelf.count == 1 && drop.source == nil)
    drop.source = .file(shelfID)
    drop.ended(.move, at: CGPoint(x: 400, y: 500), copying: false)
    #expect(s.dockShelf.isEmpty && s.dockFolders.count == 2 && drop.source == nil && FileManager.default.fileExists(atPath: f.path))
}

// Si toglie solo oltre un passo del Dock (33 a barra 52) tutto attorno a ogni barra, e solo se nessun Dock l'ha presa.
@Test func aFolderIsRemovedOnlyFarFromTheBar() {
    let bar = CGRect(x: 100, y: 0, width: 52, height: 900), other = CGRect(x: 2000, y: 0, width: 52, height: 900)
    #expect(!folderDragRemoves([], at: CGPoint(x: 155, y: 400), bars: [bar]))   // nel margine accanto alla capsula
    #expect(!folderDragRemoves([], at: CGPoint(x: 184, y: 400), bars: [bar]))   // ancora entro un passo
    #expect(folderDragRemoves([], at: CGPoint(x: 186, y: 400), bars: [bar]))
    #expect(folderDragRemoves([], at: CGPoint(x: 60, y: 400), bars: [bar]))     // dall'altra parte, su uno schermo senza barra
    #expect(!folderDragRemoves([], at: CGPoint(x: 2026, y: 400), bars: [bar, other]))   // sulla barra dell'altro schermo
    #expect(folderDragRemoves([], at: CGPoint(x: 1000, y: 400), bars: [bar, other]))    // lontano da tutte e due
    #expect(!folderDragRemoves(.move, at: CGPoint(x: 400, y: 400), bars: [bar]))   // l'ha presa un Dock
}

// Una cartella che non si riesce a registrare (qui: una che non c'è) non prende un posto, così il rilascio non ne salta
// uno per le altre: davanti ad a vanno b e c attaccate. Una voce sparita non finisce nemmeno sulla mensola.
@MainActor @Test func aFolderThatCannotBeAddedTakesNoSlot() async {
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let a = folder(root, "a"), b = folder(root, "b"), c = folder(root, "c")
    s.addFolder(a, at: 0)
    #expect(s.addFolder(root.appendingPathComponent("non-c-e"), at: 0) == nil)
    await s.dropOnDock([b, root.appendingPathComponent("sparita"), c], at: .folders(before: s.dockFolders[0].id))
    #expect(s.dockFolders.map { real($0.url) } == [b, c, a].map { real($0) } && s.dockShelf.isEmpty)
}

// Fuori da dockduo nessuno può fare niente di una cartella del Dock (né spostarla, né copiarla, né buttarla): dentro
// cambia solo posto. Il file della mensola esce come dal Finder.
@Test func aDockFolderNeverLeavesDockduo() {
    let id = UUID()
    #expect(dockDragMask(.folder(id), .outsideApplication) == [])
    #expect(dockDragMask(.folder(id), .withinApplication) == .move)
    #expect(dockDragMask(.file(UUID()), .outsideApplication).isSuperset(of: [.copy, .move, .link, .generic]))
    #expect(dockDragMask(nil, .outsideApplication) == [])
}

// Il tasto destro su una voce del Dock (spec dock §2, §3): la cartella si toglie dal Dock, il file si apre, si mostra nel
// Finder o si toglie dalla mensola; in fondo, staccate, Modifica Dock… e le impostazioni. Togliere toglie quella voce e basta, nella sua
// lista, e il file vero resta com'è.
@MainActor @Test func theFolderAndShelfMenus() throws {
    _ = NSApplication.shared
    let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let a = folder(root, "a"), b = folder(root, "b"), f = file(root, "f.txt", "contenuto"), g = file(root, "g.txt")
    s.addFolder(a, at: 0); s.addFolder(b, at: 1); s.addToShelf([f, g])
    let folderMenu = DockItemMenuView(id: s.dockFolders[1].id, url: b, folder: true, settings: s)
    let fileMenu = DockItemMenuView(id: s.dockShelf[0].id, url: f, folder: false, settings: s)
    #expect(folderMenu.menu().items.map(\.title) == ["Remove from Dock", "", "Edit Dock…", "Settings"])
    #expect(fileMenu.menu().items.map(\.title) == ["Open", "Show in Finder", "Remove from Shelf", "", "Edit Dock…", "Settings"])
    #expect(folderMenu.menu().items[1].isSeparatorItem && fileMenu.menu().items[3].isSeparatorItem)
    func choose(_ view: DockItemMenuView, _ title: String) throws {
        let item = try #require(view.menu().items.first { $0.title == title })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }
    try choose(folderMenu, "Remove from Dock")
    #expect(s.dockFolders.map { real($0.url) } == [real(a)] && s.dockShelf.count == 2)
    try choose(fileMenu, "Remove from Shelf")
    #expect(s.dockShelf.map { real($0.url) } == [real(g)] && s.dockFolders.count == 1)
    #expect(try FileManager.default.fileExists(atPath: b.path) && String(contentsOf: f, encoding: .utf8) == "contenuto")
}
