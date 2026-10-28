import AppKit
import Testing
@testable import Dockduo

private let w1 = Workspace(name: "1", isFocused: true)
private let w2 = Workspace(name: "2", isFocused: false)
private let w3 = Workspace(name: "3", isFocused: false)
private func win(_ ws: String, _ app: String, id: Int = 1, pid: Int = 100,
                 bundle: String = "com.test", title: String = "") -> Window {
    Window(workspace: ws, app: app, id: id, pid: pid_t(pid), bundle: bundle, title: title)
}
// Le sessioni di prova sono di Claude e mai viste (session()): un'icona con sessioni ha l'agente Claude, e se aspetta insiste.
private func entry(_ name: String, pid: Int = 100, windowID: Int = 1, bundle: String = "com.test", agent: AgentState? = nil,
                   sessions: [String] = []) -> AppEntry {
    var e = AppEntry(name: name, pid: pid_t(pid), windowID: windowID, bundle: bundle, agent: agent, sessionIDs: sessions)
    e.nagging = agent == .waiting
    e.agents = sessions.isEmpty ? [] : [.claude]
    return e
}
func session(_ id: String, _ state: AgentState, agent: Agent = .claude, cwd: String = "/Users/me/Git/dockduo",
             bundle: String? = "com.test") -> AgentSession {   // serve anche ad AppMenuTests
    AgentSession(id: id, agent: agent, state: state, cwd: cwd, bundle: bundle, since: Date(), updatedAt: Date())
}

@Test func parsesWorkspaceLines() {
    #expect(parseWorkspaces("1|true\n2|false\n\n") == [w1, w2])
}

@Test func parsesWindowLinesKeepingPipesInTitleAndSkippingMalformed() {
    let text = "1|Code|25589|2829|com.microsoft.VSCode|main.swift — dockduo\n"
        + "2|Safari|24503|91596|com.apple.Safari|a | b | c\n"
        + "rotta\n1|Code|x|2829|com.microsoft.VSCode|t\n1|Code|1|2829|com.microsoft.VSCode\n"
    #expect(parseWindows(text) == [
        win("1", "Code", id: 25589, pid: 2829, bundle: "com.microsoft.VSCode", title: "main.swift — dockduo"),
        win("2", "Safari", id: 24503, pid: 91596, bundle: "com.apple.Safari", title: "a | b | c"),
    ])
}

// Una voce per finestra, per spazio; dentro lo spazio l'ordine lo decide dockduo: alfabetico per app come nel Finder
// (maiuscole e minuscole insieme), poi titolo, qualunque sia l'ordine in cui arrivano le finestre.
@Test func oneEntryPerWindowAlphabeticalByAppThenTitle() {
    let windows = [win("1", "Ghostty", id: 11, pid: 200), win("1", "Code", id: 12, title: "b"), win("1", "Code", id: 10, title: "a"),
                   win("1", "iTerm2", id: 13, pid: 300), win("2", "Safari", id: 20, pid: 400)]
    let r = report(workspaces: [w1, w2, w3], windows: windows, sessions: [])
    #expect(r.map(\.apps) == [[entry("Code", windowID: 10), entry("Code", windowID: 12), entry("Ghostty", pid: 200, windowID: 11),
                               entry("iTerm2", pid: 300, windowID: 13)],
                              [entry("Safari", pid: 400, windowID: 20)], []])
}

@Test func excludesIgnoredApps() {
    #expect(report(workspaces: [w1], windows: [win("1", "Code", id: 1), win("1", "Comnyang", id: 4)], sessions: [])[0].apps
            == [entry("Code", windowID: 1)])
}

// Se una finestra si vede lo dice macOS: fuori schermo (minimizzata, app nascosta) niente icona, qualunque layout dia
// AeroSpace. Per un attimo dopo un avviso di SkyLight vale l'avviso: l'elenco di macOS arriva fino a 0,1 s dopo.
@Test func visibilityComesFromMacOSAndTheLatestNoticeWins() {
    let code = win("1", "Code", id: 1), safari = win("1", "Safari", id: 3, pid: 300)
    let kuma = win("1", "Kuma", id: 2, pid: 200)
    #expect(visibleWindows([code, kuma, safari], offscreen: [2], recent: [:], lastKnown: [:], focusedWorkspace: "1") == [code, safari])
    #expect(visibleWindows([code, kuma, safari], offscreen: [2], recent: [2: true, 3: false], lastKnown: [:], focusedWorkspace: "1")
            == [code, kuma])
}

