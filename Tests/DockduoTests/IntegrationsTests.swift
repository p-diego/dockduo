import Foundation
import Testing
@testable import Dockduo

private let bundle = URL(fileURLWithPath: "/Users/x/Applications/dockduo.app")
private let home = URL(fileURLWithPath: "/Users/x")
private func cmd(_ state: String) -> String { claudeHookCommand(bundle: bundle, home: home, state: state) }
private func codexCmd(_ state: String) -> String { codexHookCommand(bundle: bundle, home: home, state: state) }

// Un settings.json con hook altrui (il caso Comnyang dell'autore) e altre chiavi.
private let foreign: [String: Any] = [
    "model": "opus",
    "hooks": [
        "Stop": [["matcher": "", "hooks": [["type": "command", "command": "/usr/bin/env node /x/other-hook.js Stop"]]]],
        "Notification": [["matcher": "", "hooks": [["type": "command", "command": "/usr/bin/env node /x/other-hook.js Notification"]]]],
    ],
]

private func groups(_ json: [String: Any], _ event: String) -> [[String: Any]] {
    (json["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
}

@Test func hookCommandUsesHomeVariable() {
    #expect(cmd("done") == "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook done")
    let abs = claudeHookCommand(bundle: URL(fileURLWithPath: "/Applications/dockduo.app"), home: home, state: "end")
    #expect(abs == "/Applications/dockduo.app/Contents/Resources/dockduo-hook end")
}

@Test func codexCommandSetsAgentAndDefaultBundle() {
    #expect(codexCmd("waiting") == "DOCKDUO_AGENT=codex DOCKDUO_BUNDLE=com.openai.codex $HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook waiting")
}

@Test func codexInstallOnEmptyAddsSevenEventsWithoutMatchers() {
    let out = hooksInstall(json: [:], table: codexHooksTable, command: codexCmd)
    #expect((out["hooks"] as? [String: Any])?.count == 7)
    #expect(Set(((out["hooks"] as? [String: Any]) ?? [:]).keys) == ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd", "Interrupt"])
    #expect(groups(out, "Interrupt").first?["matcher"] == nil)
    #expect((groups(out, "Interrupt").first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == codexCmd("end"))
    #expect(hooksStatus(json: out, table: codexHooksTable, command: codexCmd) == .installed)
}

@Test func codexInstallKeepsForeignGroupsAndRemoveRestoresThem() {
    let once = hooksInstall(json: foreign, table: codexHooksTable, command: codexCmd)
    #expect(groups(once, "Stop").count == 2)
    #expect(groups(once, "Notification").count == 1)   // evento non nella tabella Codex: intatto
    #expect(NSDictionary(dictionary: hooksInstall(json: once, table: codexHooksTable, command: codexCmd)).isEqual(to: once))
    #expect(NSDictionary(dictionary: hooksRemove(json: once)).isEqual(to: foreign))
}

// Il permesso e la domanda (un'attesa), e la notifica di Claude "fermo da un minuto" (idle_prompt), che chiude un turno
// interrotto ancora al lavoro (ruling #5, 27/10).
@Test func claudeHooksListenToIdlePrompt() {
    #expect(claudeHooksTable.first { $0.event == "Notification" }?.matcher == "permission_prompt|idle_prompt|elicitation_dialog")
}

@Test func installOnEmptyAddsNineEvents() {
    let out = hooksInstall(json: [:], table: claudeHooksTable, command: cmd)
    #expect((out["hooks"] as? [String: Any])?.count == 9)
    #expect(groups(out, "Notification").first?["matcher"] as? String == "permission_prompt|idle_prompt|elicitation_dialog")
    #expect(groups(out, "Stop").first?["matcher"] == nil)
    #expect(hooksStatus(json: out, table: claudeHooksTable, command: cmd) == .installed)
}

@Test func installKeepsForeignHooksAndIsIdempotent() {
    let once = hooksInstall(json: foreign, table: claudeHooksTable, command: cmd)
    #expect(once["model"] as? String == "opus")
    #expect(groups(once, "Stop").count == 2)
    #expect((groups(once, "Stop").first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/bin/env node /x/other-hook.js Stop")
    let twice = hooksInstall(json: once, table: claudeHooksTable, command: cmd)
    #expect(NSDictionary(dictionary: twice).isEqual(to: once))
}

@Test func removeAfterInstallRestoresTheOriginal() {
    let back = hooksRemove(json: hooksInstall(json: foreign, table: claudeHooksTable, command: cmd))
    #expect(NSDictionary(dictionary: back).isEqual(to: foreign))
    #expect(hooksRemove(json: hooksInstall(json: [:], table: claudeHooksTable, command: cmd)).isEmpty)
}

@Test func statusDetectsOutdatedPath() {
    let old = hooksInstall(json: [:], table: claudeHooksTable) { "/old/dockduo.app/Contents/Resources/dockduo-hook \($0)" }
    #expect(hooksStatus(json: old, table: claudeHooksTable, command: cmd) == .outdated)
    #expect(hooksStatus(json: foreign, table: claudeHooksTable, command: cmd) == .notInstalled)
    #expect(hooksStatus(json: [:], table: claudeHooksTable, command: cmd) == .notInstalled)
}

// Un gruppo con un hook altrui E uno nostro nello stesso evento (I2, guardia): hooksRemove deve lasciare il
// gruppo col solo hook altrui, hooksInstall deve rimettere l'altrui intatto più il nostro gruppo in coda.
private let mixedStopGroup: [String: Any] = [
    "hooks": [
        "Stop": [["matcher": "", "hooks": [
            ["type": "command", "command": "/usr/bin/env node /x/other-hook.js Stop"],
            ["type": "command", "command": cmd("done")],
        ]]],
    ],
]

@Test func mixedGroupKeepsForeignHookAlone() {
    let removed = hooksRemove(json: mixedStopGroup)
    let removedGroups = groups(removed, "Stop")
    #expect(removedGroups.count == 1)
    #expect((removedGroups.first?["hooks"] as? [[String: Any]])?.count == 1)
    #expect((removedGroups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/bin/env node /x/other-hook.js Stop")

    let installed = hooksInstall(json: mixedStopGroup, table: claudeHooksTable, command: cmd)
    let installedGroups = groups(installed, "Stop")
    #expect(installedGroups.count == 2)
    #expect((installedGroups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/bin/env node /x/other-hook.js Stop")
    #expect((installedGroups.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String == cmd("done"))
}

// Una chiave di hooks di forma inattesa (dizionario al posto dell'array, es. un editor manuale rotto): hooksInstall
// non deve rimpiazzarla in silenzio, e lo status del risultato non deve dire .installed (I2).
private let unexpectedShape: [String: Any] = ["hooks": ["Stop": ["type": "command"]]]

@Test func installLeavesUnexpectedShapeAlone() {
    let out = hooksInstall(json: unexpectedShape, table: claudeHooksTable, command: cmd)
    let stopValue = (out["hooks"] as? [String: Any])?["Stop"] as? [String: Any] ?? [:]
    #expect(NSDictionary(dictionary: stopValue).isEqual(to: ["type": "command"]))
    #expect(hooksStatus(json: out, table: claudeHooksTable, command: cmd) != .installed)
}

// "hooks" che non è un dizionario non è roba nostra: l'installazione lascia il file com'è (27/9: lo sostituiva).
@Test func installLeavesANonDictionaryHooksValueAlone() {
    for odd: Any in [["x"], "x"] {
        let json: [String: Any] = ["hooks": odd, "model": "opus"]
        let out = hooksInstall(json: json, table: claudeHooksTable, command: cmd)
        #expect(NSDictionary(dictionary: out).isEqual(to: json))
    }
}

// L'I/O vero, in una cartella temporanea (mai ~/.claude né ~/.codex). Un settings.json che è un symlink (dotfile di chezmoi,
// dotbot) resta un link: il file vero tiene le sue chiavi e gli hook altrui più i nostri, e il .bak accanto a lui ha i byte di
// prima. Un JSON rotto fa fallire l'installazione e il file resta com'era.
@Test func installHooksOnDiskKeepsLinksAndNeverBreaksAFile() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("dockduo-hooks-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let target = dir.appendingPathComponent("dotfiles-settings.json"), link = dir.appendingPathComponent("settings.json")
    let original = try JSONSerialization.data(withJSONObject: foreign)
    try original.write(to: target)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    try installHooks(link, claudeHooksTable, cmd)
    #expect(try fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeSymbolicLink)
    let written = try readHooks(target)
    #expect(written["model"] as? String == "opus")
    #expect(groups(written, "Stop").count == 2 && groups(written, "Notification").count == 2)   // l'altrui, poi il nostro
    #expect(hooksStatus(json: written, table: claudeHooksTable, command: cmd) == .installed)
    #expect(try Data(contentsOf: target.appendingPathExtension("bak")) == original)

    let broken = dir.appendingPathComponent("broken.json"), bytes = Data(#"{"model": "opus", "#.utf8)
    try bytes.write(to: broken)
    #expect(throws: (any Error).self) { try installHooks(broken, claudeHooksTable, cmd) }
    #expect(try Data(contentsOf: broken) == bytes)
    #expect(!fm.fileExists(atPath: broken.appendingPathExtension("bak").path))
}

@Test func snakeCaseOfHookEvents() {
    #expect(snakeCase("PreToolUse") == "pre_tool_use")
    #expect(snakeCase("Stop") == "stop")
    #expect(snakeCase("SessionEnd") == "session_end")
}

// La chiave di fiducia che Codex scrive in config.toml: path di hooks.json, evento in snake_case, indice del NOSTRO
// gruppo nell'array dell'evento (dopo quelli altrui), indice del hook (sempre 0: un hook per gruppo).
@Test func codexTrustKeysUseOurGroupIndex() {
    let json = hooksInstall(json: foreign, table: codexHooksTable, command: codexCmd)   // Stop ha un gruppo altrui prima del nostro
    let keys = codexTrustKeys(json: json, hooksPath: "/Users/x/.codex/hooks.json", table: codexHooksTable, command: codexCmd)
    #expect(keys.count == 7)
    #expect(keys.contains("/Users/x/.codex/hooks.json:stop:1:0"))
    #expect(keys.contains("/Users/x/.codex/hooks.json:pre_tool_use:0:0"))
    #expect(codexTrustKeys(json: [:], hooksPath: "/p", table: codexHooksTable, command: codexCmd).isEmpty)
}

@Test func codexApprovedOnlyWhenEveryKeyIsInTheToml() {
    let keys = ["/p/hooks.json:stop:0:0", "/p/hooks.json:session_end:0:0"]
    let toml = """
    [hooks.state]

    [hooks.state."/p/hooks.json:stop:0:0"]
    trusted_hash = "sha256:aa"

    [hooks.state."/p/hooks.json:session_end:0:0"]
    trusted_hash = "sha256:bb"
    """
    #expect(codexApproved(toml: toml, keys: keys, trustWritten: nil, hooksWritten: nil))
    #expect(!codexApproved(toml: toml, keys: keys + ["/p/hooks.json:interrupt:0:0"], trustWritten: nil, hooksWritten: nil))
    #expect(!codexApproved(toml: "", keys: keys, trustWritten: nil, hooksWritten: nil))
    #expect(codexApproved(toml: "", keys: [], trustWritten: nil, hooksWritten: nil))
}

// I3: la fiducia lega l'hash all'hook. Se dockduo riscrive hooks.json (es. path dell'app cambiato dopo un Update)
// dopo l'ultima approvazione, le chiavi restano nel TOML ma non sono più valide: serve riapprovare.
@Test func codexApprovedRequiresTrustNoOlderThanHooks() {
    let keys = ["/p/hooks.json:stop:0:0"]
    let toml = "[hooks.state.\"/p/hooks.json:stop:0:0\"]\ntrusted_hash = \"sha256:aa\""
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)
    // chiavi tutte presenti ma hooks.json più recente della fiducia → non approvato
    #expect(!codexApproved(toml: toml, keys: keys, trustWritten: older, hooksWritten: newer))
    // config.toml più recente (fiducia scritta dopo l'ultimo hooks.json) → approvato
    #expect(codexApproved(toml: toml, keys: keys, trustWritten: newer, hooksWritten: older))
    #expect(codexApproved(toml: toml, keys: keys, trustWritten: newer, hooksWritten: newer))
}

@Test func hookCommandQuotesAPathWithSpaces() {
    let cmd = claudeHookCommand(bundle: URL(fileURLWithPath: "/Users/x/My Apps/dockduo.app"), home: home, state: "done")
    #expect(cmd == "\"$HOME/My Apps/dockduo.app/Contents/Resources/dockduo-hook\" done")
    #expect(!claudeHookCommand(bundle: bundle, home: home, state: "done").contains("\""))   // senza spazi, invariato
}

// Una home con lo spazio: $HOME si espande in due parole, quindi il comando va tra virgolette anche se il percorso
// scritto ("$HOME/…") non ne ha (27/9).
@Test func hookCommandIsQuotedWhenTheHomeHasASpace() {
    let spaced = URL(fileURLWithPath: "/Users/Mario Rossi")
    let cmd = claudeHookCommand(bundle: URL(fileURLWithPath: "/Users/Mario Rossi/Applications/dockduo.app"), home: spaced, state: "done")
    #expect(cmd == "\"$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook\" done")
}


// Siigil e dockduo negli stessi file degli hook (spec dockduo §2): ognuna riconosce solo i suoi comandi. I gruppi di
// Siigil restano primi e intatti, così le chiavi di fiducia di Codex (indice del gruppo) di Siigil non cambiano.
private func siigilCmd(_ state: String) -> String {
    "SIIGIL_AGENT=codex SIIGIL_BUNDLE=com.openai.codex $HOME/Applications/Siigil.app/Contents/Resources/siigil-hook \(state)"
}
private let siigilOnly: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: codexHooksTable.map { row -> (String, Any) in
    (row.event, [["hooks": [["type": "command", "command": siigilCmd(row.state)]]]])
})]

@Test func removingOurHooksKeepsSiigilsInPlace() {
    #expect(hooksStatus(json: siigilOnly, table: codexHooksTable, command: codexCmd) == .notInstalled)   // non sono nostri
    let both = hooksInstall(json: siigilOnly, table: codexHooksTable, command: codexCmd)
    for row in codexHooksTable {
        let g = groups(both, row.event)
        #expect(g.count == 2)
        #expect((g.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == siigilCmd(row.state))
        #expect((g.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String == codexCmd(row.state))
    }
    #expect(codexTrustKeys(json: both, hooksPath: "/p", table: codexHooksTable, command: codexCmd).allSatisfy { $0.hasSuffix(":1:0") })
    #expect(NSDictionary(dictionary: hooksInstall(json: both, table: codexHooksTable, command: codexCmd)).isEqual(to: both))
    #expect(NSDictionary(dictionary: hooksRemove(json: both)).isEqual(to: siigilOnly))
}
