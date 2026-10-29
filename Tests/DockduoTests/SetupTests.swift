import AppKit
import Testing
@testable import Dockduo

// Regola di riapertura (spec benvenuto §2): qualcosa era a posto e ora non lo è. Chiavi nuove o sparite non contano.
@Test func regressedOnlyWhenSomethingWasOKAndIsNot() {
    #expect(regressed(previous: ["fda": true], now: ["fda": false]))
    #expect(!regressed(previous: ["fda": true], now: ["fda": true]))
    #expect(!regressed(previous: ["fda": false], now: ["fda": false]))   // mai stato a posto
    #expect(!regressed(previous: [:], now: ["fda": false]))              // chiave nuova (widget appena acceso)
    #expect(!regressed(previous: ["fda": true], now: [:]))               // chiave sparita (widget spento)
    #expect(regressed(previous: ["fda": true, "codex": true], now: ["fda": true, "codex": false]))
}

// Stesso criterio di main.swift per "copia installata".
@Test func inApplicationsForSystemAndUserFolders() {
    #expect(inApplications("/Applications/dockduo.app"))
    #expect(inApplications("/Users/x/Applications/dockduo.app"))
    #expect(!inApplications("/Volumes/dockduo/dockduo.app"))
    #expect(!inApplications("/Users/x/Git/dockduo/.build/dockduo.app"))
}

// Finding 1 della revisione finale: dal disco immagine o da una copia tradotta la finestra deve aprirsi da sola.
@Test func launchedFromDiskImageForVolumesAndAppTranslocation() {
    #expect(launchedFromDiskImage("/Volumes/dockduo/dockduo.app"))
    #expect(launchedFromDiskImage("/private/var/folders/xx/T/AppTranslocation/ABCD/d/dockduo.app"))
    #expect(!launchedFromDiskImage("/Applications/dockduo.app"))
    #expect(!launchedFromDiskImage("/Users/x/Applications/dockduo.app"))
    #expect(!launchedFromDiskImage("/Users/x/Git/dockduo/.build/dockduo.app"))
}

@Test func destinationPrefersSystemApplications() {
    let home = URL(fileURLWithPath: "/Users/x")
    #expect(applicationsDestination(applicationsWritable: true, home: home).path == "/Applications/dockduo.app")
    #expect(applicationsDestination(applicationsWritable: false, home: home).path == "/Users/x/Applications/dockduo.app")
}

// La fotografia (spec §2) contiene solo ciò che un aggiornamento può rompere: permessi TCC dei widget accesi e gli hook
// che esistono. AeroSpace non c'è; l'elemento di stato spento e le integrazioni assenti nemmeno.
@Test func snapshotOnlyCoversWhatUpdatesBreak() {
    let s = snapshot(noLocation: false,
                     hooks: ["claude-code": .installed, "codex": .outdated, "gemini": .missing("no ~/.gemini")],
                     wifiOn: true)
    #expect(s == ["location": true, "claude-code": true, "codex": false])
    #expect(snapshot(noLocation: false, hooks: [:], wifiOn: false).isEmpty)
    #expect(snapshot(noLocation: true, hooks: [:], wifiOn: true) == ["location": false])
}

// "Crea il file di AeroSpace" (spec app conclusa §2.3): il file di fabbrica dentro l'app diventa ~/.aerospace.toml, uguale.
// Un file dell'utente che c'è già non si tocca, nemmeno quello in ~/.config/aerospace: con due file AeroSpace non parte.
@Test func createConfigCopiesTheFactoryFile() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("dockduo-create-config-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("AeroSpace.app"), home = root.appendingPathComponent("home")
    let resources = app.appendingPathComponent("Contents/Resources"), xdg = home.appendingPathComponent(".config/aerospace")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let factory = "# di fabbrica\ngaps.outer.left =       0\n"
    try factory.write(to: resources.appendingPathComponent("default-config.toml"), atomically: true, encoding: .utf8)
    let user = home.appendingPathComponent(".aerospace.toml")
    try createAerospaceConfig(app: app, home: home)
    #expect(try String(contentsOf: user, encoding: .utf8) == factory)
    try "mine\n".write(to: user, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try createAerospaceConfig(app: app, home: home) }
    #expect(try String(contentsOf: user, encoding: .utf8) == "mine\n")
    try fm.removeItem(at: user)
    try fm.createDirectory(at: xdg, withIntermediateDirectories: true)
    try "xdg\n".write(to: xdg.appendingPathComponent("aerospace.toml"), atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try createAerospaceConfig(app: app, home: home) }
    #expect(!fm.fileExists(atPath: user.path))
}

// Il Benvenuto offre "Crea il file di AeroSpace" solo con AeroSpace aperto e senza un file suo; per gli altri motivi la
// riga resta com'era (il segno verde, o Apri e Installa).
@Test func welcomeOffersTheConfigOnlyWhenMissing() {
    #expect(offersAerospaceConfig(.running, .noUserConfig))
    for problem: SpaceProblem? in [nil, .notInstalled, .notOpen, .unknownForm, .rejected] { #expect(!offersAerospaceConfig(.running, problem)) }
    #expect(!offersAerospaceConfig(.installedNotRunning, .noUserConfig) && !offersAerospaceConfig(.notInstalled, .noUserConfig))
}

// Spec impostazioni-nel-dock §1: riaprire dockduo (Finder, Spotlight) mette il Dock in modifica; nessuna finestra da riaprire.
@MainActor @Test func reopeningEntersEditMode() {
    #expect(!AppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    #expect(Editing.shared.on)
    Editing.shared.end()
}