// Riaperta dopo ⌘M: AeroSpace l'aveva tolta dalla lista e la rimette 0,9 s dopo, nello spazio a fuoco; intanto torna
// dall'ultima riga nota, in quello spazio. Se AeroSpace l'ha in lista (dopo ⌘H) vale la sua riga, col suo spazio.
// Senza riga nota non si inventa niente; senza spazio a fuoco resta il suo.
@Test func windowMissingFromAeroSpaceComesBackInTheFocusedWorkspace() {
    let code = win("1", "Code", id: 1), kuma = win("2", "Kuma", id: 2, pid: 200)
    #expect(visibleWindows([code], offscreen: [], recent: [2: true], lastKnown: [2: kuma], focusedWorkspace: "1")
            == [code, win("1", "Kuma", id: 2, pid: 200)])
    #expect(visibleWindows([code, kuma], offscreen: [], recent: [2: true], lastKnown: [2: kuma], focusedWorkspace: "1") == [code, kuma])
    #expect(visibleWindows([code], offscreen: [], recent: [3: true], lastKnown: [2: kuma], focusedWorkspace: "1") == [code])
    #expect(visibleWindows([code], offscreen: [], recent: [2: true], lastKnown: [2: kuma], focusedWorkspace: nil) == [code, kuma])
}

@Test func hiddenAppsAreRunningAppsWithoutAVisibleIcon() {
    let running = [entry("Code", windowID: 0), entry("Kuma", pid: 7, windowID: 0), entry("Comnyang", windowID: 0), entry("Finder", windowID: 0)]
    let r = report(workspaces: [w1], windows: [win("1", "Code", id: 1)], sessions: [])
    #expect(hiddenApps(running: running, reports: r, sessions: []) == [entry("Kuma", pid: 7, windowID: 0)])
}

@Test func hiddenAppsDedupeByName() {
    let running = [entry("Kuma", pid: 7, windowID: 0), entry("Kuma", pid: 8, windowID: 0)]
    #expect(hiddenApps(running: running, reports: [], sessions: []) == [entry("Kuma", pid: 7, windowID: 0)])
}

// L'app a tutto schermo in uno spazio nativo sta tra le nascoste (scelta del 3/10) ma si vede piena, non attenuata:
// non è minimizzata, è parcheggiata altrove.
@Test func aFullscreenAppIsHiddenButMarked() {
    let running = [entry("Safari", pid: 9, windowID: 0), entry("Kuma", pid: 7, windowID: 0)]
    let hidden = hiddenApps(running: running, reports: [], sessions: [], fullscreen: [9])
    #expect(hidden.first { $0.name == "Safari" }?.fullscreenElsewhere == true)
    #expect(hidden.first { $0.name == "Kuma" }?.fullscreenElsewhere == false)
}

// Il fantasma di macOS 27 (app uscita con processi in background) ha il pid di un processo finito.
@Test func processAliveOnlyForLiveProcesses() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run(); p.waitUntilExit()
    #expect(!processAlive(p.processIdentifier))
    #expect(processAlive(getpid()))
    #expect(processAlive(1))   // launchd, di root: vivo anche se non gli si può mandare segnali
}

@Test func reportKeepsWorkspaceOrder() {
    #expect(report(workspaces: [w2, w1], windows: [], sessions: []).map(\.workspace.name) == ["2", "1"])
}

@Test func sessionBindsToTheOnlyWindowOfItsApp() {
    let windows = [win("1", "Code", id: 10), win("1", "Ghostty", id: 11, pid: 200, bundle: "com.ghostty")]
    let r = report(workspaces: [w1], windows: windows, sessions: [session("s", .working, bundle: "com.ghostty")])
    #expect(r[0].apps == [entry("Code", windowID: 10), entry("Ghostty", pid: 200, windowID: 11, bundle: "com.ghostty", agent: .working, sessions: ["s"])])
}

@Test func sessionPicksTheWindowWhoseTitleHasTheCwdName() {
    let windows = [win("1", "Code", id: 10, title: "main.swift — dockduo"), win("2", "Code", id: 20, title: "README — dotfiles")]
    let r = report(workspaces: [w1, w2], windows: windows, sessions: [session("s", .waiting)])
    #expect(r.map { $0.apps[0].agent } == [.waiting, nil])
}

@Test func ambiguousSessionMarksEveryWindowOfItsApp() {
    let windows = [win("1", "Code", id: 10, title: "x"), win("1", "Code", id: 12, title: "x"), win("2", "Code", id: 20, title: "x")]
    let r = report(workspaces: [w1, w2], windows: windows, sessions: [session("s", .waiting)])
    #expect(r[0].apps == [entry("Code", windowID: 10, agent: .waiting, sessions: ["s"]), entry("Code", windowID: 12, agent: .waiting, sessions: ["s"])])
    #expect(r[1].apps == [entry("Code", windowID: 20, agent: .waiting, sessions: ["s"])])
}

