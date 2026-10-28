import AppKit
import Foundation

// Integrazioni (spec impostazioni native §4): dockduo scrive da sé la config degli agenti provati su questo Mac. Regole:
// mai riscrivere righe altrui, backup prima di ogni scrittura. Le funzioni pure lavorano su JSON e sono testate; l'I/O
// sta in fondo. Altri agenti (Codex, Gemini, Cursor, OpenCode) entrano quando si possono provare. AeroSpace non ha più
// bisogno di righe nella sua config: dockduo ne ascolta gli eventi dalla socket (spec 2026-09-23).

enum IntegrationStatus: Equatable {
    case installed, outdated, notInstalled
    case needsApproval       // Codex: installato, ma l'utente non ha ancora dato la fiducia agli hook (/hooks → Trust)
    case missing(String)     // programma o config non trovati: il messaggio da mostrare

    var isMissing: Bool { if case .missing = self { true } else { false } }
}

struct Integration: Identifiable {
    let id: String
    let name: String
    let status: () -> IntegrationStatus
    let install: () throws -> Void
    let remove: () throws -> Void

    // Installa, aggiorna o rimuove (dal Benvenuto e da Impostazioni › Agenti AI) fuori dal main, perché scrive e rilegge
    // file; `done` torna sul main con l'errore da mostrare (nil se è andata), e lì chi chiama rilegge. Scelta dell'utente,
    // non una regressione: da qui non deve far ricomparire il Benvenuto al prossimo avvio solo perché la fotografia diceva
    // ancora "a posto".
    func run(_ action: @escaping () throws -> Void, done: @escaping @MainActor (String?) -> Void) {
        let snapshot = inApplications(Bundle.main.bundlePath)
        DispatchQueue.global().async {
            var failure: String?
            do { try action() } catch { failure = error.localizedDescription }
            let installed = snapshot ? status() == .installed : nil
            DispatchQueue.main.async {
                if let installed { Settings.shared.setupSnapshot[id] = installed }
                done(failure)
            }
        }
    }
}

// MARK: Hook di ciclo vita — Claude Code (settings.json) e Codex (hooks.json), stessa forma (spec agenti §1, spec Codex)

typealias HooksTable = [(event: String, matcher: String?, state: String)]

// Notification per un permesso o una domanda (un'attesa) e per "fermo da un minuto" (idle_prompt): quest'ultima non è
// un'attesa, AgentServer la usa solo per chiudere un turno interrotto ancora al lavoro (ruling #5, 27/10).
let claudeHooksTable: HooksTable = [
    ("UserPromptSubmit", nil, "working"), ("PreToolUse", nil, "working"), ("PostToolUse", nil, "working"),
    ("PermissionRequest", nil, "waiting"), ("Elicitation", nil, "waiting"), ("StopFailure", nil, "waiting"),
    ("Notification", "permission_prompt|idle_prompt|elicitation_dialog", "waiting"),
    ("Stop", nil, "done"), ("SessionEnd", nil, "end"),
]

// Codex non ha Notification/Elicitation/StopFailure; Interrupt = turno abortito, non "in attesa" (spec Codex §1).
let codexHooksTable: HooksTable = [
    ("UserPromptSubmit", nil, "working"), ("PreToolUse", nil, "working"), ("PostToolUse", nil, "working"),
    ("PermissionRequest", nil, "waiting"), ("Stop", nil, "done"), ("SessionEnd", nil, "end"), ("Interrupt", nil, "end"),
]

// Comando del hook: il dockduo-hook di questo bundle, con $HOME al posto della home (come il README: la stessa
// config vale su un altro Mac con la stessa struttura). Bundle fuori dalla home → path assoluto.
func claudeHookCommand(bundle: URL, home: URL, state: String) -> String {
    let full = bundle.appendingPathComponent("Contents/Resources/dockduo-hook").path
    let path = full.hasPrefix(home.path + "/") ? "$HOME" + full.dropFirst(home.path.count) : full
    // Virgolette solo se serve (le installazioni esistenti restano "installed"): serve se c'è uno spazio nel percorso vero,
    // anche nella parte che $HOME nasconde (27/9: con la home "Mario Rossi" il comando si spezzava in due).
    return (full.contains(" ") ? "\"\(path)\"" : path) + " \(state)"
}

