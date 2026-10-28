import Foundation

// I Dock (spec 2026-10-25-dock-contenitori-design.md §1): la barra contiene solo Dock, ognuno in una zona con le sue
// sezioni in ordine; in una zona ne possono stare più, nell'ordine salvato. Una sezione sta al massimo in un Dock, ed
// esserci è essere acceso. Salvati in `dockduo.docks` (Settings).
struct DockBox: Equatable, Identifiable {
    var id = UUID()
    var zone: Zone
    var sections: [BarItem]
}

// Una sezione di un Dock: un widget, salvato col suo nome ("apps"). Le mascotte ("mascot:<uuid>") non ci sono più (spec
// dock-degli-agenti §5): il loro token, come ogni nome che non è un widget, lo scarta init.
enum BarItem: Hashable {
    case widget(WidgetID)

    init?(_ token: String) {
        guard let w = WidgetID(rawValue: token) else { return nil }
        self = .widget(w)
    }

    var token: String { switch self { case .widget(let w): w.rawValue } }
}

// Salvato con i token delle sezioni (BarItem.token), riletti attraverso upgradeToken: un token che questa versione non
// conosce si perde da solo, il Dock e gli altri si leggono.
extension DockBox: Codable {
    private enum CodingKeys: String, CodingKey { case id, zone, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        zone = try c.decode(Zone.self, forKey: .zone)
        sections = try c.decode([String].self, forKey: .sections).flatMap(upgradeToken).compactMap(BarItem.init)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(zone, forKey: .zone)
        try c.encode(sections.map(\.token), forKey: .sections)
    }
}

// Un token salvato (nelle zone di prima o in un Dock) come lo legge questa versione: una sezione che cambia nome o si
// divide aggiunge qui il suo caso. Il Dock di prima si divide nelle sue tre sezioni. Le sezioni che non ci sono più (app
// nascoste, ora, batteria, Wi‑Fi, volume, Bluetooth, Concentrazione, mascotte) le scarta BarItem.init.
func upgradeToken(_ token: String) -> [String] { token == "dock" ? ["apps", "folders", "shelf"] : [token] }
let statusTokens: Set<String> = ["clock", "battery", "wifi"]   // le pillole di prima che ora sono lo Stato

// Se le zone di prima avevano ora, batteria o Wi‑Fi (spec §7): i token come sono salvati, prima che la lettura li scarti.
func hadStatusPills(zones: [String: [String]]?) -> Bool {
    !statusTokens.isDisjoint(with: zones?.values.flatMap { $0 } ?? [])
}

// Lo Stato sta sempre da solo nel suo Dock (spec impostazioni-nel-dock, decisione 5): libero sullo sfondo, come l'iPhone Duo.
extension DockBox {
    var isStatus: Bool { sections == [.widget(.status)] }
}

// I Dock con lo Stato acceso (`statusElement`) che non sta ancora in nessuno: un Dock suo, prima di ogni altro in cima, dove
// stava l'elemento di prima (spec impostazioni-nel-dock §7). Già in un Dock, o spento, i Dock restano come sono.
func docksWithStatus(_ docks: [DockBox], statusElement: Bool) -> [DockBox] {
    let status = BarItem.widget(.status)
    guard statusElement, !docks.contains(where: { $0.sections.contains(status) }) else { return docks }
    return [DockBox(zone: .top, sections: [status])] + docks
}

// Le sezioni da rileggere subito dopo un cambio dei Dock (le accese da `old` a `new`): quelle appena accese, per la loro
// prima lettura (firstRead), e lo Stato anche appena spento, così batteria e Wi‑Fi si svuotano.
func sectionsToRead(old: Set<BarItem>, new: Set<BarItem>) -> Set<BarItem> {
    let status = BarItem.widget(.status)
    return new.subtracting(old).union(old.contains(status) && !new.contains(status) ? [status] : [])
}

// I Dock fatti dalle zone di prima (spec §7): uno per zona non vuota, dall'alto in basso, nello stesso ordine. La prima
// volta (nessuna zona salvata) solo il Dock, al centro (autore, 24/10): il resto si accende dalle Impostazioni.
func migratedDocks(zones: [String: [String]]?) -> [DockBox] {
    guard let zones else { return [DockBox(zone: .middle, sections: [.widget(.apps), .widget(.folders), .widget(.shelf)])] }
    let docks = Zone.allCases.map { DockBox(zone: $0, sections: (zones[$0.rawValue] ?? []).flatMap(upgradeToken).compactMap(BarItem.init)) }
    return uniqueSections(docks).filter { !$0.sections.isEmpty }
}