@Test func eachBoundSessionRingsOnlyItsWindow() {
    let windows = [win("1", "Code", id: 10, title: "a"), win("1", "Code", id: 12, title: "b")]
    let sessions = [session("w", .working, cwd: "/x/a"), session("p", .waiting, cwd: "/x/b")]
    #expect(report(workspaces: [w1], windows: windows, sessions: sessions)[0].apps
            == [entry("Code", windowID: 10, agent: .working, sessions: ["w"]), entry("Code", windowID: 12, agent: .waiting, sessions: ["p"])])
}

@Test func unboundSessionDoesNotOverrideAWindowBoundOne() {
    // Sessione "a" legata alla finestra 10 (working); "c" ambigua (waiting) accende tutte le finestre, la 10 compresa: vince waiting.
    let windows = [win("1", "Code", id: 10, title: "a"), win("1", "Code", id: 12, title: "x")]
    let sessions = [session("w", .working, cwd: "/x/a"), session("c", .waiting, cwd: "/x/zzz")]
    #expect(report(workspaces: [w1], windows: windows, sessions: sessions)[0].apps
            == [entry("Code", windowID: 10, agent: .waiting, sessions: ["c", "w"]), entry("Code", windowID: 12, agent: .waiting, sessions: ["c"])])
}

@Test func sessionWithoutBundleMarksNothing() {
    let r = report(workspaces: [w1], windows: [win("1", "Code", id: 10)], sessions: [session("s", .waiting, bundle: nil)])
    #expect(r[0].apps == [entry("Code", windowID: 10)])
}

@Test func hiddenAppCarriesItsSessionState() {
    let running = [entry("Ghostty", pid: 7, windowID: 0, bundle: "com.ghostty"), entry("Kuma", pid: 8, windowID: 0, bundle: "com.kuma")]
    let r = hiddenApps(running: running, reports: [], sessions: [session("s", .done, bundle: "com.ghostty")])
    #expect(r == [entry("Ghostty", pid: 7, windowID: 0, bundle: "com.ghostty", agent: .done, sessions: ["s"]), entry("Kuma", pid: 8, windowID: 0, bundle: "com.kuma")])
}

@Test func sessionsExpireByStateAndAge() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func s(_ state: AgentState, age: TimeInterval, bundle: String? = nil) -> AgentSession {
        AgentSession(id: "x", agent: .claude, state: state, cwd: "", bundle: bundle, since: t0.addingTimeInterval(-age), updatedAt: t0.addingTimeInterval(-age))
    }
    #expect(expired(s(.done, age: 6), now: t0))            // bundle ignoto: 5 s
    #expect(!expired(s(.done, age: 4), now: t0))
    // Con bundle: verde finché l'app non è in primo piano, e comunque almeno 5 s.
    #expect(!expired(s(.done, age: 3600, bundle: "com.a"), now: t0, front: "com.b"))
    #expect(!expired(s(.done, age: 3600, bundle: "com.a"), now: t0, front: nil))
    #expect(expired(s(.done, age: 6, bundle: "com.a"), now: t0, front: "com.a"))
    #expect(!expired(s(.done, age: 4, bundle: "com.a"), now: t0, front: "com.a"))
    // App chiusa (bundle non in esecuzione): morta in ogni stato; senza bundle non si può sapere.
    #expect(expired(s(.waiting, age: 1, bundle: "com.a"), now: t0, running: ["com.b"]))
    #expect(!expired(s(.waiting, age: 1, bundle: "com.a"), now: t0, running: ["com.a", "com.b"]))
    #expect(!expired(s(.waiting, age: 1), now: t0, running: ["com.b"]))
    #expect(expired(s(.working, age: 601), now: t0))
    #expect(!expired(s(.working, age: 599), now: t0))
    #expect(!expired(s(.waiting, age: 3600), now: t0))
}

// L'agente ucciso senza SessionEnd: il suo processo non c'è più e la sessione scade in ogni stato, anche un'attesa senza app
// nota, che prima restava per sempre. Col processo vivo resta.
@Test func aSessionDiesWithItsAgent() throws {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run(); p.waitUntilExit()
    var s = AgentSession(id: "x", agent: .claude, state: .waiting, cwd: "", bundle: nil, since: t0, updatedAt: t0)
    #expect(!expired(s, now: t0))
    s.pid = p.processIdentifier
    #expect(expired(s, now: t0))
    s.pid = getpid()
    #expect(!expired(s, now: t0))
}

