import AppKit
import Observation

struct Battery: Equatable {
    let percent: Int
    let charging: Bool
    var lowPower = false   // Risparmio energetico: l'anello si tinge di giallo, come su iOS (autore, 4/10)
}

// Wi-Fi: acceso/spento, tacche 0...3 (0 = acceso ma non collegato) e VPN attiva (lucchetto sull'icona).
struct WiFi: Equatable {
    let on: Bool
    let bars: Int
    let vpn: Bool
}

@Observable
final class BarState {
    static let shared = BarState()   // quella dell'app (main.swift); le prove se ne fanno una loro
    var reports: [SpaceReport] = []
    var hidden: [AppEntry] = []      // app senza finestre visibili
    var dock: [AppEntry] = []        // il widget Dock: le app del Dock in ordine di apertura (dockApps); vuoto da spento
    var badges: [pid_t: String] = [:]   // il numero rosso di ogni app del Dock (Badges.swift); vuoto da spento
    var frontWindow: Int?    // id AeroSpace della finestra a fuoco: il nome dell'app compare accanto alla sua icona
    var battery: Battery?
    var wifi: WiFi?       // nil = nessuna interfaccia Wi-Fi, o l'elemento di stato spento
    var track: Track?        // "In riproduzione" (NowPlaying.swift); nil = niente o widget spento
    var trackRead = false    // la prima lettura di In riproduzione è tornata (riuscita o no): prima la barra non sa se la capsula vuota va
    var artwork: NSImage?    // la copertina della traccia, quando arriva
    var sessions: [String: AgentSession] = [:]   // sessioni di agenti AI per session_id (AgentServer)
    var spaceProblem: SpaceProblem?   // perché AeroSpace non fa posto alla barra (syncAerospaceGaps, Poller); nil = posto fatto
}

// La barra si nasconde (spec app conclusa §2.3): con Nascondi acceso, o da sola quando AeroSpace non le fa posto. L'unica
// regola per chi nasconde; Settings.autohide resta la scelta dell'utente, che lo spazio ritrovato rimette com'era.
@MainActor func barHides(_ s: Settings, _ state: BarState) -> Bool { s.autohide || state.spaceProblem != nil }
