import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Il sottomenu Impostazioni (spec impostazioni-nel-dock §5): si costruisce e si guardano le voci, senza aprirlo. Gli hook
// veri (~/.claude, ~/.codex) non si toccano: stati e azioni li danno integrazioni finte.

private struct Broken: LocalizedError { var errorDescription: String? { "broken" } }

@MainActor private func choose(_ item: NSMenuItem) { _ = (item.target as? NSObject)?.perform(item.action, with: item) }

// Le azioni degli agenti tornano sul main quando hanno finito: si aspetta il loro effetto, al massimo 2 s.
@MainActor private func waitFor(_ done: () -> Bool) async {
    for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

// Collega, aggiorna e scollega scrivono file: l'azione gira fuori dal main, l'esito torna sul main.
@MainActor @Test func agentActionsRunOffTheMainThread() async {
    nonisolated(unsafe) var offMain: Bool?
    let i = Integration(id: "x", name: "X", status: { .notInstalled }, install: { offMain = !Thread.isMainThread; throw Broken() }, remove: {})
    let (error, onMain) = await withCheckedContinuation { c in i.run(i.install) { c.resume(returning: ($0, Thread.isMainThread)) } }
    #expect(offMain == true && error == "broken" && onMain)
}

// Dall'alto: le voci della linea del Dock (autore, 28/10: «DEVE essere uguale»), Agenti AI ›, Suoni ›, Apri al login; la
// versione con le voci dell'aggiornamento; Configurazione iniziale…; Informazioni e Esci. Nascondi da qui accende il
// nascondi come dalla linea.
@MainActor @Test func theSettingsMenuHasEverything() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    let s = Dockduo.Settings(defaults: d)
    let item = settingsMenuItem(settings: s, integrations: [], dock: dock)
    let menu = try #require(item.submenu)
    let update: [String] = updateItems(Updater.shared.state, checkError: Updater.shared.checkError, current: Updater.shared.current).map(\.title)
    let line = ["Turn Hiding On", "Position on Screen", "Minimize Using"]
    let expected: [String] = line + ["", "AI Agents", "Sounds", "Open at Login", ""] + update + ["", "Setup…", "", "About dockduo", "Quit dockduo"]
    #expect(item.title == "Settings")
    #expect(menu.items.map(\.title) == expected)
    let fromLine = DockLineMenuView(settings: s, dock: dock, update: { .idle }).menu().items.prefix(3)
    #expect(menu.items.prefix(3).map { $0.submenu?.items.map(\.title) } == fromLine.map { $0.submenu?.items.map(\.title) })
    #expect(menu.items[4].submenu != nil && menu.items[5].submenu != nil)
    choose(menu.items[0])
    #expect(s.autohide)
}

