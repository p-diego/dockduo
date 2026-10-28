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
private let sideLines = sideGapLines(base: 5, edge: 6, width: 52, side: .right)

// Cartella temporanea con real.toml (il testo dato) e link.toml che ci punta; mai il vero ~/.aerospace.toml.
private func tmp(_ text: String) throws -> (dir: URL, real: URL, link: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let real = dir.appendingPathComponent("real.toml"), link = dir.appendingPathComponent("link.toml")
    try text.write(to: real, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    return (dir, real, link)
}

@Test func readsTheGapsLinesAndTheBase() {
    #expect(gapLine("top", in: config) == #"gaps.outer.top =        [{ monitor."built-in" = 5 }, 43]   # schermi senza notch: 38 pt di barra Siigil + 5"#)
    #expect(gapsBase(config) == 5 && gapsBase("gaps.outer.bottom = [{ monitor.main = 8 }, 5]") == 0 && gapsBase("") == 0)
}
// La barra a destra: lo spazio solo da quel lato, l'altro resta al margine dell'utente; la riga in alto non c'è (spec
// dockduo §4: è di Siigil o dell'autore).
@Test func sideLinesForTheBarSideOnly() {
    let l = sideGapLines(base: 5, edge: 6, width: 52, side: .right)
    #expect(l == ["left": "gaps.outer.left = 5   # dockduo: barra di lato", "right": "gaps.outer.right = 63   # dockduo: barra di lato"])
    #expect(sideGapLines(base: 5, edge: 6, width: 52, side: .left)["left"] == "gaps.outer.left = 63   # dockduo: barra di lato")
}
// La riga in alto dell'autore (per monitor) resta identica, byte per byte, dopo la scrittura e dopo il ripristino.
@Test func theTopLineIsNeverTouched() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    let top = gapLine("top", in: config)!
    #expect(top.hasPrefix(#"gaps.outer.top =        [{ monitor."built-in" = 5 }, 43]   # "#))
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    #expect(gapLine("top", in: try String(contentsOf: real, encoding: .utf8)) == top)
    #expect((d.dictionary(forKey: "dockduo.aerospace.gapsBefore") as? [String: String])?.keys.sorted() == ["left", "right"])
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
    // Una riga in alto nel salvataggio (dockduo non la salva mai) non si ripristina: solo i lati.
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    var saved = d.dictionary(forKey: "dockduo.aerospace.gapsBefore") as! [String: String]
    saved["top"] = "gaps.outer.top = 99"
    d.set(saved, forKey: "dockduo.aerospace.gapsBefore")
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
}
// All'uscita le righe tornano quelle di prima e il salvataggio sparisce; all'avvio dopo si riscrivono e si salvano di nuovo
// (dopo un'uscita forzata invece il salvataggio c'è già e non si rifà: writingFollowsTheSymlinkAndKeepsIt).
@Test func restoreAtQuitThenWriteAtLaunch() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == config && d.object(forKey: "dockduo.aerospace.gapsBefore") == nil)
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == withGapLines(config, sideLines))
    #expect((d.dictionary(forKey: "dockduo.aerospace.gapsBefore") as? [String: String])?["right"] == "gaps.outer.right =      5")
    // Un secondo avvio senza uscita (crash): si riscrive, il salvataggio resta quello di prima.
    #expect(writeGaps(sideGapLines(base: 5, edge: 6, width: 72, side: .right), to: real, defaults: d, reload: nil))
    #expect((d.dictionary(forKey: "dockduo.aerospace.gapsBefore") as? [String: String])?["right"] == "gaps.outer.right =      5")
}
// Il margine in alto che AeroSpace usa su uno schermo: un numero per tutti, o per monitor (lo schermo del Mac ha la sua
// voce "built-in", gli altri il predefinito in fondo). Forme che non si conoscono: nil.
@Test func outerTopGapReadsConstantAndPerMonitor() {
    #expect(outerTopGap("gaps.outer.top = 8", builtIn: true) == 8 && outerTopGap("gaps.outer.top = 8", builtIn: false) == 8)
    #expect(outerTopGap(config, builtIn: true) == 5 && outerTopGap(config, builtIn: false) == 43)
    #expect(outerTopGap("gaps.outer.top = [{ monitor.main = 16 }, 24]", builtIn: false) == 24)
    #expect(outerTopGap("gaps.outer.top = [{ monitor.main = 16 }]", builtIn: false) == nil)
    #expect(outerTopGap("gaps.outer.top = 'tanto'", builtIn: false) == nil && outerTopGap("", builtIn: true) == nil)
}
@Test func replacesOnlyTheTwoSideLines() {
    let out = withGapLines(config, sideLines).components(separatedBy: "\n"), old = config.components(separatedBy: "\n")
    #expect(out.count == old.count)
    for (a, b) in zip(out, old) where a != b { #expect(a.hasPrefix("gaps.outer.left") || a.hasPrefix("gaps.outer.right")) }
    #expect(out.filter { $0.hasSuffix("# dockduo: barra di lato") }.count == 2)
}
@Test func appendsMissingKeysBeforeTheFirstTable() {
    let noLeft = config.replacingOccurrences(of: "gaps.outer.left =       5\n", with: "")
    let out = withGapLines(noLeft, sideLines).components(separatedBy: "\n")
    let i = out.firstIndex(of: "[workspace-to-monitor-force-assignment]")!
    #expect(out[i - 1] == "gaps.outer.left = 5   # dockduo: barra di lato")
    #expect(withGapLines("a = 1\n", ["left": "x = 2"]) == "a = 1\nx = 2\n")
}
@Test func writingFollowsTheSymlinkAndKeepsIt() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, link) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(sideLines, to: link, defaults: d, reload: nil))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
    #expect(try String(contentsOf: real, encoding: .utf8) == withGapLines(config, sideLines))
    #expect(try String(contentsOf: URL(fileURLWithPath: real.path + ".dockduo-backup"), encoding: .utf8) == config)
    let saved = d.dictionary(forKey: "dockduo.aerospace.gapsBefore") as? [String: String]
    #expect(saved?["left"] == "gaps.outer.left =       5" && saved?.count == 2)
}
@Test func aFailedDryRunPutsTheOldTextBack() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!writeGaps(sideLines, to: real, defaults: d, reload: { dry in !dry }))
    #expect(try String(contentsOf: real, encoding: .utf8) == config)
}
// Il ripristino non chiede la prova (dry-run): con una ricarica che fallisce o va in timeout (AeroSpace muto, 24/10) il
// file torna lo stesso quello di prima, byte per byte, attraverso il link, e il salvataggio sparisce.
@Test func restoreDoesNotNeedTheDryRun() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, link) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(sideLines, to: link, defaults: d, reload: nil))
    var asked: [Bool] = []
    #expect(restoreGaps(to: link, defaults: d, reload: { dry in asked.append(dry); return false }))
    #expect(asked == [false])
    #expect(try String(contentsOf: real, encoding: .utf8) == config && d.object(forKey: "dockduo.aerospace.gapsBefore") == nil)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
}
@Test func withAerospaceOffTheFileIsJustWritten() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(config); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8).contains("gaps.outer.right = 63"))
}
@Test func restoreWritesTheLinesBackAndRemovesAddedOnes() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let noLeft = config.replacingOccurrences(of: "gaps.outer.left =       5\n", with: "")
    let (dir, real, _) = try tmp(noLeft); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == noLeft)
    #expect(d.object(forKey: "dockduo.aerospace.gapsBefore") == nil)
    #expect(restoreGaps(to: real, defaults: d, reload: nil))
}
// Col nascondi automatico le finestre si prendono anche il lato della barra: lì resta solo la base, come dall'altro lato
// (spec cartelle §4); la barra, quando esce, passa sopra di loro.
@Test func autohideGapIsTheBase() {
    let l = sideGapLines(base: 5, edge: 6, width: 52, side: .right, autohide: true)
    #expect(l == ["left": "gaps.outer.left = 5   # dockduo: barra di lato", "right": "gaps.outer.right = 5   # dockduo: barra di lato"])
    #expect(sideGapLines(base: 0, edge: 2, width: 52, side: .left, autohide: true)["left"] == "gaps.outer.left = 0   # dockduo: barra di lato")
}
// Le righe nel file sono già nostre ma il salvataggio non c'è (perso): a salvarle si salva la base del file, non il 63
// della barra, che all'uscita tornerebbe come "dell'utente".
@Test func ourOwnLinesAreSavedAsTheBase() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, real, _) = try tmp(withGapLines(config, sideLines)); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(writeGaps(sideLines, to: real, defaults: d, reload: nil))
    let saved = d.dictionary(forKey: "dockduo.aerospace.gapsBefore") as? [String: String]
    #expect(saved == ["left": "gaps.outer.left = 5", "right": "gaps.outer.right = 5"])
}
// Il config di serie dentro AeroSpace.app non si scrive né si ripristina: si romperebbe la firma dell'app.
@Test func aConfigInsideAnAppIsNeverWritten() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dir, _, _) = try tmp(""); defer { try? FileManager.default.removeItem(at: dir) }
    let inApp = dir.appendingPathComponent("AeroSpace.app/Contents/Resources/default-config.toml")
    try FileManager.default.createDirectory(at: inApp.deletingLastPathComponent(), withIntermediateDirectories: true)
    try config.write(to: inApp, atomically: true, encoding: .utf8)
    #expect(!writeGaps(sideLines, to: inApp, defaults: d, reload: nil))
    #expect(try String(contentsOf: inApp, encoding: .utf8) == config && d.object(forKey: "dockduo.aerospace.gapsBefore") == nil)
    d.set(["left": "gaps.outer.left = 1", "right": ""], forKey: "dockduo.aerospace.gapsBefore")
    #expect(!restoreGaps(to: inApp, defaults: d, reload: nil))
    #expect(try String(contentsOf: inApp, encoding: .utf8) == config)
}
// Un config con la tabella [gaps] (le chiavi sotto di lei, senza "gaps.") la scansione per righe non lo capisce: non si
// scrive e non si salva niente.
@Test func aGapsTableConfigIsLeftAlone() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let table = "start-at-login = true\n\n  [gaps]  \nouter.left = 5\nouter.right = 5\n"
    let (dir, real, _) = try tmp(table); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!writeGaps(sideLines, to: real, defaults: d, reload: nil))
    #expect(try String(contentsOf: real, encoding: .utf8) == table && d.object(forKey: "dockduo.aerospace.gapsBefore") == nil)
}

// Ogni forma di tabella [gaps] ferma sia la scrittura sia il ripristino; le chiavi puntate no (autore: gaps.outer.left = 5).
@Test func everyGapsTableStopsTheRewrite() {
    #expect(usesGapsTable("[gaps] # margini\nouter.left = 5\n"))
    #expect(usesGapsTable("[gaps.outer]\nleft = 5\n"))
    #expect(!usesGapsTable("gaps.outer.left = 5\n[mode.main.binding]\n"))
}
