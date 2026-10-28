import Foundation

// Cartelle e mensola del Dock (spec dock §2, §3): solo RIFERIMENTI ai file (segnalibri). Dockduo non sposta, copia,
// cancella né rinomina mai un file dell'utente: togliere una voce toglie il riferimento e basta.
struct DockItem: Identifiable, Equatable {
    let id: UUID
    var bookmark: Data
    var url: URL?        // risolto adesso; nil se non ancora risolto o non raggiungibile
    var hidden: Bool     // non si raggiunge (volume smontato, rete muta, permesso negato): la voce torna quando torna il percorso
    var shown: Bool { url != nil && !hidden }   // nel Dock: risolta e raggiungibile
}

func makeDockItem(_ url: URL) -> DockItem? {
    // App non in sandbox: niente security scope.
    guard let data = try? url.bookmarkData() else { return nil }
    return DockItem(id: UUID(), bookmark: data, url: url, hidden: false)
}

// Cestino: quello dell'utente (~/.Trash, confrontato per percorso) e le .Trashes dei volumi esterni.
private func inTrash(_ url: URL, trashDirs: [URL] = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)) -> Bool {
    let p = url.resolvingSymlinksInPath().path
    return url.pathComponents.contains(".Trashes") || trashDirs.contains { p.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
}

// Il file non c'è più davvero: la sua ultima cartella nota si legge, sta sullo stesso volume del segnalibro, e lui lì non
// c'è. Una cartella che non si legge (volume smontato, condivisione muta, permesso negato) o su un altro volume (la voce era
// la radice di un volume smontato: /Volumes resta; o un'altra scheda con lo stesso nome: si confronta l'UUID del volume quando
// c'è, se no il suo percorso) non prova niente.
private func isGone(_ bookmark: Data) -> Bool {
    guard let v = URL.resourceValues(forKeys: [.pathKey, .volumeURLKey, .volumeUUIDStringKey], fromBookmarkData: bookmark),
          let path = v.path, let volume = v.volume else { return false }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    guard (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil,
          let here = try? parent.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey]), let parentVolume = here.volume
    else { return false }
    let sameVolume = if let a = v.volumeUUIDString, let b = here.volumeUUIDString { a == b }
        else { parentVolume.resolvingSymlinksInPath().path == volume.resolvingSymlinksInPath().path }
    return sameVolume && !FileManager.default.fileExists(atPath: path)
}

// Mai montare né chiedere password. Si butta una voce finita nel Cestino o il cui file non c'è più davvero (isGone); ogni
// altro errore (volume smontato, condivisione montata ma muta dopo il risveglio) la nasconde, e torna quando torna il percorso.
func resolve(_ item: DockItem) -> DockItem {
    var out = item
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
          FileManager.default.fileExists(atPath: url.path) else {
        out.url = nil
        out.hidden = !isGone(item.bookmark)   // sparito: url nil e non nascosta, publishResolved la butta
        return out
    }
    out.hidden = false
    guard !inTrash(url) else { out.url = nil; return out }   // url nil e non nascosta: publishResolved la butta
    out.url = url
    if stale, let fresh = try? url.bookmarkData() { out.bookmark = fresh }
    return out
}

// Chiave per i doppioni: percorso risolto (/var e /private/var sono lo stesso posto).
// shortcut: legge il disco sul thread principale (al rilascio, per i doppioni); con una condivisione di rete bloccata ma
// montata nel Dock il rilascio aspetta il suo timeout. Se serve: la chiave salvata nel DockItem, calcolata fuori dal main.
private func key(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().path }

// Risoluzione pigra (all'avvio non si tocca il disco sul main): le voci caricate hanno url nil finché
// `resolveDockItemsInBackground` non le risolve. I doppioni si guardano sull'url già noto o, se manca, sul percorso
// registrato nel segnalibro, che si legge senza toccare il disco: si guarda sul main. Una voce spostata può sfuggire.
private func known(_ item: DockItem) -> URL? {
    item.url ?? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: item.bookmark)?.path.map { URL(fileURLWithPath: $0) }
}

