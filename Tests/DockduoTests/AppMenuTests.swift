import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Le righe di un menu come si leggono: "|" per una riga di separazione, l'account per l'intestazione di una quota ("Claude",
// "ChatGPT": il titolo fino al primo " · ", dopo vengono piano e stato), se no il titolo.
@MainActor private func lines(_ menu: NSMenu) -> [String] {
    menu.items.map { item in
        if item.isSeparatorItem { return "|" }
        if let row = item.view as? NSHostingView<AccountRow> { return "account " + row.rootView.title.components(separatedBy: " · ")[0] }
        return item.title
    }
}

// Le sessioni in cima al menu, fino alla prima riga di separazione: per ognuna l'id che portano le sue voci.
@MainActor private func sessionIDs(_ menu: NSMenu) -> [String?] {
    menu.items.prefix { !$0.isSeparatorItem }.map { $0.submenu?.items.first?.representedObject as? String }
}

// Review Focus 5: le sessioni nell'app che le ospita (spec dock-degli-agenti §3). Il menu di un'app elenca solo le sue
// (sessionIDs), dalla più urgente, con Mostra finestra e Reimposta l'agente; poi i limiti degli agenti di quelle sessioni
// (ChatGPT solo dove c'è Codex, accountAvailable); poi, staccate, le voci di oggi. Una sessione finita dopo l'ultimo giro
// non c'è più; una che non sta in nessuna app non è in nessun menu; un'app senza sessioni ha il menu di oggi.
@MainActor @Test func theAppMenuShowsItsOwnSessions() {
    _ = NSApplication.shared
    let bar = BarState()
    bar.sessions = ["a1": session("a1", .working, agent: .claude, bundle: "com.code"),
                    "a2": session("a2", .waiting, agent: .codex, bundle: "com.code"),
                    "b1": session("b1", .done, agent: .claude, bundle: "com.term"),
                    "z": session("z", .waiting, agent: .codex, bundle: nil)]
    let code = AppEntry(name: "Code", pid: 7, windowID: 1, bundle: "com.code", agent: .waiting, sessionIDs: ["a1", "a2", "gone"])
    let term = AppEntry(name: "Terminal", pid: 8, windowID: 2, bundle: "com.term", agent: .done, sessionIDs: ["b1"])
    let notes = AppEntry(name: "Notes", pid: 9, windowID: 3, bundle: "com.notes")
    // Tenute qui: le voci tengono il loro bersaglio debole.
    let views = [code, term, notes].map { AppMenuView(app: $0, state: bar) }
    let (codeMenu, termMenu, notesMenu) = (views[0].menu(), views[1].menu(), views[2].menu())
    let codex = FileManager.default.fileExists(atPath: codexDir.path)
    let today = ["|", "Show", "Hide", "Quit", "|", "Reset agent", "|", "Edit Dock…", "Settings"]

    #expect(sessionIDs(codeMenu) == ["a2", "a1"])   // l'attesa prima del lavoro
    #expect(lines(codeMenu).prefix(2).map { $0.components(separatedBy: " · ")[0] } == ["Codex", "Claude"])   // poi la cartella
    #expect(codeMenu.items[0].submenu?.items.map(\.title) == ["Show window", "Reset agent"])
    #expect(codeMenu.items[0].submenu?.items.map { $0.representedObject as? String } == ["a2", "a2"])
    #expect(lines(codeMenu).filter { $0.hasPrefix("account") } == ["account Claude"] + (codex ? ["account ChatGPT"] : []))
    #expect(lines(codeMenu).suffix(today.count) == ArraySlice(today))

    #expect(sessionIDs(termMenu) == ["b1"])
    #expect(lines(termMenu).filter { $0.hasPrefix("account") } == ["account Claude"])   // solo gli agenti delle sue sessioni
    #expect(lines(termMenu).suffix(today.count) == ArraySlice(today))

    #expect(lines(notesMenu) == ["Show", "Hide", "Quit", "|", "Edit Dock…", "Settings"])
}

// Un account c'è su questo Mac: Claude sempre, ChatGPT solo con la cartella di Codex (la regola di prima, M3).
@Test func chatGPTCountsOnlyWhereCodexIs() {
    #expect(accountAvailable(.claude, codexInstalled: false) && accountAvailable(.codex, codexInstalled: true))
    #expect(!accountAvailable(.codex, codexInstalled: false))
}
