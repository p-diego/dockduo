import AppKit
import Foundation

// Del config di AeroSpace si riscrivono solo i margini esterni gaps.outer.left, .right e .bottom, così le finestre lasciano
// posto alla barra (spec app conclusa §2.4): dal lato della barra il valore dell'utente con la barra aggiunta a ogni numero,
// anche per schermo; gli altri lati tornano le righe dell'utente. gaps.outer.top si legge solo per allineare la barra
// (gapValue), mai si scrive. Scansione per righe, niente parser TOML: una voce finisce alla riga dove le sue parentesi si
// chiudono. Le forme che la scansione non capisce (la tabella [gaps], gaps = {…} in una riga, valori che non sono numeri o
// elenchi per schermo) non si scrivono: writeGaps rinuncia (.unknownForm) e il file resta com'è.
let sideGapKeys = ["left", "right", "bottom"]
private let gapsKey = "dockduo.aerospace.gapsBefore"
private let gapsMark = "   # dockduo: barra di lato"

// Perché dockduo non riesce a fare posto alla barra (spec app conclusa §2.3): allora la barra si nasconde da sola.
enum SpaceProblem: Equatable { case notInstalled, notOpen, noUserConfig, unknownForm, rejected }

// Una voce gaps.outer.<key>: le sue righe nel file e il valore senza commenti, su una riga sola.
struct GapEntry: Equatable { let lines: Range<Int>; let value: String }
// `monitor`: main, secondary, un numero da 1, o il nome fra virgolette senza virgolette (built-in, un'espressione sul nome).
struct MonitorGap: Equatable { let monitor: String; let value: Int }
// Un numero per tutti (solo `fallback`) o per schermo, con in fondo il valore per gli altri schermi.
struct GapValue: Equatable { var perMonitor: [MonitorGap]; var fallback: Int? }

// La riga (senza spazi ai lati) assegna `key`: dopo il nome solo spazi e poi "=".
private func assigns(_ t: String, _ key: String) -> Bool {
    t.hasPrefix(key) && t.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }.first == "="
}

// Il testo prima del commento (# fuori dalle virgolette) e quante parentesi lascia aperte ([ e { meno ] e }).
private func scan(_ line: Substring) -> (code: Substring, depth: Int) {
    var quote: Character?, escaped = false, depth = 0
    for i in line.indices {
        let c = line[i]
        if let q = quote {
            if escaped { escaped = false } else if c == "\\" && q == "\"" { escaped = true } else if c == q { quote = nil }
        } else if c == "#" { return (line[..<i], depth) }
        else if c == "\"" || c == "'" { quote = c }
        else if c == "[" || c == "{" { depth += 1 }
        else if c == "]" || c == "}" { depth -= 1 }
    }
    return (line, depth)
}

// La voce non commentata di gaps.outer.<key>, con tutte le sue righe quando un elenco [ va a capo; `closed` falso se le
// parentesi non si chiudono prima della fine del file.
private func scanEntry(_ key: String, in toml: String) -> (entry: GapEntry, closed: Bool)? {
    let lines = toml.components(separatedBy: "\n")
    guard let first = lines.firstIndex(where: { assigns($0.trimmingCharacters(in: .whitespaces), "gaps.outer.\(key)") }) else { return nil }
    var parts: [String] = [], depth = 0, end = first
    for i in first..<lines.count {
        let line = lines[i][...]
        let (code, open) = scan(i == first ? line[line.index(after: line.firstIndex(of: "=")!)...] : line)
        parts.append(code.trimmingCharacters(in: .whitespaces))
        (depth, end) = (depth + open, i)
        if depth <= 0 { break }
    }
    return (GapEntry(lines: first..<end + 1, value: parts.filter { !$0.isEmpty }.joined(separator: " ")), depth <= 0)
}

