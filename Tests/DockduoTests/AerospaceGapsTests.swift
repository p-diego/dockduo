import Foundation
import Testing
@testable import Dockduo

private let config = """
start-at-login = true
gaps.inner.horizontal = 5
gaps.outer.left =       5
gaps.outer.bottom =     5
gaps.outer.top =        [{ monitor."built-in" = 5 }, 43]   # schermi senza notch: 38 pt di barra Siigil + 5
gaps.outer.right =      5

[workspace-to-monitor-force-assignment]
    1 = 'built-in'
"""
// La barra a destra larga 52, a 6 dal bordo: a destra 5 + 58, gli altri lati come li aveva l'utente.
private let written = config.replacingOccurrences(of: "gaps.outer.right =      5", with: "gaps.outer.right = 63   # dockduo: barra di lato")
private let gapsBefore = "dockduo.aerospace.gapsBefore"
private func write(_ file: URL, _ d: UserDefaults, side: Side = .right, autohide: Bool = false,
                   reload: ((Bool) -> Bool)? = nil) -> SpaceProblem? {
    writeGaps(side: side, edge: 6, width: 52, autohide: autohide, to: file, defaults: d, reload: reload)
}
private func saved(_ d: UserDefaults) -> [String: String]? { d.dictionary(forKey: gapsBefore) as? [String: String] }

