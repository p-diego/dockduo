import AppKit
import SwiftUI

// "Impostazioni ›" in fondo ai menu della barra (spec impostazioni-nel-dock §5): quello che non si modifica nella barra.
// In cima le voci della linea del Dock (dockLineItems: Nascondi, Posizione sullo schermo, Riduci usando), poi Agenti AI ›,
// Suoni ›, Apri al login, la versione con l'aggiornamento, Configurazione iniziale…, Informazioni e Esci. Le azioni sono
// quelle delle pagine di prima (Account AI, Generali). Il menu è la fotografia di quando si apre; solo lo stato degli hook
// arriva dopo, letto fuori dal main.
@MainActor func settingsMenuItem(settings: Settings = .shared, integrations: [Integration] = Dockduo.integrations,
                                 dock: UserDefaults? = UserDefaults(suiteName: "com.apple.dock")) -> NSMenuItem {
    let menu = NSMenu()
    dockLineItems(settings: settings, dock: dock).forEach(menu.addItem)
    menu.addItem(.separator())
    let agents = NSMenu()
    fillAgents(agents, statuses: [:], integrations: integrations, settings: settings)
    // I file degli hook si leggono fuori dal main all'apertura (la pagina di prima lo faceva alla comparsa), poi le voci si
    // rifanno: di solito prima che il sottomenu si apra.
    let fill: @MainActor ([String: IntegrationStatus]) -> Void = { fillAgents(agents, statuses: $0, integrations: integrations, settings: settings) }
    DispatchQueue.global().async {
        let statuses = integrationStatuses(integrations)
        DispatchQueue.main.async { fill(statuses) }
    }
    menu.addItem(submenuItem(String(localized: "AI Agents"), agents))
    menu.addItem(submenuItem(String(localized: "Sounds"), soundsMenu(settings)))
    settings.refreshLaunchAtLogin()   // può essere cambiato da Impostazioni di Sistema
    menu.addItem(ActionItem(String(localized: "Open at Login"), on: settings.launchAtLogin) { settings.setLaunchAtLogin(!settings.launchAtLogin) })
    if let e = settings.launchAtLoginError { menu.addItem(greyLine(e)) }
    menu.addItem(.separator())
    let updater = Updater.shared
    updateItems(updater.state, checkError: updater.checkError, current: updater.current).forEach(menu.addItem)
    menu.addItem(.separator())
    // Dopo la chiusura del menu, come Impostazioni… di prima: aperta durante il tracking la finestra s'impagina male.
    menu.addItem(ActionItem(String(localized: "Setup…")) { DispatchQueue.main.async { Editing.shared.opensWindow(); WelcomeWindow.shared.open() } })
    menu.addItem(.separator())
    menu.addItem(ActionItem(String(localized: "About dockduo")) {
        DispatchQueue.main.async { Editing.shared.opensWindow(); NSApp.activate(); NSApp.orderFrontStandardAboutPanel(nil) }
    })
    menu.addItem(ActionItem(String(localized: "Quit dockduo")) { NSApp.terminate(nil) })
    return submenuItem(String(localized: "Settings"), menu)
}

// L'errore dell'ultima azione di ogni agente (per id), finché un'azione su quell'agente non riesce: il menu si chiude col
// click, la riga grigia si vede alla prossima apertura.
@MainActor var agentErrors: [String: String] = [:]
// "Apri il Terminale" premuto: il riavvio di ChatGPT serve anche dopo l'approvazione (come nella pagina di prima).
@MainActor private var codexRestartPending = false

// Agenti AI ›: per ogni integrazione il nome, lo stato del collegamento con la sua azione, l'errore dell'ultima azione e
// l'account; in fondo ogni quanto si aggiornano i limiti. `statuses` vuoto: ancora da leggere, niente stato. Dal DMG
// (`fromDiskImage`) niente Collega né Aggiorna: gli hook punterebbero dentro il disco immagine.
@MainActor func fillAgents(_ menu: NSMenu, statuses: [String: IntegrationStatus], integrations: [Integration], settings: Settings,
                           fromDiskImage: Bool = launchedFromDiskImage(Bundle.main.bundlePath)) {
    menu.removeAllItems()
    for i in integrations {
        let status = statuses[i.id]
        func act(_ title: String, _ action: @escaping () throws -> Void) -> NSMenuItem {
            ActionItem(title) { i.run(action) { agentErrors[i.id] = $0 } }
        }
        menu.addItem(.sectionHeader(title: i.name))
        switch status {
        case .installed?:
            menu.addItem(greyLine(String(localized: "Connected"), on: true))
            menu.addItem(act(String(localized: "Disconnect"), i.remove))
        case .needsApproval?: menu.addItem(act(String(localized: "Disconnect"), i.remove))   // installato, da approvare
        case .outdated?, .notInstalled?:
            menu.addItem(fromDiskImage ? greyLine(String(localized: "Move dockduo to Applications first"))
                : act(status == .outdated ? String(localized: "Update Connection") : String(localized: "Connect"), i.install))
        case .missing(let m)?: menu.addItem(greyLine(m))
        case nil: break
        }
        if i.id == "codex", status == .needsApproval || codexRestartPending {
            menu.addItem(ActionItem(String(localized: "Open Terminal")) { openCodexTerminal(); codexRestartPending = true })
            menu.addItem(ActionItem(String(localized: "Restart ChatGPT")) { restartChatGPT(); codexRestartPending = false })
        }
        if status == .needsApproval { menu.addItem(greyLine(String(localized: "Approve once: /hooks → Trust"))) }
        if let e = agentErrors[i.id] { menu.addItem(greyLine(e)) }
        if let a = accountLine(i.id) { menu.addItem(greyLine(a)) }
        menu.addItem(.separator())
    }
    let every = NSMenu()
    for m in [5, 10, 15, 30] {
        every.addItem(ActionItem(String(localized: "\(m) min"), on: settings.quotaInterval == m) { settings.quotaInterval = m })
    }
    menu.addItem(submenuItem(String(localized: "Refresh limits every"), every))
}