// I Dock salvati come li legge questa versione; nil se non si leggono. Uno che la lettura lascia senza sezioni (le sue non ci
// sono più, spec dock-degli-agenti §5) sparisce, come quando se ne toglie l'ultima (removing); vuoto resta solo quello
// salvato vuoto.
func readDocks(_ data: Data) -> [DockBox]? {
    struct Saved: Decodable { let sections: [String] }
    guard let docks = try? JSONDecoder().decode([DockBox].self, from: data),
          let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return nil }
    return zip(uniqueSections(docks), saved).filter { !$0.sections.isEmpty || $1.sections.isEmpty }.map(\.0)
}

// I doppioni (vince il primo, nell'ordine dei Dock) si scartano; i Dock restano.
func uniqueSections(_ docks: [DockBox]) -> [DockBox] {
    var seen = Set<BarItem>()
    return docks.map { box in
        var box = box
        box.sections = box.sections.filter { seen.insert($0).inserted }
        return box
    }
}

// Gli stessi Dock senza quella sezione. Il Dock che resta senza sezioni perché era l'ultima sparisce; uno salvato vuoto
// resta.
func removing(_ item: BarItem, from docks: [DockBox]) -> [DockBox] {
    docks.compactMap { box in
        guard box.sections.contains(item) else { return box }
        var box = box
        box.sections.removeAll { $0 == item }
        return box.sections.isEmpty ? nil : box
    }
}

// Dove va una sezione trascinata (spec impostazioni-nel-dock §2): dentro un Dock, al posto `index` fra le sue sezioni, o in
// un Dock nuovo tutto suo, al posto `index` fra i Dock della zona. Gli indici contano sezioni e Dock come si vedono, la
// trascinata compresa (oltre la fine = in fondo).
enum SectionTarget: Equatable {
    case into(dock: UUID, index: Int)
    case newDock(zone: Zone, index: Int)
}

// Dove va davvero: lo Stato non divide mai un Dock (decisione 5), quindi "dentro" un Dock dove starebbe con altre sezioni
// diventa un Dock nuovo al posto di quel Dock, subito prima. Il resto com'è.
func sectionLanding(_ item: BarItem, at target: SectionTarget, docks: [DockBox]) -> SectionTarget {
    guard case .into(let id, _) = target, let box = docks.first(where: { $0.id == id }) else { return target }
    let together = Set(box.sections + [item])
    guard together.contains(.widget(.status)), together.count > 1 else { return target }
    return .newDock(zone: box.zone, index: docks.filter { $0.zone == box.zone }.firstIndex { $0.id == id } ?? 0)
}

// Gli stessi Dock con la sezione al suo posto nuovo (sectionLanding): via da dov'era, e il Dock che lascia vuoto sparisce
// (removing); una che non era in nessun Dock (dalla galleria) entra e basta. Per i trascinamenti nella barra e dalla
// galleria (Settings.place). Un Dock che non c'è più: niente.
func sectionPlaced(_ item: BarItem, at target: SectionTarget, docks: [DockBox]) -> [DockBox] {
    switch sectionLanding(item, at: target, docks: docks) {
    case .into(let id, let index):
        guard let box = docks.first(where: { $0.id == id }) else { return docks }
        // La sezione davanti a cui va (nil = in fondo); davanti a sé vuol dire davanti a quella dopo.
        let before = box.sections.dropFirst(max(index, 0)).first { $0 != item }
        return docks.flatMap { b -> [DockBox] in
            guard b.id == id else { return removing(item, from: [b]) }
            var b = b
            b.sections.removeAll { $0 == item }
            b.sections.insert(item, at: before.flatMap(b.sections.firstIndex) ?? b.sections.count)
            return [b]
        }
    case .newDock(let zone, let index):
        let new = DockBox(zone: zone, sections: [item])
        return dockMoved(new.id, to: zone, index: index, docks: docks + [new]).flatMap { $0.id == new.id ? [$0] : removing(item, from: [$0]) }
    }
}

// Gli stessi Dock con quello spostato nella zona, fra i Dock di lì all'indice contato senza di lui (oltre la fine = in
// fondo): l'anteprima del ⌘-trascina, e moveDock al rilascio.
func dockMoved(_ id: UUID, to zone: Zone, index: Int, docks: [DockBox]) -> [DockBox] {
    guard var box = docks.first(where: { $0.id == id }) else { return docks }
    box.zone = zone
    var all = docks.filter { $0.id != id }
    let there = all.indices.filter { all[$0].zone == zone }
    let at = min(max(index, 0), there.count)
    all.insert(box, at: at < there.count ? there[at] : all.count)
    return all
}