// Cartella temporanea con real.toml (il testo dato) e link.toml che ci punta; mai il vero ~/.aerospace.toml.
private func tmp(_ text: String) throws -> (dir: URL, real: URL, link: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let real = dir.appendingPathComponent("real.toml"), link = dir.appendingPathComponent("link.toml")
    try text.write(to: real, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    return (dir, real, link)
}

// Il file dell'autore com'è oggi (~/.aerospace.toml, righe 80-85): i lati già scritti da una versione di prima, il
// salvataggio con sinistra e destra e senza il basso.
private let authors = """
gaps.inner.horizontal = 5
gaps.inner.vertical =   5
gaps.outer.left = 78   # dockduo: barra di lato
gaps.outer.bottom =     5
gaps.outer.top =        [{ monitor."built-in" = 5 }, 43]   # schermi senza notch: 38 pt di barra Siigil + 5
gaps.outer.right = 5   # dockduo: barra di lato
"""
// Margini per schermo, su più righe, con commenti e virgolette; la destra manca (lo 0 di AeroSpace).
private let perMonitor = """
start-at-login = true
gaps.outer.left = [   # per schermo
    { monitor."built-in" = 5 },   # il Mac
    { monitor.'DELL.*' = 12 },
    8,
]
gaps.outer.bottom = [{ monitor.main = 16 }, 24]   # in basso
# gaps.outer.right = 99
gaps.outer.top = 10

[mode.main.binding]
    alt-h = 'focus left'
"""

// Il caso dell'autore (spec app conclusa §2.4): la barra a sinistra larga 71 (73 col bordo) sopra il suo 5; la destra
// torna la sua riga di prima, il basso si salva dal file com'è, che dockduo non ha mai scritto.
@Test func theAuthorsFileKeepsItsMargins() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(authors); defer { try? FileManager.default.removeItem(at: dir) }
    d.set(["left": "gaps.outer.left =       5", "right": "gaps.outer.right =      5"], forKey: gapsBefore)
    #expect(writeGaps(side: .left, edge: 2, width: 71, autohide: false, to: real, defaults: d, reload: nil) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == authors.replacingOccurrences(
        of: "gaps.outer.right = 5   # dockduo: barra di lato", with: "gaps.outer.right =      5"))
    #expect(saved(d) == ["left": "gaps.outer.left =       5", "right": "gaps.outer.right =      5", "bottom": "gaps.outer.bottom =     5"])
    #expect(!FileManager.default.fileExists(atPath: real.path + ".dockduo-backup"))   // il salvataggio c'era già
}
// Ogni numero della riga dell'utente si allarga della barra, il valore per schermo resta per schermo.
@Test func perMonitorValuesAreWidenedNotFlattened() throws {
    let v = try #require(parseGapValue("[{ monitor.main = 16 }, 24]"))
    #expect(v == GapValue(perMonitor: [MonitorGap(monitor: "main", value: 16)], fallback: 24))
    #expect(gapText(widened(v, by: 73)) == "[{ monitor.main = 89 }, 97]")
    #expect(gapText(widened(try #require(parseGapValue("5")), by: 73)) == "78")
    // Un nome con virgolette e barre fra virgolette doppie torna scritto uguale.
    let escaped = #"[{ monitor."a\"b\\c" = 1 }, 2]"#
    let e = try #require(parseGapValue(escaped))
    #expect(e.perMonitor == [MonitorGap(monitor: #"a"b\c"#, value: 1)] && gapText(e) == escaped)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp("gaps.outer.right = [{ monitor.main = 16 }, 24]\n"); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(side: .right, edge: 2, width: 71, autohide: false, to: real, defaults: d, reload: nil) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == "gaps.outer.right = [{ monitor.main = 89 }, 97]   # dockduo: barra di lato\n")
}
// Un elenco spezzato su più righe è una voce sola fino alla parentesi che lo chiude; i commenti non contano, la riga
// commentata non è una voce.
@Test func aMultiLineValueIsReadWhole() throws {
    let e = try #require(gapEntry("left", in: perMonitor))
    #expect(e.lines == 1..<6)
    #expect(e.value == #"[ { monitor."built-in" = 5 }, { monitor.'DELL.*' = 12 }, 8, ]"#)
    #expect(parseGapValue(e.value) == GapValue(perMonitor: [MonitorGap(monitor: "built-in", value: 5), MonitorGap(monitor: "DELL.*", value: 12)], fallback: 8))
    #expect(gapEntry("right", in: perMonitor) == nil)
    #expect(gapEntry("bottom", in: perMonitor) == GapEntry(lines: 6..<7, value: "[{ monitor.main = 16 }, 24]"))
    #expect(gapEntry("top", in: #"gaps.outer.top = [{ monitor."a#b" = 1 }, 2]  # nota"#)?.value == #"[{ monitor."a#b" = 1 }, 2]"#)
}
// Scrivere da un lato, poi dall'altro, poi ripristinare: il file dell'utente torna identico, byte per byte.
@Test func aRoundTripGivesTheUserFileBack() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(perMonitor); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d, side: .left) == nil)
    let left = try String(contentsOf: real, encoding: .utf8)
    #expect(gapEntry("left", in: left)?.value == #"[{ monitor."built-in" = 63 }, { monitor."DELL.*" = 70 }, 66]"#)
    #expect(left.contains("gaps.outer.bottom = [{ monitor.main = 16 }, 24]   # in basso") && gapEntry("right", in: left) == nil)
    #expect(write(real, d, side: .right) == nil)
    let right = try String(contentsOf: real, encoding: .utf8)
    #expect(right.contains("gaps.outer.top = 10\n\ngaps.outer.right = 58   # dockduo: barra di lato\n[mode.main.binding]"))
    #expect(right.contains("gaps.outer.left = [   # per schermo\n    { monitor.\"built-in\" = 5 },   # il Mac\n"))
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == perMonitor)
}
// Forme che la scansione per righe non sa modificare: il file resta com'è e non si salva niente (spec §2.4: mai un file rotto).
@Test func unknownFormsAreLeftAlone() throws {
    for text in ["start-at-login = true\n\n  [gaps]  \nouter.left = 5\nouter.right = 5\n", "gaps.outer = { left = 5 }\n",
                 "gaps = { outer = { left = 5 } }\n", "gaps.outer.left = \"x\"\n"] {
        let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
        let (dir, real, _) = try tmp(text); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(write(real, d, side: .left) == .unknownForm)
        #expect(try String(contentsOf: real, encoding: .utf8) == text && d.object(forKey: gapsBefore) == nil)
        #expect(!FileManager.default.fileExists(atPath: real.path + ".dockduo-backup"))
    }
    #expect(parseGapValue("[]") == nil && parseGapValue("5.5") == nil && parseGapValue("[{ monitor = { main = 5 } }, 3]") == nil)
}
// Un elenco che apre [ e non si chiude più si prenderebbe il resto del file, e riscriverlo lo cancellerebbe: è una forma
// sconosciuta, né la scrittura (con o senza salvataggio, da ogni lato) né il ripristino toccano il file.
@Test func anUnclosedBracketLeavesTheFileAlone() throws {
    let broken = "gaps.outer.left = [ { monitor.main = 5 },\ngaps.outer.right = 5\n\n[mode.main.binding]\n    alt-h = 'focus left'\n"
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(broken); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(gapEntry("left", in: broken) == nil)
    #expect(write(real, d, side: .left) == .unknownForm && write(real, d, side: .right) == .unknownForm)
    #expect(d.object(forKey: gapsBefore) == nil && !FileManager.default.fileExists(atPath: real.path + ".dockduo-backup"))
    let before = ["left": "gaps.outer.left = 5", "right": "gaps.outer.right = 5", "bottom": ""]
    d.set(before, forKey: gapsBefore)
    #expect(write(real, d, side: .left) == .unknownForm && saved(d) == before)
    #expect(!restoreGaps(to: real, defaults: d, reload: nil) && saved(d) == before)
    #expect(try String(contentsOf: real, encoding: .utf8) == broken)
}
// Il margine in alto si sceglie come AeroSpace: la prima voce che vale per lo schermo, altrimenti il valore finale.
@Test func theTopGapFollowsAerospacesMatching() throws {
    func screen(_ name: String = "DELL U2720Q", number: Int = 2, main: Bool = false, builtIn: Bool = false, secondary: Bool = false) -> MonitorFacts {
        MonitorFacts(name: name, number: number, isMain: main, isBuiltIn: builtIn, isSecondary: secondary)
    }
    let v = try #require(parseGapValue(#"[{ monitor."built-in" = 5 }, { monitor.main = 10 }, 43]"#))
    #expect(gapValue(v, on: screen("Built-in Retina Display", number: 1, main: true, builtIn: true)) == 5)
    #expect(gapValue(v, on: screen(number: 1, main: true)) == 10)
    #expect(gapValue(v, on: screen(secondary: true)) == 43)
    let main = try #require(parseGapValue("[{ monitor.main = 16 }]"))
    #expect(gapValue(main, on: screen(secondary: true)) == nil && gapValue(main, on: screen(main: true)) == 16)
    let named = try #require(parseGapValue(#"[{ monitor.secondary = 1 }, { monitor.3 = 2 }, { monitor.'dell.*q' = 3 }, 4]"#))
    #expect(gapValue(named, on: screen(secondary: true)) == 1 && gapValue(named, on: screen(number: 3)) == 2)
    #expect(gapValue(named, on: screen()) == 3 && gapValue(named, on: screen("LG")) == 4)
    #expect(gapValue(try #require(parseGapValue("8")), on: screen()) == 8)
}
@Test func readsTheGapsEntryAndTheBase() {
    #expect(gapEntry("top", in: config) == GapEntry(lines: 4..<5, value: #"[{ monitor."built-in" = 5 }, 43]"#))
    #expect(gapsBase(config) == 5 && gapsBase("gaps.outer.bottom = [{ monitor.main = 8 }, 5]") == 0 && gapsBase("") == 0)
    #expect(gapsBase("gaps.outer.bottom = 80   # dockduo: barra di lato") == 0)   // il basso nostro non è la base
}
// La barra a destra: lo spazio solo da quel lato, gli altri restano le righe dell'utente; la riga in alto non si scrive mai.
@Test func onlyTheBarSideIsWidened() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == written)
    #expect(write(real, d, side: .left) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == config.replacingOccurrences(
        of: "gaps.outer.left =       5", with: "gaps.outer.left = 63   # dockduo: barra di lato"))
}
// La barra in basso, alta 71 a 2 dal bordo (spec app conclusa §3.2): il basso è quello dell'utente più 73, la destra
// scritta prima torna la sua riga, la sinistra resta la sua.
@Test func theBottomGapIsWidened() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(writeGaps(side: .bottom, edge: 2, width: 71, autohide: false, to: real, defaults: d, reload: nil) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == config.replacingOccurrences(
        of: "gaps.outer.bottom =     5", with: "gaps.outer.bottom = 78   # dockduo: barra di lato"))
}
// La riga in alto dell'autore (per monitor) resta identica, byte per byte, dopo la scrittura e dopo il ripristino.
@Test func theTopLineIsNeverTouched() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(gapEntry("top", in: try String(contentsOf: real, encoding: .utf8)) == gapEntry("top", in: config))
    #expect(saved(d)?.keys.sorted() == ["bottom", "left", "right"])
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
    // Una riga in alto nel salvataggio (dockduo non la salva mai) non si scrive né si ripristina: solo i lati.
    #expect(write(real, d) == nil)
    var s = saved(d)!
    s["top"] = "gaps.outer.top = 99"
    d.set(s, forKey: gapsBefore)
    #expect(write(real, d) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == written)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
}
// All'uscita le righe tornano quelle di prima e il salvataggio sparisce; all'avvio dopo si riscrivono e si salvano di nuovo
// (dopo un'uscita forzata invece il salvataggio c'è già e non si rifà: writingFollowsTheSymlinkAndKeepsIt).
@Test func restoreAtQuitThenWriteAtLaunch() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config && d.object(forKey: gapsBefore) == nil)
    #expect(write(real, d) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == written)
    #expect(saved(d)?["right"] == "gaps.outer.right =      5")
    // Un secondo avvio senza uscita (crash): si riscrive, il salvataggio resta quello di prima.
    #expect(writeGaps(side: .right, edge: 6, width: 72, autohide: false, to: real, defaults: d, reload: nil) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8).contains("gaps.outer.right = 83   # dockduo: barra di lato"))
    #expect(saved(d)?["right"] == "gaps.outer.right =      5")
}
@Test func replacesOnlyTheGivenLines() {
    let out = withGapLines(config, ["right": "gaps.outer.right = 63   # dockduo: barra di lato", "left": "gaps.outer.left =       5"])
    #expect(out == written)
    #expect(withGapLines(perMonitor, ["left": "gaps.outer.left = 1"]).components(separatedBy: "\n").count == perMonitor.components(separatedBy: "\n").count - 4)
}
@Test func appendsMissingKeysBeforeTheFirstTable() {
    let noLeft = config.replacingOccurrences(of: "gaps.outer.left =       5\n", with: "")
    let out = withGapLines(noLeft, ["left": "gaps.outer.left = 63   # dockduo: barra di lato"]).components(separatedBy: "\n")
    let i = out.firstIndex(of: "[workspace-to-monitor-force-assignment]")!
    #expect(out[i - 1] == "gaps.outer.left = 63   # dockduo: barra di lato")
    #expect(withGapLines("a = 1\n", ["left": "x = 2"]) == "a = 1\nx = 2\n")
}
@Test func writingFollowsTheSymlinkAndKeepsIt() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, link) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(link, d) == nil)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
    #expect(try String(contentsOf: real, encoding: .utf8) == written)
    #expect(try String(contentsOf: URL(fileURLWithPath: real.path + ".dockduo-backup"), encoding: .utf8) == config)
    #expect(saved(d)?["left"] == "gaps.outer.left =       5" && saved(d)?.count == 3)
}
@Test func aFailedDryRunPutsTheOldTextBack() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d, reload: { dry in !dry }) == .rejected)
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
}
// Il ripristino non chiede la prova (dry-run): con una ricarica che fallisce o va in timeout (AeroSpace muto, 24/10) il
// file torna lo stesso quello di prima, byte per byte, attraverso il link, e il salvataggio sparisce.
@Test func restoreDoesNotNeedTheDryRun() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, link) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(link, d) == nil)
    var asked: [Bool] = []
    #expect(restoreGaps(to: link, defaults: d, reload: { dry in asked.append(dry); return false }))
    #expect(asked == [false])
    #expect(try String(contentsOf: real, encoding: .utf8) == config && d.object(forKey: gapsBefore) == nil)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
}
@Test func restoreWritesTheLinesBackAndRemovesAddedOnes() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let noRight = config.replacingOccurrences(of: "gaps.outer.right =      5\n", with: "")
    let (dir, real, _) = try tmp(noRight); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8).contains("gaps.outer.right = 58   # dockduo: barra di lato"))
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == noRight)
    #expect(d.object(forKey: gapsBefore) == nil)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
}
// Solo le righe col segno sono di dockduo: il basso portato a 10 e una destra aggiunta mentre dockduo gira restano
// dell'utente, al sync dopo e all'uscita; la sinistra della barra torna il suo 5.
@Test func theUsersEditsWhileRunningAreKept() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp("gaps.outer.left = 5\ngaps.outer.bottom = 5\n"); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d, side: .left) == nil)
    let edited = "gaps.outer.left = 63   # dockduo: barra di lato\ngaps.outer.bottom = 10\ngaps.outer.right = 8\n"
    try edited.write(to: real, atomically: true, encoding: .utf8)
    #expect(write(real, d, side: .left) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == edited)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == "gaps.outer.left = 5\ngaps.outer.bottom = 10\ngaps.outer.right = 8\n")
}
// Spazi o un a capo Windows lasciati da un editor dopo il segno: la riga resta di dockduo, si riscrive dal 5 dell'utente
// (63, non 63 + 58) e all'uscita torna il 5.
@Test func ourLineWithTrailingSpacesStaysOurs() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp("gaps.outer.left = 5\ngaps.outer.bottom = 5\n"); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d, side: .left) == nil)
    for tail in ["  ", "\r"] {
        try "gaps.outer.left = 63   # dockduo: barra di lato\(tail)\ngaps.outer.bottom = 5\n".write(to: real, atomically: true, encoding: .utf8)
        #expect(write(real, d, side: .left) == nil)
        #expect(try String(contentsOf: real, encoding: .utf8) == "gaps.outer.left = 63   # dockduo: barra di lato\ngaps.outer.bottom = 5\n")
    }
    try "gaps.outer.left = 63   # dockduo: barra di lato \ngaps.outer.bottom = 5\n".write(to: real, atomically: true, encoding: .utf8)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == "gaps.outer.left = 5\ngaps.outer.bottom = 5\n")
}
// La riga della barra, col segno, è di dockduo e si riscrive a ogni sync dal valore dell'utente: con la barra più larga, e
// anche cambiata a mano col segno lasciato, pure se un formattatore ha tolto gli spazi prima del commento.
@Test func theBarsOwnLineIsRewrittenAtEverySync() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(writeGaps(side: .right, edge: 6, width: 72, autohide: false, to: real, defaults: d, reload: nil) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == config.replacingOccurrences(
        of: "gaps.outer.right =      5", with: "gaps.outer.right = 83   # dockduo: barra di lato"))
    try config.replacingOccurrences(of: "gaps.outer.right =      5", with: "gaps.outer.right = 99 # dockduo: barra di lato")
        .write(to: real, atomically: true, encoding: .utf8)
    #expect(write(real, d) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8) == written)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
}
// Dal lato della barra una forma che dockduo non sa modificare (ma AeroSpace sì): quel lato non si tocca, e il lato allargato
// prima torna la riga dell'utente invece di restare largo.
@Test func anUneditableBarSidePutsOurOtherLineBack() throws {
    let text = config.replacingOccurrences(of: "gaps.outer.left =       5", with: "gaps.outer.left = [{ monitor = { main = 5 } }, 3]")
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(text); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(write(real, d, side: .left) == .unknownForm)
    #expect(try String(contentsOf: real, encoding: .utf8) == text)
}
// Col nascondi automatico le finestre si prendono anche il lato della barra: lì resta il valore dell'utente, come dagli
// altri lati (spec cartelle §4); la barra, quando esce, passa sopra di loro.
@Test func autohideGapIsTheUsersValue() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(perMonitor); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d, side: .left, autohide: true) == nil)
    #expect(gapEntry("left", in: try String(contentsOf: real, encoding: .utf8))?.value == #"[{ monitor."built-in" = 5 }, { monitor."DELL.*" = 12 }, 8]"#)
    #expect(write(real, d, side: .right, autohide: true) == nil)
    #expect(try String(contentsOf: real, encoding: .utf8).contains("gaps.outer.right = 0   # dockduo: barra di lato"))
}
// Le righe nel file sono già nostre ma il salvataggio non c'è (perso): a salvarle si salva la base del file, non il 78
// della barra, che all'uscita tornerebbe come "dell'utente"; il basso, dell'utente, si salva com'è.
@Test func ourOwnLinesAreSavedAsTheBase() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(authors); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(write(real, d) == nil)
    #expect(saved(d) == ["left": "gaps.outer.left = 5", "right": "gaps.outer.right = 5", "bottom": "gaps.outer.bottom =     5"])
}
// Il config di serie dentro AeroSpace.app non si scrive né si ripristina: si romperebbe la firma dell'app.
@Test func aConfigInsideAnAppIsNeverWritten() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, _, _) = try tmp(""); defer { try? FileManager.default.removeItem(at: dir) }
    let inApp = dir.appendingPathComponent("AeroSpace.app/Contents/Resources/default-config.toml")
    try FileManager.default.createDirectory(at: inApp.deletingLastPathComponent(), withIntermediateDirectories: true)
    try config.write(to: inApp, atomically: true, encoding: .utf8)
    #expect(write(inApp, d) == .noUserConfig)
    #expect(try String(contentsOf: inApp, encoding: .utf8) == config && d.object(forKey: gapsBefore) == nil)
    d.set(["left": "gaps.outer.left = 1", "right": ""], forKey: gapsBefore)
    #expect(!restoreGaps(to: inApp, defaults: d, reload: nil))
    #expect(try String(contentsOf: inApp, encoding: .utf8) == config)
}
// Ogni forma di tabella dei margini ([gaps], [gaps.outer], gaps = {…}) e ogni voce che non chiude la sua parentesi, anche
// quella in alto, fermano sia la scrittura sia il ripristino; le chiavi puntate no (autore: gaps.outer.left = 5).
@Test func everyGapsTableStopsTheRewrite() {
    #expect(unknownGapsForm("gaps.outer.top = [{ monitor.main = 5 },\ngaps.outer.left = 5\n") && gapEntry("left", in: "gaps.outer.left = [\n") == nil)
    #expect(unknownGapsForm("[gaps] # margini\nouter.left = 5\n"))
    #expect(unknownGapsForm("[gaps.outer]\nleft = 5\n"))
    #expect(unknownGapsForm("gaps.outer = { left = 5 }\n") && unknownGapsForm("  gaps   = { outer = { left = 5 } }\n"))
    #expect(!unknownGapsForm("gaps.outer.left = 5\n[mode.main.binding]\n"))
}