// L'account di un agente come nell'intestazione della pagina di prima: piano · mail, o lo stato finché la quota non risponde.
@MainActor func accountLine(_ id: String) -> String? {
    let q = QuotaCache.shared
    switch id {
    case "claude-code": return q.claudeTitle + " · " + (q.email ?? q.status)
    case "codex": return q.codexTitle + " · " + (q.codex?.email ?? q.codexStatus)
    default: return nil
    }
}

// Suoni ›: l'interruttore, il volume come cursore dentro il menu, Prova ("ti aspetta" e poi "ha finito"). Da spenti il
// cursore e Prova non si usano, come nella pagina di prima.
@MainActor private func soundsMenu(_ settings: Settings) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionItem(String(localized: "Agent Sounds"), on: settings.agentSounds) { settings.agentSounds.toggle() })
    menu.addItem(menuViewItem(NSHostingView(rootView: VolumeRow(settings: settings)), height: 28))
    let test = ActionItem(String(localized: "Try")) { tryAgentSounds(volume: settings.agentVolume) }
    test.isEnabled = settings.agentSounds
    menu.addItem(test)
    return menu
}

// Il volume degli agenti come il cursore del menu Suono di macOS, fra l'altoparlante piano e quello forte: 0…100 % a
// numeri interi (senza `step`, che disegna una tacca per valore), salvato 0…1.
struct VolumeRow: View {
    let settings: Settings
    var percent: Double { (settings.agentVolume * 100).rounded() }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
            Slider(value: Binding(get: { percent }, set: { settings.agentVolume = $0.rounded() / 100 }), in: 0...100)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.primary.opacity(0.55))   // esplicito: il "secondario" nei menu lo spegne la vibrancy
        .padding(.horizontal, menuInset)
        .disabled(!settings.agentSounds)
    }
}

// La versione in grigio con lo stato dell'aggiornamento, poi le azioni della card Informazioni di prima: da scaricare
// "Aggiorna alla…" e "Novità"; dopo un'installazione fallita il DMG; se no "Cerca aggiornamenti…".
@MainActor func updateItems(_ state: Updater.State, checkError: String?, current: String) -> [NSMenuItem] {
    let version = [String(localized: "Version \(current)"), updateStatus(state, checkError: checkError)].compactMap { $0 }
    var items = [greyLine(version.joined(separator: " · "))]
    switch state {
    case .available(let r):
        items.append(ActionItem(String(localized: "Update to \(r.version)")) { Task { await Updater.shared.install() } })
        items.append(ActionItem(String(localized: "What's New")) { DispatchQueue.main.async { NSWorkspace.shared.open(r.page) } })
    case .failed:
        items.append(ActionItem(String(localized: "Download the DMG")) { DispatchQueue.main.async { NSWorkspace.shared.open(latestReleasePage) } })
        fallthrough
    default:
        items.append(ActionItem(String(localized: "Check for Updates…")) { Task { await Updater.shared.check() } })
    }
    return items
}

// Scaricamento ed errore d'installazione prima di tutto; poi un controllo fallito; poi l'esito dell'ultimo controllo.
func updateStatus(_ state: Updater.State, checkError: String?) -> String? {
    switch (state, checkError) {
    case (.downloading(let r), _): String(localized: "Downloading \(r.version)…")
    case (.failed(let reason), _): String(localized: "Update failed: \(reason)")
    case (_, let e?): String(localized: "Couldn't check: \(e)")
    case (.upToDate, _): String(localized: "Up to date")
    case (.available(let r), _): String(localized: "\(r.version) is out")
    default: nil
    }
}

// Una voce con la sua azione in una chiusura: è il bersaglio di se stessa, e il menu la tiene viva.
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, on: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) non usato") }
    @objc private func fire() { run() }
}

// Una riga grigia di solo testo: una voce spenta, come le righe d'informazione dei menu di sistema.
private func greyLine(_ title: String, on: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.state = on ? .on : .off
    return item
}

func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
}
