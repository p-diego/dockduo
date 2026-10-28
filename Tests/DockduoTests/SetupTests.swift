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

// Spec impostazioni-nel-dock §1: riaprire dockduo (Finder, Spotlight) mette il Dock in modifica; nessuna finestra da riaprire.
@MainActor @Test func reopeningEntersEditMode() {
    #expect(!AppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    #expect(Editing.shared.on)
    Editing.shared.end()
}
