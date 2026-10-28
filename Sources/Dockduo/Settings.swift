import Foundation
import ServiceManagement

// Impostazioni (spec 2026-09-21-siigil-impostazioni-design.md). I widget della barra (BarItem) sono le sezioni dei Dock
// (Docks.swift); uno che non è in nessun Dock è spento. Il Dock di prima è tre sezioni: app aperte, cartelle, mensola. Lo
// Stato (ora, batteria e Wi‑Fi) è una sezione che sta sempre in un Dock suo, da sola (DockBox.isStatus).
enum WidgetID: String, CaseIterable {
    case workspaces, apps, folders, shelf, nowPlaying, status
}

enum Side: String { case left, right }

// La larghezza della barra: in fondo le icone del Dock grandi quanto quelle del Dock di macOS al massimo sullo schermo
// dell'autore (cattura del 25/10, 3420 px: il disegno dell'icona 144 px = 72 pt; da noi è 25/52 della barra, quindi
// 72 × 52 / 25 ≈ 150). macOS arriverebbe a 128 di casella, ma ci sta solo se le icone stanno nello schermo; l'autore lo
// vuole come lo vede (25/10: «hai sbagliato la dimensione massima»).
let sideWidths: ClosedRange<Double> = 38...150

// Un numero salvato, riportato nei suoi limiti; assente o non numerico = il default.
func clamped(_ value: Double?, to range: ClosedRange<Double>, default fallback: Double) -> Double {
    guard let value else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}

// Dell'elenco delle mascotte salvato dalle versioni che le avevano (`dockduo.mascots`, JSON; spec dock-degli-agenti §5)
// solo quello che serve ai suoni degli agenti. La funzione è {"ai":{"agents":[…]}} o {"system":{"kinds":[…]}}.
private struct SavedMascotSounds: Decodable {
    let function: [String: [String: [String]]]
    let sounds: Bool
    let volume: Int   // 0…100
}

private func firstAIMascotSounds(_ data: Data?) -> (sounds: Bool, volume: Int)? {
    let all = data.flatMap { try? JSONDecoder().decode([SavedMascotSounds].self, from: $0) } ?? []
    return all.first { $0.function["ai"] != nil }.map { ($0.sounds, $0.volume) }
}

// Su UserDefaults con chiavi `dockduo.<nome>`; i default sono il comportamento di prima delle impostazioni.
// Scritta solo sul main, come BarState. `init(defaults:)` per i test; l'app usa `shared`.
@Observable final class Settings {
    static let shared = Settings(defaults: .standard)
    private let defaults: UserDefaults

    var showFrontAppName: Bool { didSet { defaults.set(showFrontAppName, forKey: "dockduo.showFrontAppName") } }
    var bigArtwork: Bool { didSet { defaults.set(bigArtwork, forKey: "dockduo.bigArtwork") } }   // In riproduzione: copertina grande nel menu
    // L'aspetto è uno solo, quello del Dock di macOS (spec dock-degli-agenti §5): stile, chiaro/scuro, vetro, carattere e
    // margine dal bordo non si scelgono più. Le loro chiavi (`dockduo.barStyle` e le altre, come `dockduo.cornerRadius`
    // prima) restano dove sono, non lette.
    var clockApp: String { didSet { defaults.set(clockApp, forKey: "dockduo.clockApp") } }   // bundle id dell'app che il click sull'ora attiva; vuoto = niente
    var quotaInterval: Int { didSet { defaults.set(quotaInterval, forKey: "dockduo.quotaInterval") } }   // minuti
    var setupDone: Bool { didSet { defaults.set(setupDone, forKey: "dockduo.setupDone") } }   // la finestra Benvenuto è stata chiusa almeno una volta (spec benvenuto §2)
    var setupSnapshot: [String: Bool] { didSet { defaults.set(setupSnapshot, forKey: "dockduo.setupSnapshot") } }   // ultima fotografia delle voci che un aggiornamento può rompere (Setup.swift)