// Dall'app ChatGPT manca $__CFBundleIdentifier: DOCKDUO_BUNDLE è il default che lo script usa al suo posto.
func codexHookCommand(bundle: URL, home: URL, state: String) -> String {
    "DOCKDUO_AGENT=codex DOCKDUO_BUNDLE=com.openai.codex " + claudeHookCommand(bundle: bundle, home: home, state: state)
}

private func isOurs(_ hook: [String: Any]) -> Bool { (hook["command"] as? String)?.contains("dockduo-hook") == true }

// installed = ogni riga della tabella ha il suo comando esatto nel gruppo col matcher giusto; outdated = c'è
// qualche dockduo-hook ma non tutto combacia (app spostata, versione vecchia); altrimenti notInstalled.
func hooksStatus(json: [String: Any], table: HooksTable, command: (String) -> String) -> IntegrationStatus {
    let hooks = json["hooks"] as? [String: Any] ?? [:]
    var anyOurs = false, complete = true
    for row in table {
        var found = false
        for group in hooks[row.event] as? [[String: Any]] ?? [] {
            let matcher = group["matcher"] as? String ?? ""
            for hook in group["hooks"] as? [[String: Any]] ?? [] where isOurs(hook) {
                anyOurs = true
                if hook["command"] as? String == command(row.state), matcher == (row.matcher ?? "") { found = true }
            }
        }
        if !found { complete = false }
    }
    if complete { return .installed }
    return anyOurs ? .outdated : .notInstalled
}

// Toglie i nostri hook: un gruppo che conteneva solo i nostri sparisce, un evento rimasto vuoto sparisce, `hooks`
// vuoto sparisce. Tutto il resto identico. Non dipende dalla tabella: toglie ogni comando con "dockduo-hook".
func hooksRemove(json: [String: Any]) -> [String: Any] {
    var out = json
    guard var hooks = json["hooks"] as? [String: Any] else { return out }
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]] else { continue }
        let kept: [[String: Any]] = groups.compactMap { group in
            let all = group["hooks"] as? [[String: Any]] ?? []
            let rest = all.filter { !isOurs($0) }
            if rest.count == all.count { return group }          // niente di nostro: intatto
            if rest.isEmpty { return nil }                       // era tutto nostro
            var g = group; g["hooks"] = rest; return g
        }
        // removeValue, non `= nil`: su [String: Any] il nil verrebbe incartato come Any invece di togliere la chiave
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
    }
    if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
    return out
}

// Toglie i nostri e li rimette in coda a ogni evento, un gruppo per riga della tabella. Idempotente.
// Se hooks[evento] esiste già ma non è nella forma [[String: Any]] (es. un dizionario, config rotta a mano),
// quella riga si salta: non è roba nostra, non si tocca (I2, prima sovrascriveva in silenzio).
func hooksInstall(json: [String: Any], table: HooksTable, command: (String) -> String) -> [String: Any] {
    if let hooks = json["hooks"], !(hooks is [String: Any]) { return json }   // non è la forma che conosciamo: non si tocca
    var out = hooksRemove(json: json)
    var hooks = out["hooks"] as? [String: Any] ?? [:]
    for row in table {
        if let existing = hooks[row.event], !(existing is [[String: Any]]) { continue }
        var group: [String: Any] = ["hooks": [["type": "command", "command": command(row.state)]]]
        if let m = row.matcher { group["matcher"] = m }
        hooks[row.event] = (hooks[row.event] as? [[String: Any]] ?? []) + [group]
    }
    out["hooks"] = hooks
    return out
}

// MARK: Codex — fiducia degli hook (spec Codex §2)