private func at(_ id: String, _ state: AgentState, since: Double, updated: Double) -> AgentSession {
    AgentSession(id: id, agent: .claude, state: state, cwd: "", bundle: "com.test",
                 since: Date(timeIntervalSince1970: since), updatedAt: Date(timeIntervalSince1970: updated))
}

@Test func aContinuingStateKeepsItsStart() {
    let first = at("a", .working, since: 10, updated: 10)
    let again = at("a", .working, since: 50, updated: 50)     // un altro PreToolUse
    #expect(continuing(again, from: first).since == Date(timeIntervalSince1970: 10))
    #expect(continuing(again, from: first).updatedAt == Date(timeIntervalSince1970: 50))
    let waiting = at("a", .waiting, since: 60, updated: 60)   // lo stato cambia: riparte
    #expect(continuing(waiting, from: again).since == Date(timeIntervalSince1970: 60))
    #expect(continuing(first, from: nil) == first)            // sessione nuova
}

@Test func sessionsGoFromTheMostUrgent() {
    let sessions = ["w": at("w", .waiting, since: 0, updated: 0), "old": at("old", .working, since: 1, updated: 1),
                    "new": at("new", .working, since: 2, updated: 2), "d": at("d", .done, since: 9, updated: 9)]
    #expect(sessionsByUrgency(sessions).map(\.id) == ["w", "new", "old", "d"])
    #expect(sessionsByUrgency([:]).isEmpty)
}

@Test func placeFindsTheIconShowingTheSession() {
    let a = entry("Terminal", windowID: 1, agent: .working, sessions: ["s1"])
    let b = entry("Terminal", windowID: 2, agent: .working, sessions: ["s2"])   // stessa app, stesso stato
    let hidden = entry("Code", windowID: 0, bundle: "com.code", sessions: ["s3"])
    #expect(place(of: "s2", in: [a, b, hidden])?.windowID == 2)
    #expect(place(of: "s3", in: [a, b, hidden])?.bundle == "com.code")      // senza icona: l'app nascosta
    #expect(place(of: "zz", in: [a, b, hidden]) == nil)
}

@Test func sessionRowsSayWhoWhereAndSinceWhen() {
    let s = at("a", .waiting, since: 1000, updated: 1000)
    #expect(sessionTitle(s) == "Claude")                                                 // cartella non nota
    let inFolder = AgentSession(id: "d", agent: .codex, state: .working, cwd: "/Users/x/Git/siigil", bundle: "com.test",
                                since: Date(), updatedAt: Date())
    #expect(sessionTitle(inFolder) == "Codex · siigil")                                  // il menu è già dell'app: la cartella
    #expect(sessionSubtitle(s, now: Date(timeIntervalSince1970: 1030)) == "Waiting · now")
    #expect(sessionSubtitle(s, now: Date(timeIntervalSince1970: 1000 + 125)) == "Waiting · 2 min")
    #expect(sessionSubtitle(at("b", .working, since: 0, updated: 0), now: Date(timeIntervalSince1970: 7300)) == "Working · 2 h")
    #expect(sessionSubtitle(at("c", .done, since: 50, updated: 50), now: Date(timeIntervalSince1970: 0)) == "Finished · now")   // orologio indietro
}

// Senza app nota il simbolo di riserva deve leggersi anche nel menu scuro: non nero (review finale, 27/9). Si guarda solo
// il centro dell'icona, lontano dall'anello colorato sul bordo.
@Test @MainActor func aSessionWithNoKnownAppStillHasAVisibleIcon() throws {
    let s = AgentSession(id: "x", agent: .claude, state: .working, cwd: "", bundle: nil, since: Date(), updatedAt: Date())
    let image = try #require(sessionIcon(s))
    let bitmap = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
    let (w, h) = (bitmap.pixelsWide, bitmap.pixelsHigh)
    var brightest: CGFloat = 0
    for y in h / 4 ..< h * 3 / 4 { for x in w / 4 ..< w * 3 / 4 {
        if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 { brightest = max(brightest, c.brightnessComponent) }
    } }
    #expect(brightest > 0.6)
}

