import AppKit
import SwiftUI

// Azioni del menu contestuale sulle icone (porting di sketchybar/helpers/apps/apps.m):
// nessun permesso richiesto, `terminate` chiede la chiusura come cmd+q.
func showApp(_ app: AppEntry) {
    guard let a = NSRunningApplication(processIdentifier: app.pid) else { return }
    a.unhide()            // il focus da solo non mostra un'app nascosta
    // Solo gli id positivi sono finestre di AeroSpace: le voci ridotte (negative) e le nascoste (0) attivano l'app.
    if app.windowID > 0 { focusWindow(id: app.windowID); return }
    // Senza una finestra da mettere a fuoco (nascosta, minimizzata, chiusa): il "reopen" del Dock.
    // activate() da un'app mai attiva viene rifiutato da macOS 14+.
    if let url = a.bundleURL { open(url.path) }
}

// Va alla finestra di una sessione: da Mostra finestra nel menu della sua app (spec sessioni §3). Un'attesa resta: l'app
// che si attiva la segna vista (markSeen, Poller) e l'anello resta giallo fermo finché l'agente aspetta (spec
// dock-degli-agenti §1).
func showSession(_ s: AgentSession) {
    if let app = place(of: s.id, in: state.reports.flatMap(\.apps) + state.hidden) { showApp(app) }
}

// Toglie delle sessioni e rifà la barra: Reimposta l'agente sull'icona (le sue sessioni) e su una sessione del suo menu (una).
func resetSessions(_ ids: [String]) {
    state.sessions = state.sessions.filter { !ids.contains($0.key) }
    poller.tick()
}

// Vista in overlay che al tasto destro apre `menu()` ancorato in basso a sinistra, come un sottomenu
// (.contextMenu di SwiftUI si apre dove sta il mouse). Esiste solo per il tasto destro: agli altri
// click è trasparente, così il tap SwiftUI sotto arriva.
class RightClickMenuView: NSView {
    func menu() -> NSMenu { NSMenu() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
    }
    override func rightMouseDown(with event: NSEvent) { pop() }
    func pop() { popUpFromBar(menu(), in: self) }
}

// Ogni tendina della barra si apre da qui, chiara o scura come la barra: col Mac (spec dock-degli-agenti §5), da sola.
// `refresh`: i menu che si aggiornano da aperti (Wi-Fi) lo ricevono ogni secondo. popUp blocca finché il menu è aperto,
// quindi il timer vive esattamente quanto il menu; modo .common: gira anche durante il tracking.
@MainActor func popUpFromBar(_ menu: NSMenu, in view: NSView, refresh: (() -> Void)? = nil) {
    let timer = refresh.map { r in Timer(timeInterval: 1, repeats: true) { _ in r() } }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
    // Il menu si apre accanto alla pillola, verso il centro dello schermo.
    let opensLeft = (view.window?.frame.midX ?? 0) > (view.window?.screen?.frame.midX ?? 0)
    BarHold.shared.menuOpen = true   // col nascondi automatico la barra resta fuori finché il menu è aperto
    menu.popUp(positioning: nil, at: menuOrigin(in: view.bounds, menuWidth: menu.size.width, opensLeft: opensLeft), in: view)
    BarHold.shared.menuOpen = false
    timer?.invalidate()
}

// Dove si apre un menu dalla barra di lato: verso il centro dello schermo, a 8 pt dall'icona.
func menuOrigin(in bounds: CGRect, menuWidth: CGFloat, opensLeft: Bool) -> NSPoint {
    NSPoint(x: opensLeft ? -menuWidth - 8 : bounds.maxX + 8, y: bounds.maxY)
}

// Mostra / Nascondi / Chiudi sull'icona di un'app.
struct AppMenu: NSViewRepresentable {
    let app: AppEntry
    func makeNSView(context: Context) -> AppMenuView { AppMenuView(app: app) }
    func updateNSView(_ view: AppMenuView, context: Context) { view.app = app }
}