    // La barra di lato (spec dockduo §3): il lato, la larghezza e i Dock nelle tre zone (spec dock-contenitori §1). Essere in
    // un Dock è essere acceso.
    var barSide: Side { didSet { defaults.set(barSide.rawValue, forKey: "dockduo.barSide") } }
    var sideWidth: Double { didSet { defaults.set(sideWidth, forKey: "dockduo.sideWidth") } }
    // Nascondi automaticamente (spec cartelle §4): tutta la barra esce dal bordo e torna col mouse, come il Dock di macOS.
    var autohide: Bool { didSet { defaults.set(autohide, forKey: "dockduo.autohide") } }
    var docks: [DockBox] { didSet { if let data = try? JSONEncoder().encode(docks) { defaults.set(data, forKey: "dockduo.docks") } } }

    // Cartelle e mensola del Dock: solo segnalibri (DockItems.swift).
    var dockFolders: [DockItem] { didSet { defaults.set(encodeDockItems(dockFolders), forKey: "dockduo.dock.folders") } }
    var dockShelf: [DockItem] { didSet { defaults.set(encodeDockItems(dockShelf), forKey: "dockduo.dock.shelf") } }
    // Il nome delle voci del Dock al passaggio del mouse (spec dock §5): da accendere (autore, 25/10: «mettilo opzionale»).
    var dockHoverNames: Bool { didSet { defaults.set(dockHoverNames, forKey: "dockduo.dockHoverNames") } }
    // I suoni degli agenti (spec dock-degli-agenti §4): "ti aspetta" e "ha finito" con la voce di sempre, la bollicina, al
    // volume 0…1 (Impostazioni › Suoni).
    var agentSounds: Bool { didSet { defaults.set(agentSounds, forKey: "dockduo.agentSounds") } }
    var agentVolume: Double { didSet { defaults.set(agentVolume, forKey: "dockduo.agentVolume") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Chiave assente = il default.
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "dockduo.\(key)") as? Bool ?? fallback }
        showFrontAppName = bool("showFrontAppName", true)
        bigArtwork = bool("bigArtwork", true)
        clockApp = defaults.string(forKey: "dockduo.clockApp") ?? "com.apple.iCal"
        quotaInterval = defaults.object(forKey: "dockduo.quotaInterval") as? Int ?? 5
        // I Dock salvati o, la prima volta, quelli fatti dalle zone di prima (migratedDocks; senza zone solo il Dock),
        // salvati subito: la vecchia chiave resta dov'è, non più letta. Le mascotte (non ci sono più), i doppioni e i Dock
        // rimasti così senza sezioni si scartano anche qui (readDocks). Dei Dock che qui non si leggono (una versione
        // futura) si tiene una copia, una volta sola: la barra intanto riparte dalle zone di prima, e il primo cambiamento
        // li sovrascrive.
        let zones = defaults.dictionary(forKey: "dockduo.side.zones") as? [String: [String]]
        let docksData = defaults.data(forKey: "dockduo.docks")
        let savedDocks = docksData.flatMap(readDocks)
        if let docksData, savedDocks == nil, defaults.object(forKey: "dockduo.docks.unreadable") == nil { defaults.set(docksData, forKey: "dockduo.docks.unreadable") }
        // Lo Stato era a parte, sopra i Dock, acceso da `dockduo.statusElement` (spec impostazioni-nel-dock §7): acceso, diventa
        // un Dock suo in cima e si salva coi Dock. La chiave si legge una volta e se ne va; senza, decidono ora, batteria e
        // Wi‑Fi delle zone di prima, solo quando i Dock si fanno adesso (spec dock-contenitori §7). Poi decidono i Dock.
        let status = defaults.object(forKey: "dockduo.statusElement") as? Bool ?? (docksData == nil && hadStatusPills(zones: zones))
        let boxes = docksWithStatus(savedDocks ?? migratedDocks(zones: zones), statusElement: status)
        docks = boxes
        if docksData == nil || status, let encoded = try? JSONEncoder().encode(boxes) { defaults.set(encoded, forKey: "dockduo.docks") }
        defaults.removeObject(forKey: "dockduo.statusElement")
        defaults.removeObject(forKey: "dockduo.settingsPane")   // la pagina della finestra delle impostazioni, che non c'è più (spec §6)
        barSide = Side(rawValue: defaults.string(forKey: "dockduo.barSide") ?? "") ?? .left
        sideWidth = clamped(defaults.object(forKey: "dockduo.sideWidth") as? Double, to: sideWidths, default: 52)
        autohide = bool("autohide", false)
        setupDone = bool("setupDone", false)
        setupSnapshot = defaults.dictionary(forKey: "dockduo.setupSnapshot") as? [String: Bool] ?? [:]
        dockFolders = decodeDockItems(defaults.object(forKey: "dockduo.dock.folders"))
        dockShelf = decodeDockItems(defaults.object(forKey: "dockduo.dock.shelf"))
        dockHoverNames = bool("dockHoverNames", false)
        // La prima volta i suoni degli agenti sono quelli della prima mascotte AI salvata (erano suoi), se no accesi a 35, e si
        // salvano subito: le mascotte si leggono solo finché manca una delle due chiavi, poi non decidono più. La loro chiave resta dov'è, non più letta.
        let first = defaults.object(forKey: "dockduo.agentSounds") == nil || defaults.object(forKey: "dockduo.agentVolume") == nil
        let mascot = first ? firstAIMascotSounds(defaults.data(forKey: "dockduo.mascots")) : nil
        agentSounds = bool("agentSounds", mascot?.sounds ?? true)
        agentVolume = clamped(defaults.object(forKey: "dockduo.agentVolume") as? Double ?? mascot.map { Double($0.volume) / 100 },
                              to: 0...1, default: 0.35)
        if defaults.object(forKey: "dockduo.agentSounds") == nil { defaults.set(agentSounds, forKey: "dockduo.agentSounds") }
        if defaults.object(forKey: "dockduo.agentVolume") == nil { defaults.set(agentVolume, forKey: "dockduo.agentVolume") }
    }

    func isOn(_ item: BarItem) -> Bool { docks.contains { $0.sections.contains(item) } }
    func isOn(_ w: WidgetID) -> Bool { isOn(.widget(w)) }

    // I Dock di una zona, nell'ordine salvato.
    func docks(in zone: Zone) -> [DockBox] { docks.filter { $0.zone == zone } }

    // Tolta l'ultima sezione di un Dock, il Dock sparisce con lei (removing).
    func removeSection(_ item: BarItem) { docks = removing(item, from: docks) }

    // Un Dock fra i Dock della zona (il ⌘-trascina): `index` conta senza lui, oltre la fine = in fondo.
    func moveDock(_ id: UUID, to zone: Zone, index: Int) { docks = dockMoved(id, to: zone, index: index, docks: docks) }
    // Una sezione lasciata sulla barra, in modifica: trascinata dalla barra o dalla galleria (sectionPlaced). Una appena
    // accesa ha la sua prima lettura da sola (main.swift, sectionsToRead).
    func place(_ item: BarItem, at target: SectionTarget) { docks = sectionPlaced(item, at: target, docks: docks) }

    // Avvio al login: lo stato vero è SMAppService, non UserDefaults; ma la scelta dell'utente va comunque su
    // defaults (`dockduo.launchAtLogin`), perché main.swift la legge per non registrare di nuovo chi l'ha spenta.
    // `launchAtLogin` rispecchia lo stato di sistema dopo ogni tentativo e quando si apre il sottomenu Impostazioni.
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    func setLaunchAtLogin(_ on: Bool) {
        defaults.set(on, forKey: "dockduo.launchAtLogin")   // scritta comunque: la scelta è dell'utente anche se SMAppService fallisce
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLogin()
        } catch {
            // refresh prima: se register()/unregister() fallisce ma lo stato risulta lo stesso .enabled di prima
            // (es. unregister fallito), refresh lo pulirebbe da solo; l'errore vero, scritto dopo, vince sempre.
            refreshLaunchAtLogin()
            launchAtLoginError = error.localizedDescription
        }
    }

    // Rilegge lo stato di sistema: può cambiare da Impostazioni di Sistema senza passare da qui (es. l'utente
    // approva dopo un .requiresApproval). Pulisce l'errore solo quando torna .enabled: altrimenti un errore
    // vero (register/unregister fallito) resterebbe visibile finché lo stato non si sistema davvero.
    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            launchAtLoginError = String(localized: "Approval required in System Settings › Login Items")
        } else if status == .enabled {
            launchAtLoginError = nil
        }
    }
}
