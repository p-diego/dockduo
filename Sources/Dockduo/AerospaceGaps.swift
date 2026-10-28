import AppKit
import Foundation

// Del config di AeroSpace si riscrivono solo le righe dei lati, gaps.outer.left e .right, così le finestre lasciano posto
// alla barra (spec dockduo §4); gaps.outer.top si legge solo per allineare la barra (outerTopGap), mai si scrive.
// ponytail: scansione per righe, niente parser TOML; non vede chiavi in tabelle inline o su più righe, da rivedere se il config le usa.
// Un config con la tabella [gaps] (outer.left = … sotto di lei) non si scrive: writeGaps rinuncia.
let sideGapKeys = ["left", "right"]
private let gapsKey = "dockduo.aerospace.gapsBefore"
private let gapsMark = "   # dockduo: barra di lato"

// La riga intera (senza a capo) non commentata di gaps.outer.<key>: dopo il nome solo spazi e poi "=".
func gapLine(_ key: String, in toml: String) -> String? {
    let prefix = "gaps.outer.\(key)"
    return toml.components(separatedBy: "\n").first { l in
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix(prefix) && t.dropFirst(prefix.count).drop { $0 == " " || $0 == "\t" }.first == "="
    }
}

// Il margine di partenza dell'utente: gaps.outer.bottom se è un intero, altrimenti 0.
func gapsBase(_ toml: String) -> Int {
    guard let l = gapLine("bottom", in: toml), let eq = l.firstIndex(of: "=") else { return 0 }
    let v = l[l.index(after: eq)...].split(separator: "#", omittingEmptySubsequences: false)[0]
    return Int(v.trimmingCharacters(in: .whitespaces)) ?? 0
}

// Dal lato della barra base + margine dai bordi + larghezza, dall'altro la base. Col nascondi automatico la base anche dal
// lato della barra: quando esce passa sopra le finestre, come il Dock di macOS (spec cartelle §4).
func sideGapLines(base: Int, edge: Int, width: Int, side: Side, autohide: Bool = false) -> [String: String] {
    func gap(_ s: Side) -> Int { s == side && !autohide ? base + edge + width : base }
    return ["left": "gaps.outer.left = \(gap(.left))" + gapsMark, "right": "gaps.outer.right = \(gap(.right))" + gapsMark]
}