// Senza AeroSpace (spec senza-aerospace §2): una pillola sola, workspace senza nome e mai a fuoco (l'invariante che
// la distingue: AeroSpace non ha workspace senza nome), un'icona per app del Dock con finestre a schermo,
// windowID = pid (unico: due app omonime restano due), in ordine alfabetico, sessioni sull'app per bundle.
@Test func theReducedReportShowsOnscreenAppsOnly() {
    let running = [entry("Safari", pid: 9, windowID: 0, bundle: "com.safari"),
                   entry("Code", pid: 7, windowID: 0, bundle: "com.code"),
                   entry("Kuma", pid: 5, windowID: 0, bundle: ""),            // senza bundle: si mostra lo stesso
                   entry("Kuma", pid: 6, windowID: 0, bundle: ""),            // omonima: due icone
                   entry("Hidden", pid: 8, windowID: 0, bundle: "com.h")]     // senza finestre: resta alle nascoste
    let s = session("s1", .working, bundle: "com.code")
    let r = reducedReport(running: running, visible: [9, 7, 5, 6], sessions: [s])
    #expect(r.workspace == Workspace(name: "", isFocused: false))
    #expect(r.apps.map(\.name) == ["Code", "Kuma", "Kuma", "Safari"])
    #expect(r.apps.map(\.windowID) == [-7, -5, -6, -9])                       // windowID = -pid
    // Negativo = non focalizzabile: showApp attiva l'app invece di mandare l'id ad AeroSpace.
    #expect(r.apps.allSatisfy { $0.windowID < 0 })
    #expect(r.apps[0].agent == .working && r.apps[0].sessionIDs == ["s1"])
    #expect(r.apps[1].agent == nil)
}

// Il Dock: un'icona per app, in ordine di apertura come nel Dock (senza data in fondo, a pari per pid); attenuate quelle
// senza finestre a schermo.
@Test func dockAppsFollowLaunchOrderAndDimTheHidden() {
    let t = Date(timeIntervalSince1970: 1000)
    let running = [entry("Safari", pid: 9, windowID: 0), entry("Finder", pid: 3, windowID: 0), entry("Kuma", pid: 7, windowID: 0),
                   entry("Code", pid: 5, windowID: 0), entry("Mail", pid: 4, windowID: 0)]
    let launched: [pid_t: Date] = [9: t.addingTimeInterval(20), 3: t, 5: t.addingTimeInterval(10)]
    let dock = dockApps(running: running, launched: launched, visible: [9, 3], sessions: [])
    #expect(dock.map(\.name) == ["Finder", "Code", "Safari", "Mail", "Kuma"])
    #expect(dock.map(\.dimmed) == [false, true, false, true, true])
    #expect(dock.allSatisfy { $0.windowID == 0 })   // click = mostra l'app (showApp), nessuna finestra
}

// Il Finder gira sempre (la scrivania): nel Dock solo con una finestra aperta, anche ridotta (autore, 25/10).
@Test func theFinderShowsOnlyWithAWindow() {
    let running = [entry("Finder", pid: 3, windowID: 0, bundle: finderBundle), entry("Mail", pid: 4, windowID: 0)]
    #expect(dockApps(running: running, launched: [:], visible: [], sessions: []).map(\.name) == ["Mail"])
    #expect(dockApps(running: running, launched: [:], visible: [], windowed: [3], sessions: []).map(\.name) == ["Finder", "Mail"])
    #expect(dockApps(running: running, launched: [:], visible: [3], sessions: []).map(\.name) == ["Finder", "Mail"])
}

@Test func dockAppsCarryTheAgentRing() {
    let running = [entry("Ghostty", pid: 7, windowID: 0, bundle: "com.ghostty"), entry("Kuma", pid: 8, windowID: 0, bundle: "com.kuma")]
    let dock = dockApps(running: running, launched: [:], visible: [7, 8],
                        sessions: [session("b", .working, bundle: "com.ghostty"), session("a", .waiting, bundle: "com.ghostty")])
    #expect(dock == [entry("Ghostty", pid: 7, windowID: 0, bundle: "com.ghostty", agent: .waiting, sessions: ["a", "b"]),
                     entry("Kuma", pid: 8, windowID: 0, bundle: "com.kuma")])
}

// Il valore di LaunchServices "StatusLabel" (misurato il 24/10 con un'app di prova): {label: "4"}, {label: ""} per il solo
// pallino, {label: NSNull} dopo che l'app l'ha tolto, niente se non l'ha mai messo.
@Test func badgeLabelParsing() {
    #expect(badgeLabel(["label": "4"] as NSDictionary) == "4")
    #expect(badgeLabel(["label": ""] as NSDictionary) == "")
    #expect(badgeLabel(["label": NSNull()] as NSDictionary) == nil)
    #expect(badgeLabel(["label": 4] as NSDictionary) == nil)
    #expect(badgeLabel(nil) == nil)
    #expect(badgeLabel("4") == nil)
}