// "PreToolUse" → "pre_tool_use": così Codex nomina gli eventi nelle chiavi di fiducia. `\B`: una maiuscola dentro la
// parola, non la prima lettera.
func snakeCase(_ s: String) -> String {
    s.replacing(#/\B[A-Z]/#) { "_" + $0.output }.lowercased()
}

// Le chiavi che Codex scrive in config.toml quando l'utente approva i nostri hook:
// `[hooks.state."<hooks.json>:<evento_snake>:<indice del nostro gruppo>:0"]`. Una per riga della tabella
// installata; righe non installate non compaiono.
func codexTrustKeys(json: [String: Any], hooksPath: String, table: HooksTable, command: (String) -> String) -> [String] {
    let hooks = json["hooks"] as? [String: Any] ?? [:]
    return table.compactMap { row in
        let groups = hooks[row.event] as? [[String: Any]] ?? []
        let mine = groups.firstIndex { g in (g["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command(row.state) } == true }
        return mine.map { "\(hooksPath):\(snakeCase(row.event)):\($0):0" }
    }
}

// ponytail: ricerca di stringa nel TOML, niente parser; l'hash non è riproducibile da fuori, quindi un hook
// modificato dopo l'approvazione lo vede solo Codex (che lo segnala in /hooks). La fiducia lega l'hash all'hook:
// se hooks.json è stato riscritto dopo l'ultima approvazione (es. path dell'app cambiato dopo un Update) le
// chiavi restano nel TOML ma non sono più valide, quindi serve trustWritten >= hooksWritten quando le date
// dei due file ci sono entrambe; senza una delle due si torna al solo controllo delle chiavi (come prima).
// ponytail: dopo Remove+Install allo stesso path resta "da approvare" finché Codex non riscrive config.toml:
// falso positivo innocuo.
func codexApproved(toml: String, keys: [String], trustWritten: Date?, hooksWritten: Date?) -> Bool {
    guard keys.allSatisfy({ toml.contains("[hooks.state.\"\($0)\"]") }) else { return false }
    if let trustWritten, let hooksWritten { return trustWritten >= hooksWritten }
    return true
}

// MARK: I/O

enum IntegrationError: LocalizedError {
    case badJSON(String), unexpectedHooks
    var errorDescription: String? {
        switch self {
        case .badJSON(let file): String(localized: "\(file) is not valid JSON")
        case .unexpectedHooks: String(localized: "Some hooks have an unexpected shape: fix them by hand.")
        }
    }
}

private let home = FileManager.default.homeDirectoryForCurrentUser

private var claudeDir: URL {
    ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
}
private var claudeFile: URL { claudeDir.appendingPathComponent("settings.json") }
private func claudeCommand(_ state: String) -> String { claudeHookCommand(bundle: Bundle.main.bundleURL, home: home, state: state) }
// Il file degli hook (settings.json di Claude Code, hooks.json di Codex): assente → {} (la cartella c'è, si parte da vuoto).
func readHooks(_ file: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw IntegrationError.badJSON(file.lastPathComponent) }
    return json
}
// È come li riscrivono Claude Code e Codex: chiavi ordinate, indentato, senza "\/". Backup <file>.bak (sovrascritto)
// prima di ogni scrittura; se il backup fallisce non si scrive.
func writeHooks(_ json: [String: Any], to file: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    // I dotfile spesso sono symlink (chezmoi, dotbot, ...): scrittura atomica su un symlink sostituisce il link
    // con un file normale e lascia intatto il vero target. Si risolve prima, così backup e scrittura vanno lì.
    let url = file.resolvingSymlinksInPath()
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        let bak = url.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try fm.copyItem(at: url, to: bak)
    }
    try data.write(to: url, options: .atomic)
}

private let claudeCodeIntegration = Integration(
    id: "claude-code", name: "Claude Code",
    status: {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return .missing(String(localized: "Claude Code not found (~/.claude missing)")) }
        guard let json = try? readHooks(claudeFile) else { return .missing(IntegrationError.badJSON("settings.json").localizedDescription) }
        return hooksStatus(json: json, table: claudeHooksTable, command: claudeCommand)
    },
    install: { try installHooks(claudeFile, claudeHooksTable, claudeCommand) },
    remove: { try writeHooks(hooksRemove(json: readHooks(claudeFile)), to: claudeFile) })

// L'installazione degli hook, identica per Claude e Codex: cambiano solo file, tabella e comando.
func installHooks(_ file: URL, _ table: HooksTable, _ command: (String) -> String) throws {
    let out = hooksInstall(json: try readHooks(file), table: table, command: command)
    guard hooksStatus(json: out, table: table, command: command) == .installed else { throw IntegrationError.unexpectedHooks }
    try writeHooks(out, to: file)
}

var codexDir: URL {   // anche le credenziali (Usage.swift)
    ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
}
private var codexFile: URL { codexDir.appendingPathComponent("hooks.json") }
private func codexCommand(_ state: String) -> String { codexHookCommand(bundle: Bundle.main.bundleURL, home: home, state: state) }
private func modDate(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

// La CLI di Codex: quella in PATH (Homebrew) se c'è, altrimenti quella dentro l'app ChatGPT.
func codexBinary() -> String {
    ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? "/Applications/ChatGPT.app/Contents/Resources/codex"
}

// Apre Terminal con uno script già in esecuzione: un file .command in temp lanciato da `open -a Terminal`, niente
// AppleScript, quindi niente permesso Automazione. `name` distingue i file (codex-hooks, aerospace).
func openTerminal(script: String, name: String) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-\(name).command")
    try? ("#!/bin/sh\n" + script).write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    open("-a", "Terminal", file.path)
}

// Codex già avviato: l'utente scrive /hooks e preme Trust.
func openCodexTerminal() {
    openTerminal(script: "printf '\\nType /hooks, choose Trust, then quit Codex (Ctrl-C twice).\\n\\n'\nexec '\(codexBinary())'\n", name: "codex-hooks")
}

// Chiude ChatGPT e la riapre quando è uscita (l'app rilegge hooks.json e la fiducia solo all'avvio).
func restartChatGPT() {
    let apps = runningApps(bundle: "com.openai.codex")
    apps.forEach { $0.terminate() }
    Task { @MainActor in
        for _ in 0..<40 where apps.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(250)) }
        open("-b", "com.openai.codex")
    }
}