// La voce di gaps.outer.<key>. Una che non si chiude fino alla fine del file non è una voce ma una forma sconosciuta
// (unknownGapsForm): con dentro il resto del file, riscriverla lo cancellerebbe.
func gapEntry(_ key: String, in toml: String) -> GapEntry? {
    scanEntry(key, in: toml).flatMap { $0.closed ? $0.entry : nil }
}

// Le righe intere della voce, com'erano nel file; "" se manca.
private func entryText(_ key: String, in toml: String) -> String {
    gapEntry(key, in: toml).map { toml.components(separatedBy: "\n")[$0.lines].joined(separator: "\n") } ?? ""
}

// Un numero, o un elenco di { monitor.<schermo> = n } con in fondo, se c'è, il numero per gli altri (virgola finale
// compresa). Ogni altra forma (anche `monitor = { … }`, che AeroSpace capisce): nil, dockduo non la sa modificare.
func parseGapValue(_ value: String) -> GapValue? {
    let v = value.trimmingCharacters(in: .whitespaces)
    if let n = Int(v) { return GapValue(perMonitor: [], fallback: n) }
    guard v.hasPrefix("["), v.hasSuffix("]") else { return nil }
    var rest = v.dropFirst().dropLast(), out = GapValue(perMonitor: [], fallback: nil)
    let item = #/\s*\{\s*monitor\.(?:"((?:[^"\\]|\\["\\])*)"|'([^']*)'|([A-Za-z0-9_-]+))\s*=\s*([+-]?\d+)\s*\}\s*(?:,|$)/#
    while let m = rest.prefixMatch(of: item), let n = Int(m.4) {
        out.perMonitor.append(MonitorGap(monitor: m.1.map { String($0.replacing(#/\\(["\\])/#) { $0.1 }) } ?? String(m.2 ?? m.3!), value: n))
        rest = rest[m.range.upperBound...]
    }
    if let m = rest.wholeMatch(of: #/\s*([+-]?\d+)\s*,?\s*/#), let n = Int(m.1) { (out.fallback, rest) = (n, "") }
    return rest.allSatisfy(\.isWhitespace) && !out.perMonitor.isEmpty ? out : nil
}

// Su una riga: `5` o `[{ monitor.main = 89 }, 97]`; i nomi fra virgolette, come nella guida di AeroSpace.
func gapText(_ v: GapValue) -> String {
    if v.perMonitor.isEmpty, let n = v.fallback { return "\(n)" }
    let items = v.perMonitor.map { g in
        let key = g.monitor.wholeMatch(of: #/main|secondary|\d+/#) != nil ? g.monitor
            : "\"" + g.monitor.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
        return "{ monitor.\(key) = \(g.value) }"
    }
    return "[" + (items + (v.fallback.map { ["\($0)"] } ?? [])).joined(separator: ", ") + "]"
}

// `n` in più a ogni numero, di ogni schermo e degli altri.
func widened(_ v: GapValue, by n: Int) -> GapValue {
    GapValue(perMonitor: v.perMonitor.map { MonitorGap(monitor: $0.monitor, value: $0.value + n) }, fallback: v.fallback.map { $0 + n })
}

// Uno schermo come lo vede AeroSpace: il nome, il numero da sinistra a destra (da 1), main (quello con la barra dei menu),
// secondary (l'altro, quando gli schermi sono due), built-in (quello del Mac).
struct MonitorFacts { let name: String; let number: Int; let isMain: Bool; let isBuiltIn: Bool; let isSecondary: Bool }
extension MonitorFacts {
    // shortcut: a pari x i numeri vanno dall'alto, come pare ordini AeroSpace; non provato con schermi uno sopra l'altro.
    init(_ screen: NSScreen) {
        let all = NSScreen.screens.map(\.frame), display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let order = all.sorted { ($0.minX, -$0.maxY) < ($1.minX, -$1.maxY) }
        self.init(name: screen.localizedName, number: (order.firstIndex(of: screen.frame) ?? 0) + 1, isMain: screen.frame == all.first,
                  isBuiltIn: CGDisplayIsBuiltin(display) != 0, isSecondary: all.count == 2 && screen.frame != all.first)
    }
}

// Il valore su uno schermo come lo sceglie AeroSpace: la prima voce che gli corrisponde (un nome qualunque è un'espressione
// sul nome dello schermo, maiuscole e minuscole uguali), altrimenti il valore finale; nil se non c'è.
func gapValue(_ v: GapValue, on m: MonitorFacts) -> Int? {
    v.perMonitor.first { g in
        switch g.monitor {
        case "main": m.isMain
        case "secondary": m.isSecondary
        case "built-in": m.isBuiltIn
        default: Int(g.monitor).map { $0 == m.number } ?? (m.name.range(of: g.monitor, options: [.regularExpression, .caseInsensitive]) != nil)
        }
    }?.value ?? v.fallback
}

// Le righe di dockduo sono solo quelle col suo segno in fondo, anche se un formattatore ha cambiato gli spazi prima del #:
// presa per dell'utente, la riga allargata farebbe da base e crescerebbe a ogni sync.
private func ours(_ entry: String) -> Bool { entry.hasSuffix(gapsMark.drop { $0 == " " }) }

// Salvataggio perso con le righe nostre ancora nel file: la base è il margine in basso se è un numero dell'utente, altrimenti 0.
func gapsBase(_ toml: String) -> Int {
    let bottom = entryText("bottom", in: toml)
    return ours(bottom) ? 0 : gapEntry("bottom", in: bottom).flatMap { Int($0.value) } ?? 0
}

// nil = togli la voce, tutte le sue righe. Una chiave mancante va prima della prima tabella (dopo una tabella le chiavi
// puntate ne farebbero parte), o in fondo.
func withGapLines(_ toml: String, _ lines: [String: String?]) -> String {
    var text = toml
    for key in lines.keys.sorted() {
        let new = lines[key]!
        var out = text.components(separatedBy: "\n")
        if let old = gapEntry(key, in: text) {
            out.replaceSubrange(old.lines, with: new.map { [$0] } ?? [])
        } else if let new {
            let table = out.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            out.insert(new, at: table ?? (out.last == "" ? out.count - 1 : out.count))
        }
        text = out.joined(separator: "\n")
    }
    return text
}

// Le righe salvate dei lati (mai una riga in alto); "" = la riga non c'era e si toglie.
private func savedLines(_ saved: [String: String]) -> [String: String?] {
    saved.filter { sideGapKeys.contains($0.key) }.mapValues { $0.isEmpty ? nil : Optional($0) }
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

// Fa posto alla barra sul lato `side` (a sinistra, a destra o in basso: la chiave è il suo nome); nil = fatto. Sono di
// dockduo solo le righe col segno (gapsMark): le altre sono dell'utente e si salvano a ogni scrittura com'è il file adesso,
// intere ("" se mancano), così un suo cambio mentre dockduo gira resta; quelle col segno tengono il salvataggio di quando
// erano sue. Dal lato della barra il valore dell'utente allargato di bordo + `width`, lo spessore della barra (in basso la
// sua altezza; una riga che manca è lo 0 di AeroSpace); col nascondi automatico com'è: quando esce, la barra passa sopra le
// finestre come il Dock di macOS (spec cartelle §4). Gli altri due lati tornano le righe dell'utente.
func writeGaps(side: Side, edge: Int, width: Int, autohide: Bool, to file: URL, defaults: UserDefaults,
               reload: ((_ dryRun: Bool) -> Bool)?) -> SpaceProblem? {
    let real = file.resolvingSymlinksInPath()
    guard !insideApp(real) else { return .noUserConfig }
    guard let old = try? String(contentsOf: real, encoding: .utf8), !unknownGapsForm(old) else {
        logger.error("gaps AeroSpace: config illeggibile o margini in una forma sconosciuta, non si tocca")
        return .unknownForm
    }
    let before = defaults.dictionary(forKey: gapsKey) as? [String: String]
    var saved = before ?? [:]
    for k in sideGapKeys {
        // Una riga senza segno è dell'utente com'è adesso, anche cambiata o aggiunta mentre dockduo gira. Una nostra tiene il
        // salvataggio; senza (perso con le righe ancora nel file) si salva la base.
        let text = entryText(k, in: old)
        if !ours(text) { saved[k] = text } else if saved[k] == nil { saved[k] = "gaps.outer.\(k) = \(gapsBase(old))" }
    }
    var lines = savedLines(saved)
    let k = side.rawValue, mine = saved[k]!
    guard let user = mine.isEmpty ? GapValue(perMonitor: [], fallback: 0) : gapEntry(k, in: mine).flatMap({ parseGapValue($0.value) }) else {
        logger.error("gaps AeroSpace: margine in una forma che dockduo non sa modificare, non si tocca")
        // Le righe dell'utente restano come sono; le nostre, di un lato allargato prima, tornano le sue come all'uscita.
        _ = apply(withGapLines(old, lines), old: old, real: real, reload: reload)
        return .unknownForm
    }
    if before == nil {
        let backup = URL(fileURLWithPath: real.path + ".dockduo-backup")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: real, to: backup) }
    }
    if saved != before { defaults.set(saved, forKey: gapsKey) }
    lines[k] = "gaps.outer.\(k) = \(gapText(widened(user, by: autohide ? 0 : edge + width)))" + gapsMark
    return apply(withGapLines(old, lines), old: old, real: real, reload: reload) ? nil : .rejected
}

// Margini che la scansione per righe non sa modificare, e il file non si tocca: in una tabella, [gaps] o [gaps.…] (anche
// con un commento dopo, con sotto righe che vorrebbero dire altro) o in una riga sola (gaps = {…}, gaps.outer = {…}); o una
// voce, anche quella in alto che si terrebbe dentro i lati, che apre una parentesi e non la chiude più (gapEntry).
func unknownGapsForm(_ toml: String) -> Bool {
    toml.components(separatedBy: "\n").contains { l in
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[gaps") || assigns(t, "gaps") || assigns(t, "gaps.outer")
    } || (sideGapKeys + ["top"]).contains { scanEntry($0, in: toml)?.closed == false }
}

func restoreGaps(to file: URL, defaults: UserDefaults, reload: ((Bool) -> Bool)?) -> Bool {
    guard let saved = defaults.dictionary(forKey: gapsKey) as? [String: String] else { return true }
    let real = file.resolvingSymlinksInPath()
    guard !insideApp(real), let old = try? String(contentsOf: real, encoding: .utf8), !unknownGapsForm(old) else { return false }
    // Solo le righe col segno sono nostre e tornano quelle salvate; le altre sono dell'utente com'è adesso.
    let new = withGapLines(old, savedLines(saved.filter { ours(entryText($0.key, in: old)) }))
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

// Impostazioni lette sul main, file e `aerospace` (bloccanti) su una coda di fondo; `done` sul main col motivo per cui lo
// spazio non c'è (nil = c'è). AeroSpace spento: non si scrive, si rifà quando si accende (Poller.connectEvents). A ogni
// avvio anche: dopo un'uscita forzata le righe sono ancora le nostre e le righe di prima già salvate (writeGaps non le risalva).
@MainActor func syncAerospaceGaps(_ done: @escaping @MainActor (SpaceProblem?) -> Void) {
    let s = Settings.shared
    let (side, edge, width, autohide) = (s.barSide, Int(barEdge), Int(s.sideWidth), s.autohide)
    gapsQueue.async {
        let problem: SpaceProblem? = if !aerospaceRunning() { aerospaceInstalled() ? .notOpen : .notInstalled }
            else if let url = findConfigURL() {
                writeGaps(side: side, edge: edge, width: width, autohide: autohide, to: url, defaults: .standard, reload: aerospaceReload())
            } else { .noUserConfig }
        if let problem { logger.error("gaps AeroSpace: nessuno spazio per la barra (\(String(describing: problem)))") }
        DispatchQueue.main.async { done(problem) }
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