extension Settings {
    // Dove è finita. Una già nel Dock si sposta e resta lei (la voce nuova si butta). Il segnalibro si fa prima, fuori
    // dal main (dockDropItems).
    @discardableResult func addFolder(_ new: DockItem, at index: Int) -> Int {
        let k = key(new.url)
        var list = dockFolders
        let existing = list.firstIndex { key(known($0)) == k }
        let item = existing.map { list.remove(at: $0) } ?? new
        let at = slot(index, from: existing, in: list)
        list.insert(item, at: at)
        dockFolders = list
        return at
    }

    func moveFolder(id: UUID, to index: Int) {
        var list = dockFolders
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: slot(index, from: from, in: list))
        dockFolders = list
    }

    // L'indice è un posto della lista di prima (davanti alla cartella che c'era lì, come nel rilascio sul Dock): se la
    // cartella veniva da più su, tolta lei quel posto è uno più in alto. `list` è la lista senza di lei.
    private func slot(_ index: Int, from: Int?, in list: [DockItem]) -> Int {
        min(max(from.map { $0 < index ? index - 1 : index } ?? index, 0), list.count)
    }

    func removeFolder(id: UUID) { dockFolders.removeAll { $0.id == id } }

    func addToShelf(_ items: [DockItem]) {
        var list = dockShelf
        var seen = Set(list.compactMap { key(known($0)) })
        for item in items { if let k = key(item.url), seen.insert(k).inserted { list.append(item) } }
        dockShelf = list
    }

    func removeFromShelf(id: UUID) { dockShelf.removeAll { $0.id == id } }

    // Dopo l'avvio e poi dal Poller: risolve fuori dal main e pubblica sul main, solo per le voci ancora presenti.
    func resolveDockItemsInBackground(then done: @escaping () -> Void = {}) {
        let (f, s) = (dockFolders, dockShelf)
        DispatchQueue.global(qos: .utility).async {
            let rf = f.map(resolve), rs = s.map(resolve)
            DispatchQueue.main.async { self.publishResolved(rf, rs); done() }
        }
    }

    // Le voci risolte rimpiazzano quelle con lo stesso id: quelle nel Cestino o sparite si buttano, quelle che non si
    // raggiungono restano (nascoste), le aggiunte nel frattempo pure.
    func publishResolved(_ rf: [DockItem], _ rs: [DockItem]) {
        func merge(_ now: [DockItem], _ done: [DockItem]) -> [DockItem] {
            let byId = Dictionary(uniqueKeysWithValues: done.map { ($0.id, $0) })
            return now.compactMap { item in
                guard let r = byId[item.id] else { return item }
                return r.url != nil || r.hidden ? r : nil
            }
        }
        let f = merge(dockFolders, rf), s = merge(dockShelf, rs)
        if f != dockFolders { dockFolders = f }
        if s != dockShelf { dockShelf = s }
    }
}

func dockDropSplit(_ urls: [URL], onShelf: Bool) -> (folders: [URL], shelf: [URL]) {
    if onShelf { return ([], urls) }
    // Un pacchetto (.app, .key…) conta come file.
    // Un link o un alias a una cartella è una cartella.
    let isFolder: (URL) -> Bool = {
        let target = ((try? URL(resolvingAliasFileAt: $0, options: [.withoutUI, .withoutMounting])) ?? $0).resolvingSymlinksInPath()
        let v = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }
    return (urls.filter(isFolder), urls.filter { !isFolder($0) })
}

// Salvataggio come lista di { id, bookmark }; una voce illeggibile si scarta.
func encodeDockItems(_ items: [DockItem]) -> [[String: Any]] { items.map { ["id": $0.id.uuidString, "bookmark": $0.bookmark] } }
func decodeDockItems(_ raw: Any?) -> [DockItem] {
    (raw as? [[String: Any]] ?? []).compactMap {
        guard let id = ($0["id"] as? String).flatMap(UUID.init), let data = $0["bookmark"] as? Data else { return nil }
        return DockItem(id: id, bookmark: data, url: nil, hidden: false)   // da risolvere dopo, non qui
    }
}
