import Foundation

// Il catalogo della galleria (spec impostazioni-nel-dock §3): le categorie della sua barra laterale, sotto "Tutte", e le
// sezioni di ognuna, nell'ordine delle categorie. Crescono con le sezioni. `bundle`: la lingua (le prove leggono l'italiano
// da Resources).
enum SectionCategory: String, CaseIterable {
    case dock, workspaces, nowPlaying, status

    func name(_ bundle: Bundle = .main) -> String {
        switch self {
        case .dock: String(localized: "Dock", bundle: bundle)
        case .workspaces: String(localized: "Workspaces", bundle: bundle)
        case .nowPlaying: String(localized: "Now Playing", bundle: bundle)
        case .status: String(localized: "Status", bundle: bundle)
        }
    }

    // L'icona nella barra laterale, come quelle delle categorie del Centro di Controllo (In riproduzione e Batteria le sue).
    var symbol: String {
        switch self {
        case .dock: "dock.rectangle"; case .workspaces: WidgetID.workspaces.symbol
        case .nowPlaying: "waveform"; case .status: "battery.100percent"
        }
    }
}

struct CatalogEntry {
    let item: BarItem
    let category: SectionCategory
    let name: String
}

func sectionCatalog(_ bundle: Bundle = .main) -> [CatalogEntry] {
    func entry(_ w: WidgetID, _ category: SectionCategory, _ name: String) -> CatalogEntry {
        CatalogEntry(item: .widget(w), category: category, name: name)
    }
    return [
        entry(.apps, .dock, String(localized: "Open apps", bundle: bundle)),
        entry(.folders, .dock, String(localized: "Folders", bundle: bundle)),
        entry(.shelf, .dock, String(localized: "Shelf", bundle: bundle)),
        entry(.workspaces, .workspaces, String(localized: "AeroSpace workspaces", bundle: bundle)),
        entry(.nowPlaying, .nowPlaying, String(localized: "Now Playing", bundle: bundle)),
        entry(.status, .status, String(localized: "Time, battery and Wi‑Fi", bundle: bundle)),
    ]
}

// Quelle di una categoria (nil: tutte) che la ricerca trova nel nome o nella categoria, senza badare a maiuscole, accenti e
// trattini ("wifi" e "wi-fi" trovano "Wi‑Fi", col trattino che non va a capo).
func catalogShown(category: SectionCategory?, search: String, bundle: Bundle = .main) -> [CatalogEntry] {
    func folded(_ text: String) -> String { text.filter { !"-\u{2010}\u{2011}".contains($0) } }
    let words = folded(search.trimmingCharacters(in: .whitespaces))
    func finds(_ text: String) -> Bool { folded(text).range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    return sectionCatalog(bundle).filter { e in
        (category == nil || e.category == category) && (words.isEmpty || finds(e.name) || finds(e.category.name(bundle)))
    }
}

// Le caselle della galleria. Una sezione già in un Dock resta, attenuata con "nel Dock" sotto il nome, e non si trascina: si
// sposta dalla barra (spec §3: la galleria non cambia sotto le dita).
struct GalleryTile {
    let entry: CatalogEntry
    let inDock: Bool
}
func galleryTiles(_ entries: [CatalogEntry], settings: Settings) -> [GalleryTile] {
    entries.map { GalleryTile(entry: $0, inDock: settings.isOn($0.item)) }
}