private let codexIntegration = Integration(
    id: "codex", name: "Codex",
    status: {
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return .missing(String(localized: "Codex not found (~/.codex missing)")) }
        guard let json = try? readHooks(codexFile) else { return .missing(IntegrationError.badJSON("hooks.json").localizedDescription) }
        let s = hooksStatus(json: json, table: codexHooksTable, command: codexCommand)
        guard s == .installed else { return s }
        let configFile = codexDir.appendingPathComponent("config.toml").resolvingSymlinksInPath()
        let toml = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let hooksPath = codexFile.resolvingSymlinksInPath().path
        let keys = codexTrustKeys(json: json, hooksPath: hooksPath, table: codexHooksTable, command: codexCommand)
        let approved = codexApproved(toml: toml, keys: keys, trustWritten: modDate(configFile.path), hooksWritten: modDate(hooksPath))
        return approved ? .installed : .needsApproval
    },
    install: { try installHooks(codexFile, codexHooksTable, codexCommand) },
    // hooksRemove può lasciare {} se non restano hook: Codex vuole "hooks" presente, anche vuoto.
    remove: {
        let out = hooksRemove(json: try readHooks(codexFile))
        try writeHooks(out.isEmpty ? ["hooks": [String: Any]()] : out, to: codexFile)
    })

let integrations = [claudeCodeIntegration, codexIntegration]

// Lo stato di ogni integrazione, per id. Legge i file degli hook: fuori dal main.
func integrationStatuses(_ list: [Integration] = integrations) -> [String: IntegrationStatus] {
    Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.status()) })
}