// In cima le sessioni che l'app ospita e i limiti dei loro agenti (spec dock-degli-agenti §3: erano nel menu delle
// mascotte), poi le voci di sempre. Il menu è la fotografia di quando si apre: cambiare le voci a menu aperto lo impagina
// male, quindi la rete non tocca mai un menu aperto.
final class AppMenuView: RightClickMenuView {
    var app: AppEntry
    let state: BarState
    init(app: AppEntry, state: BarState = Dockduo.state) { (self.app, self.state) = (app, state); super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override func menu() -> NSMenu {
        let menu = NSMenu()
        addSessions(to: menu)
        menu.addItem(NSMenuItem(String(localized: "Show"), #selector(showIt), target: self))
        menu.addItem(NSMenuItem(String(localized: "Hide"), #selector(hideIt), target: self))
        // Il Finder non si chiude, come nel Dock di macOS: tiene la scrivania (autore, 25/10).
        if app.bundle != finderBundle { menu.addItem(NSMenuItem(String(localized: "Quit"), #selector(quitIt), target: self)) }
        // Claude Code non manda nessun hook quando lo interrompi tu: l'anello resterebbe finché non scade.
        if app.agent != nil {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(String(localized: "Reset agent"), #selector(resetAgent), target: self))
        }
        // Modifica Dock… e le impostazioni anche da qui (autore, 25/10), come in ogni menu della barra.
        addEditItems(to: menu, from: self)
        return menu
    }

    @objc private func showIt() { showApp(app) }
    @objc private func hideIt() { NSRunningApplication(processIdentifier: app.pid)?.hide() }
    @objc private func quitIt() { NSRunningApplication(processIdentifier: app.pid)?.terminate() }

    // Le sessioni che questa icona mostra, non tutte quelle dell'app: con due finestre, azzerare quella bloccata
    // spegneva anche l'attesa dell'altra (27/9).
    @objc private func resetAgent() { resetSessions(app.sessionIDs) }

    // Le sessioni di questa icona (sessionIDs: solo quelle che vivono qui) dalla più urgente (spec sessioni §2); poi la quota
    // degli account dei loro agenti presenti su questo Mac (Claude → account Claude, Codex → account ChatGPT): intestazione
    // come le reti del menu Wi-Fi, poi una riga con la barra sottile per finestra. Una sessione finita dopo l'ultimo giro
    // del Poller non c'è più. Staccate dalle voci di sempre.
    // ponytail: nessun tetto al numero di voci; da mettere se un elenco lungo capita davvero (spec sessioni, Fuori scopo)
    private func addSessions(to menu: NSMenu) {
        let mine = sessionsByUrgency(state.sessions.filter { app.sessionIDs.contains($0.key) })
        guard !mine.isEmpty else { return }
        for session in mine { menu.addItem(sessionItem(session)) }
        let q = QuotaCache.shared, agents = Set(mine.map(\.agent))
        for agent in Agent.allCases where agents.contains(agent) && accountAvailable(agent) {
            menu.addItem(.separator())
            let claude = agent == .claude
            let title = claude ? q.claudeTitle + " · " + q.status : q.codexTitle + " · " + q.codexStatus
            let row = AccountRow(icon: appIcon(bundle: claude ? "com.anthropic.claudefordesktop" : "com.openai.codex"),
                                 title: title, subtitle: claude ? q.email : q.codex?.email)
            menu.addItem(menuViewItem(NSHostingView(rootView: row), height: 40))
            let rows = claude ? q.claudeRows : q.codexRows
            for (label, w) in rows ?? [] { menu.addItem(menuViewItem(NSHostingView(rootView: QuotaRow(label: label, window: w)), height: 34)) }
            if rows == nil { menu.addItem(NSMenuItem(title: "—", action: nil, keyEquivalent: "")) }
        }
        menu.addItem(.separator())
    }

    // Voce standard di macOS con sottotitolo e sottomenu: Mostra finestra, Reimposta l'agente (scelta dell'autore, 27/9).
    private func sessionItem(_ s: AgentSession) -> NSMenuItem {
        let row = NSMenuItem(title: sessionTitle(s), action: nil, keyEquivalent: "")
        row.subtitle = sessionSubtitle(s)
        row.image = sessionIcon(s)
        let sub = NSMenu()
        for (title, action) in [(String(localized: "Show window"), #selector(showSessionItem(_:))),
                                (String(localized: "Reset agent"), #selector(resetSessionItem(_:)))] {
            let item = NSMenuItem(title, action, target: self)
            item.representedObject = s.id
            sub.addItem(item)
        }
        row.submenu = sub
        return row
    }

    // Si rilegge la sessione al clic: fra l'apertura e il clic può essere finita, scaduta o reimpostata.
    @objc private func showSessionItem(_ item: NSMenuItem) {
        if let id = item.representedObject as? String, let s = state.sessions[id] { showSession(s) }
    }
    @objc private func resetSessionItem(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { resetSessions([id]) }
    }
}

// Un account c'è su questo Mac: Claude sempre, come il predefinito di prima; ChatGPT se c'è la cartella di Codex, la regola
// di prima per accendere la sua quota (M3): chi usa solo Claude non trova un riquadro ChatGPT "non collegato".
func accountAvailable(_ a: Agent, codexInstalled: Bool = FileManager.default.fileExists(atPath: codexDir.path)) -> Bool {
    a == .claude || codexInstalled
}

// L'icona dell'app, se installata (tonda nella riga, come i cerchi del menu Wi-Fi); altrimenti un simbolo.
func appIcon(bundle: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
}

// Il nome dell'app come lo mostra il Finder, dal bundle id; nil se non è installata o il bundle id è vuoto.
func appName(bundle: String) -> String? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path) }
}

// Voce di una sessione nel menu della sua app (spec dock-degli-agenti §3): "Claude · siigil", sotto "In attesa · 2 min".
// Il menu è già quello dell'app, quindi accanto all'agente la cartella in cui lavora: distingue due sessioni nella stessa
// app (scelta mia, 26/10 notte). Senza cartella nota solo l'agente.
func sessionTitle(_ s: AgentSession) -> String {
    let folder = (s.cwd as NSString).lastPathComponent
    return folder.isEmpty || folder == "/" ? s.agent.rawValue : "\(s.agent.rawValue) · \(folder)"
}

func sessionSubtitle(_ s: AgentSession, now: Date = Date()) -> String {
    let state = switch s.state {
    case .waiting: String(localized: "Waiting")
    case .working: String(localized: "Working")
    case .done: String(localized: "Finished")
    }
    let secs = max(0, Int(now.timeIntervalSince(s.since)))   // orologio spostato indietro: "adesso", mai un'età negativa
    let age = secs < 60 ? String(localized: "now")
        : secs < 3600 ? String(localized: "\(secs / 60) min") : String(localized: "\(secs / 3600) h")
    return "\(state) · \(age)"
}

// L'icona della voce: l'app della sessione con l'anello del suo stato, come nella barra; senza app nota il cerchio grigio
// col simbolo bianco delle intestazioni delle quote (un simbolo nudo usciva nero, invisibile nel menu scuro).
@MainActor func sessionIcon(_ s: AgentSession) -> NSImage? {
    let icon = s.bundle.flatMap(appIcon(bundle:))
    let r = ImageRenderer(content: Group {
        if let icon { Image(nsImage: icon).resizable() } else { MenuRowIcon(symbol: "sparkles", active: false, size: 20) }
    }.frame(width: 20, height: 20).overlay { AgentRing(state: s.state) })
    r.scale = NSScreen.main?.backingScaleFactor ?? 2
    return r.nsImage
}

// Riga con icona, titolo e sottotitolo grigio, come le reti nel menu Wi-Fi di macOS.
struct AccountRow: View {
    let icon: NSImage?
    let title: String
    let subtitle: String?
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { MenuRowIcon(symbol: "sparkles", active: false) }
            }
            .frame(width: 26, height: 26).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, menuInset)
    }
}

// Una finestra di quota nel menu: "Last 5 hours  12 % · Resets in 4 h" e sotto la barra (rossa da esaurita).
private struct QuotaRow: View {
    let label: String
    let window: UsageWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quotaLine(label, window)).font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
            UsageBar(window: window).frame(height: 5)
        }
        .padding(.horizontal, menuInset)
    }
}

// La barra di una finestra di quota: blu, rossa da esaurita.
struct UsageBar: View {
    let window: UsageWindow
    var body: some View {
        GeometryReader { g in
            Capsule().fill(.primary.opacity(0.28))
                .overlay(alignment: .leading) {
                    Capsule().fill(window.utilization >= 95 ? Color.red : Color.accentColor)
                        .frame(width: g.size.width * min(1, window.utilization / 100))
                }
        }
    }
}

// Il tasto destro su una cartella o un file del Dock (spec dock §2, §3), come quello delle app: la cartella si toglie dal
// Dock; il file si apre, si mostra nel Finder o si toglie dalla mensola. Togliere toglie solo il riferimento: il file vero
// resta dov'è. In fondo, staccate, Modifica Dock… e le impostazioni (con acceso solo il Dock non c'è altro da cui aprirle).
struct DockItemMenu: NSViewRepresentable {
    let id: UUID
    let url: URL
    let folder: Bool
    func makeNSView(context: Context) -> DockItemMenuView { DockItemMenuView(id: id, url: url, folder: folder) }
    func updateNSView(_ view: DockItemMenuView, context: Context) { (view.id, view.url, view.folder) = (id, url, folder) }   // spostato o rinominato
}

final class DockItemMenuView: RightClickMenuView {
    var id: UUID
    var url: URL
    var folder: Bool
    private let settings: Settings
    init(id: UUID, url: URL, folder: Bool, settings: Settings = .shared) {
        (self.id, self.url, self.folder, self.settings) = (id, url, folder, settings)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func menu() -> NSMenu {
        let menu = NSMenu()
        if folder {
            menu.addItem(NSMenuItem(String(localized: "Remove from Dock"), #selector(remove), target: self))
        } else {
            menu.addItem(NSMenuItem(String(localized: "Open"), #selector(openIt), target: self))
            menu.addItem(NSMenuItem(String(localized: "Show in Finder"), #selector(showInFinder), target: self))
            menu.addItem(NSMenuItem(String(localized: "Remove from Shelf"), #selector(remove), target: self))
        }
        addEditItems(to: menu, from: self)
        return menu
    }

    // Con `open` come il resto della barra (System.swift): da un'app mai attiva NSWorkspace non porta davanti.
    @objc private func openIt() { open(url.path) }
    @objc private func showInFinder() { open("-R", url.path) }
    @objc private func remove() { folder ? settings.removeFolder(id: id) : settings.removeFromShelf(id: id) }
}