// Per ogni agente il nome, lo stato del collegamento con la sua azione, l'errore dell'ultima azione e l'account; in fondo
// ogni quanto si aggiornano i limiti.
@MainActor @Test func theAgentsMenuFollowsTheHooks() async throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    nonisolated(unsafe) var removed = 0   // scritto dall'azione fuori dal main, letto dopo che l'esito è tornato sul main
    let claude = Integration(id: "claude-code", name: "Claude Code", status: { .installed }, install: {}, remove: { removed += 1 })
    let codex = Integration(id: "codex", name: "Codex", status: { .notInstalled }, install: { throw Broken() }, remove: {})
    agentErrors = [:]; defer { agentErrors = [:] }
    let menu = NSMenu()
    func titles(_ a: IntegrationStatus, _ b: IntegrationStatus) -> [String] {
        fillAgents(menu, statuses: ["claude-code": a, "codex": b], integrations: [claude, codex], settings: s)
        return menu.items.map(\.title)
    }
    let ca = try #require(accountLine("claude-code")), co = try #require(accountLine("codex"))
    let tail = ["", "Refresh limits every"]
    #expect(titles(.installed, .notInstalled) == ["Claude Code", "Connected", "Disconnect", ca, "", "Codex", "Connect", co] + tail)
    #expect(menu.items[0].isSectionHeader && menu.items[5].isSectionHeader)
    #expect(menu.items[1].state == .on && !menu.items[1].isEnabled && !menu.items[3].isEnabled)   // Collegato e l'account: grigie
    #expect(titles(.outdated, .needsApproval)
        == ["Claude Code", "Update Connection", ca, "", "Codex", "Disconnect", "Open Terminal", "Restart ChatGPT", "Approve once: /hooks → Trust", co] + tail)
    #expect(titles(.missing("Claude Code not found"), .missing("Codex not found"))
        == ["Claude Code", "Claude Code not found", ca, "", "Codex", "Codex not found", co] + tail)
    // Dal DMG gli hook punterebbero dentro il disco immagine: niente Collega né Aggiorna, la riga grigia al loro posto.
    fillAgents(menu, statuses: ["claude-code": .outdated, "codex": .notInstalled], integrations: [claude, codex], settings: s, fromDiskImage: true)
    let first = "Move dockduo to Applications first"
    #expect(menu.items.map(\.title) == ["Claude Code", first, ca, "", "Codex", first, co] + tail)
    #expect(!menu.items[1].isEnabled && !menu.items[5].isEnabled)
    // Ancora da leggere: solo il nome e l'account.
    fillAgents(menu, statuses: [:], integrations: [claude, codex], settings: s)
    #expect(menu.items.map(\.title) == ["Claude Code", ca, "", "Codex", co] + tail)

    // Le azioni sono quelle dell'integrazione e finiscono da sole sul main: una riuscita toglie l'errore di prima, una
    // fallita lo lascia, grigio, sotto il suo agente.
    _ = titles(.installed, .notInstalled)
    agentErrors["claude-code"] = "old"
    choose(menu.items[2])
    await waitFor { agentErrors["claude-code"] == nil }
    #expect(removed == 1 && agentErrors["claude-code"] == nil)
    choose(menu.items[6])
    await waitFor { agentErrors["codex"] != nil }
    #expect(titles(.installed, .notInstalled) == ["Claude Code", "Connected", "Disconnect", ca, "", "Codex", "Connect", "broken", co] + tail)
    #expect(!menu.items[7].isEnabled)

    let every = try #require(menu.items.last?.submenu)
    #expect(every.items.map(\.title) == ["5 min", "10 min", "15 min", "30 min"] && every.items.map(\.state) == [.on, .off, .off, .off])
    choose(every.items[2])
    #expect(s.quotaInterval == 15)
}

// Suoni ›: l'interruttore col segno, il volume come cursore dentro il menu (il 35 % dell'autore), Prova; da spenti cursore
// e Prova non si usano.
@MainActor @Test func theSoundsMenuMirrorsTheSettings() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    d.set(true, forKey: "dockduo.agentSounds"); d.set(0.35, forKey: "dockduo.agentVolume")
    let s = Dockduo.Settings(defaults: d)
    func sounds() throws -> [NSMenuItem] { try #require(settingsMenuItem(settings: s, integrations: []).submenu?.items.first { $0.title == "Sounds" }?.submenu).items }
    var items = try sounds()
    #expect(items.map { $0.view == nil ? $0.title : "slider" } == ["Agent Sounds", "slider", "Try"])
    #expect(items[0].state == .on && items[2].isEnabled)
    let row = try #require(items[1].view as? NSHostingView<VolumeRow>)
    #expect(row.rootView.percent == 35)
    choose(items[0])
    #expect(!s.agentSounds)
    items = try sounds()
    #expect(items[0].state == .off && !items[2].isEnabled)
}

// La versione in grigio con lo stato dell'aggiornamento, poi le voci che servono adesso.
@MainActor @Test func theUpdateItemsFollowTheUpdater() {
    let r = Release(version: "0.40", page: URL(string: "https://github.com/p-diego/dockduo/releases/tag/v0.40")!,
                    zip: URL(string: "https://github.com/p-diego/dockduo/releases/download/v0.40/dockduo-0.40.zip")!)
    func titles(_ state: Updater.State, _ error: String? = nil) -> [String] { updateItems(state, checkError: error, current: "0.39").map(\.title) }
    #expect(titles(.idle) == ["Version 0.39", "Check for Updates…"])
    #expect(titles(.upToDate) == ["Version 0.39 · Up to date", "Check for Updates…"])
    #expect(titles(.idle, "offline") == ["Version 0.39 · Couldn't check: offline", "Check for Updates…"])
    #expect(titles(.available(r)) == ["Version 0.39 · 0.40 is out", "Update to 0.40", "What's New"])
    #expect(titles(.downloading(r)) == ["Version 0.39 · Downloading 0.40…", "Check for Updates…"])
    #expect(titles(.failed("x")) == ["Version 0.39 · Update failed: x", "Download the DMG", "Check for Updates…"])
    #expect(!updateItems(.idle, checkError: nil, current: "0.39")[0].isEnabled)
}