// Il margine in alto che AeroSpace usa su uno schermo (gaps.outer.top): un numero per tutti, o per monitor
// (`[{ monitor."built-in" = 5 }, 43]`: lo schermo del Mac la sua voce "built-in", gli altri il predefinito in fondo).
// Una forma che qui non si conosce: nil.
func outerTopGap(_ toml: String, builtIn: Bool) -> CGFloat? {
    guard let l = gapLine("top", in: toml), let eq = l.firstIndex(of: "=") else { return nil }
    let value = l[l.index(after: eq)...].split(separator: "#", omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
    func number(_ s: Substring) -> CGFloat? { Double(s.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
    guard value.hasPrefix("["), value.hasSuffix("]") else { return number(Substring(value)) }
    // shortcut: si leggono solo monitor."built-in" e il valore finale; monitor.main/secondary/nomi cadono sul finale — basta per la config dell'autore, da estendere se serve
    let list = value.dropFirst().dropLast()
    if builtIn, let r = list.range(of: #"monitor."built-in""#) {
        return number(list[r.upperBound...].drop { $0 == " " || $0 == "=" }.prefix { $0 != "}" && $0 != "," })
    }
    return number(list.split(separator: ",").last ?? "")
}

// nil = togli la riga. Una chiave mancante va prima della prima tabella (dopo una tabella le chiavi puntate ne farebbero parte), o in fondo.
func withGapLines(_ toml: String, _ lines: [String: String?]) -> String {
    var out = toml.components(separatedBy: "\n")
    for key in lines.keys.sorted() {
        let new = lines[key]!
        if let old = gapLine(key, in: toml), let i = out.firstIndex(of: old) {
            if let new { out[i] = new } else { out.remove(at: i) }
        } else if let new {
            let table = out.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            out.insert(new, at: table ?? (out.last == "" ? out.count - 1 : out.count))
        }
    }
    return out.joined(separator: "\n")
}

// Scrive il testo nuovo (writeGaps); con `reload` prima la prova (dry-run) e, se fallisce, rimette il vecchio. Senza `reload` (AeroSpace spento) scrive e basta.
private func apply(_ new: String, old: String, real: URL, reload: ((Bool) -> Bool)?) -> Bool {
    guard new != old else { return true }
    guard (try? new.write(to: real, atomically: true, encoding: .utf8)) != nil else { return false }
    guard let reload else { return true }
    if !reload(true) { try? old.write(to: real, atomically: true, encoding: .utf8); return false }
    return reload(false)
}

// Il config di serie dentro AeroSpace.app (`config --config-path` senza un config dell'utente) non si scrive mai: si
// romperebbe la firma dell'app.
private func insideApp(_ real: URL) -> Bool {
    guard real.pathComponents.contains(where: { $0.hasSuffix(".app") }) else { return false }
    logger.error("gaps AeroSpace: il config è dentro un'app, non si tocca")
    return true
}

func writeGaps(_ lines: [String: String?], to file: URL, defaults: UserDefaults, reload: ((_ dryRun: Bool) -> Bool)?) -> Bool {
    let real = file.resolvingSymlinksInPath()
    guard !insideApp(real), let old = try? String(contentsOf: real, encoding: .utf8) else { return false }
    guard !usesGapsTable(old) else {
        logger.error("gaps AeroSpace: il config usa la tabella [gaps], non si tocca")
        return false
    }
    if defaults.object(forKey: gapsKey) == nil {
        // Una riga già nostra (salvataggio perso con le righe ancora nel file) non è dell'utente: si salva la base.
        defaults.set(Dictionary(uniqueKeysWithValues: sideGapKeys.map { k in
            let l = gapLine(k, in: old) ?? ""
            return (k, l.hasSuffix(gapsMark) ? "gaps.outer.\(k) = \(gapsBase(old))" : l)
        }), forKey: gapsKey)
        let backup = URL(fileURLWithPath: real.path + ".dockduo-backup")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: real, to: backup) }
    }
    return apply(withGapLines(old, lines), old: old, real: real, reload: reload)
}

// Una tabella [gaps] o [gaps.…] (anche con un commento dopo): le righe gaps.outer.* sotto di lei vorrebbero dire altro.
func usesGapsTable(_ toml: String) -> Bool {
    toml.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[gaps") }
}

func restoreGaps(to file: URL, defaults: UserDefaults, reload: ((Bool) -> Bool)?) -> Bool {
    guard let saved = defaults.dictionary(forKey: gapsKey) as? [String: String] else { return true }
    let real = file.resolvingSymlinksInPath()
    guard !insideApp(real), let old = try? String(contentsOf: real, encoding: .utf8), !usesGapsTable(old) else { return false }
    let lines = saved.filter { sideGapKeys.contains($0.key) }.mapValues { $0.isEmpty ? nil : Optional($0) }   // mai la riga in alto
    let new = withGapLines(old, lines)
    // Le righe di prima sono dell'utente e funzionavano già: niente prova (dry-run), che con AeroSpace muto le lascerebbe
    // le nostre (24/10). La ricarica è solo un tentativo: se fallisce il file resta ripristinato.
    guard new == old || (try? new.write(to: real, atomically: true, encoding: .utf8)) != nil else { return false }
    defaults.removeObject(forKey: gapsKey)
    if new != old, let reload, !reload(false) { logger.error("gaps AeroSpace: ricarica dopo il ripristino fallita") }
    return true
}

// Seriale: due sync che si sovrappongono rileggerebbero e riscriverebbero il config a metà l'uno dell'altro.
private let gapsQueue = DispatchQueue(label: "com.dockduo.aerospace-gaps", qos: .utility)

// L'ultimo config trovato (avvio, sync, rilettura), per l'uscita: lì AeroSpace può non rispondere. Solo sulla gapsQueue.
private var knownConfigURL: URL?
private func findConfigURL() -> URL? {
    knownConfigURL = aerospaceConfigURL() ?? knownConfigURL
    return knownConfigURL
}

// Il config che AeroSpace sta usando; se non risponde, il primo dei due percorsi classici che esiste.
// Bloccante (shell): mai sul main.
func aerospaceConfigURL() -> URL? {
    if let p = shell(aerospacePath, ["config", "--config-path"])?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return URL(fileURLWithPath: p) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [".aerospace.toml", ".config/aerospace/aerospace.toml"].map { home.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

// Il testo del config, letto sulla coda (bloccante) e consegnato sul main; "" se non c'è.
func readAerospaceConfig(_ done: @escaping (String) -> Void) {
    gapsQueue.async {
        let text = findConfigURL().flatMap { try? String(contentsOf: $0.resolvingSymlinksInPath(), encoding: .utf8) } ?? ""
        DispatchQueue.main.async { done(text) }
    }
}

// Con AeroSpace acceso la prova (dry-run) e poi la ricarica, ognuna entro `timeout` s; spento nil: si scrive il file e basta.
private func aerospaceReload(timeout: TimeInterval = 5) -> ((Bool) -> Bool)? {
    aerospaceRunning() ? { dry in shell(aerospacePath, dry ? ["reload-config", "--dry-run", "--no-gui"] : ["reload-config", "--no-gui"], timeout: timeout) != nil } : nil
}

// Impostazioni lette sul main, file e `aerospace` (bloccanti) su una coda di fondo. A ogni avvio anche: dopo un'uscita
// forzata le righe sono ancora le nostre e le righe di prima già salvate (writeGaps non le risalva).
@MainActor func syncAerospaceGaps() {
    let s = Settings.shared
    let (side, edge, width, autohide) = (s.barSide, Int(barEdge), Int(s.sideWidth), s.autohide)
    gapsQueue.async {
        guard let url = findConfigURL() else { return logger.error("gaps AeroSpace: config non trovato") }
        let text = (try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
        let lines = sideGapLines(base: gapsBase(text), edge: edge, width: width, side: side, autohide: autohide)
        if !writeGaps(lines, to: url, defaults: .standard, reload: aerospaceReload()) { logger.error("gaps AeroSpace: scrittura o ricarica fallita") }
    }
}

// All'uscita (spec dockduo §4) i lati tornano quelli di prima prima che l'app esca, anche se AeroSpace non risponde: sulla
// coda seriale, dopo un sync già in coda; il percorso è quello già trovato e la sola ricarica ha 2 s.
func restoreGapsAtQuit() {
    gapsQueue.sync {
        guard UserDefaults.standard.object(forKey: gapsKey) != nil else { return }   // dopo il sync in coda, che può averle salvate
        guard let url = knownConfigURL ?? aerospaceConfigURL(), restoreGaps(to: url, defaults: .standard, reload: aerospaceReload(timeout: 2)) else {
            return logger.error("gaps AeroSpace: ripristino all'uscita fallito")
        }
    }
}
