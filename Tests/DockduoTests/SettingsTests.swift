import Foundation
import Testing
@testable import Dockduo

// Ogni test ha la sua suite di UserDefaults, cancellata alla fine (la usano anche le prove di altri file).
func fresh() -> (UserDefaults, String) {
    let name = "dockduo-test-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}
private func w(_ ids: WidgetID...) -> [BarItem] { ids.map(BarItem.widget) }
// Le sezioni di una zona come si vedono oggi nella barra: i suoi Dock uno dopo l'altro.
func sections(_ s: Settings, in z: Zone) -> [BarItem] { s.docks(in: z).flatMap(\.sections) }
// Il Dock in cui sta una sezione: quello che sposta il ⌘-trascina (moveDock).
func dockID(_ s: Settings, of item: BarItem) throws -> UUID { try #require(s.docks.first { $0.sections.contains(item) }?.id) }
// Le prove che passano da Settings.shared (AgentServer.apply) lo fanno scrivere nel dominio dello strumento dei test (alla
// prima lettura salva i Dock di partenza e i suoni degli agenti): a fine prova le sue chiavi vanno via, così non restano da
// una corsa all'altra. Anche le mascotte di una corsa delle versioni di prima: deciderebbero i suoni della prima lettura.
func forgetSharedSettings() {
    for key in ["dockduo.mascots", "dockduo.docks", "dockduo.agentSounds", "dockduo.agentVolume"] {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// La prima volta solo il Dock acceso, al centro (autore, 24/10); la barra a sinistra; lo Stato spento.
@Test func defaultsMatchTodaysBehaviour() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    #expect(s.docks.map(\.zone) == [.middle] && s.docks.map(\.sections) == [w(.apps, .folders, .shelf)] && !s.isOn(.status))
    #expect(s.isOn(.apps) && s.isOn(.folders) && s.isOn(.shelf) && s.barSide == .left && !s.isOn(.workspaces) && !s.isOn(.nowPlaying))
    #expect(s.showFrontAppName)
    #expect(s.quotaInterval == 5 && s.clockApp == "com.apple.iCal")
    #expect(!s.setupDone && s.setupSnapshot.isEmpty)
    #expect(!s.autohide)
    #expect(!s.dockHoverNames)
}

@Test func writesAreReadBackByANewInstance() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    s.showFrontAppName = false
    s.quotaInterval = 15; s.clockApp = ""
    s.docks = [DockBox(zone: .top, sections: w(.status)), DockBox(zone: .bottom, sections: w(.nowPlaying)), DockBox(zone: .bottom, sections: [])]
    s.setupDone = true; s.setupSnapshot = ["fda": true, "location": false]
    s.autohide = true
    s.dockHoverNames = true
    let t = Settings(defaults: d)
    #expect(!t.showFrontAppName)
    #expect(t.quotaInterval == 15 && t.clockApp == "")
    #expect(t.docks == s.docks && t.isOn(.status))
    #expect(t.setupDone && t.setupSnapshot == ["fda": true, "location": false])
    #expect(t.autohide)
    #expect(t.dockHoverNames)
}

@Test func settingLaunchAtLoginPersistsTheChoice() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    s.setLaunchAtLogin(false)   // SMAppService può fallire nel processo di test: la chiave va comunque scritta
    #expect(d.object(forKey: "dockduo.launchAtLogin") as? Bool == false)
}

// L'arrotondamento degli angoli non c'è più (spec dock-contenitori §5): ogni capsula è un Dock, coi suoi angoli. Il valore
// salvato resta dov'è, non letto, e niente lo riscrive.
@Test func cornerRoundingIsGone() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    d.set(4.0, forKey: "dockduo.cornerRadius")
    let s = Settings(defaults: d)
    #expect(!Mirror(reflecting: s).children.contains { $0.label?.contains("cornerRadius") == true })
    #expect(d.object(forKey: "dockduo.cornerRadius") as? Double == 4)
}

// Spec impostazioni-nel-dock §6: la pagina salvata della finestra delle impostazioni se ne va alla prima lettura.
@Test func theSavedSettingsPageGoes() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    d.set("pills", forKey: "dockduo.settingsPane")
    _ = Settings(defaults: d)
    #expect(d.object(forKey: "dockduo.settingsPane") == nil)
}

// Un valore scritto a mano o da una versione futura: un lato sconosciuto = sinistra.
@Test func anUnknownSideFallsBackToTheLeft() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    d.set("top", forKey: "dockduo.barSide")
    #expect(Settings(defaults: d).barSide == .left)
}

// Senza i Dock né le zone di prima (cancellati a mano): il Dock di partenza. I Dock salvati vuoti invece restano vuoti:
// tutto spento.
@Test func withoutSavedZonesTheBarStartsFromTheDefaults() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d), playing = BarItem.widget(.nowPlaying)
    s.docks = [DockBox(zone: .top, sections: [playing])]   // un posto diverso da quello di partenza
    d.removeObject(forKey: "dockduo.docks")
    let t = Settings(defaults: d)
    #expect(t.docks.map(\.zone) == [.middle] && t.docks.map(\.sections) == [w(.apps, .folders, .shelf)] && !t.isOn(playing))
    t.docks = []
    #expect(Settings(defaults: d).docks.isEmpty)
}

// Review Focus 2: i suoni degli agenti partono dalla prima mascotte AI salvata, coi suoi effetti sonori e il suo volume
// (quelli dell'autore: accesi, 35), letti una volta sola e salvati subito: dopo, le mascotte non decidono più. Senza una
// mascotte AI: accesi, al volume di sempre (35). L'elenco è scritto come lo salvavano le versioni con le mascotte.
@Test func agentSoundsStartFromTheAuthorsMascot() {
    func mascot(ai: Bool, sounds: Bool, volume: Int) -> String {
        let function = ai ? #"{"ai":{"agents":["Claude","Codex"]}}"# : #"{"system":{"kinds":["cpu","heat","memory"]}}"#
        return #"{"id":"\#(UUID().uuidString)","shape":"mostro","body":0,"eyes":0,"voice":"bubble","function":\#(function),"#
            + #""sounds":\#(sounds),"volume":\#(volume),"captions":true,"renewedBadge":true,"quotaInMenu":true,"besideNotch":false,"#
            + #""eyeSize":1,"eyeLift":0,"eyeSpread":1,"size":1}"#
    }
    func saved(_ mascots: [String], in d: UserDefaults) { d.set(Data("[\(mascots.joined(separator: ","))]".utf8), forKey: "dockduo.mascots") }
    func sounds(_ mascots: [String]?) -> (on: Bool, volume: Double) {
        let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
        if let mascots { saved(mascots, in: d) }
        let s = Settings(defaults: d)
        return (s.agentSounds, s.agentVolume)
    }
    let author = [mascot(ai: false, sounds: true, volume: 35), mascot(ai: true, sounds: true, volume: 35)]
    #expect(sounds(author) == (true, 0.35))
    #expect(sounds([mascot(ai: false, sounds: true, volume: 10), mascot(ai: true, sounds: false, volume: 80),
                    mascot(ai: true, sounds: true, volume: 20)]) == (false, 0.8))   // la prima AI, non il Monitor di sistema
    #expect(sounds([mascot(ai: false, sounds: false, volume: 10)]) == (true, 0.35))
    #expect(sounds([]) == (true, 0.35) && sounds(nil) == (true, 0.35))

    // Una volta sola: cambiate le mascotte, restano quelli letti la prima volta; scelti da Impostazioni › Suoni, restano quelli.
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    saved([mascot(ai: true, sounds: false, volume: 80)], in: d)
    let s = Settings(defaults: d)
    saved(author, in: d)
    #expect(Settings(defaults: d).agentSounds == false && Settings(defaults: d).agentVolume == 0.8)
    s.agentSounds = true; s.agentVolume = 0.5
    #expect(Settings(defaults: d).agentSounds && Settings(defaults: d).agentVolume == 0.5)
    d.set(3.0, forKey: "dockduo.agentVolume")
    #expect(Settings(defaults: d).agentVolume == 1)   // fuori misura: dentro 0…1
}

// Review Focus 2: le impostazioni dell'autore com'erano salvate (25/10) dopo l'aggiornamento. Il suo Dock aveva in cima la
// mascotte AI e in fondo Concentrazione: escono tutte e due, le altre sezioni restano com'erano; il Dock in fondo con solo
// il Monitor di sistema sparisce.
// I suoni degli agenti restano quelli della sua mascotte, accesi a 35; l'elenco delle mascotte resta salvato, non più letto.
@Test func theAuthorsSettingsSurviveTheCleanup() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let ai = "37D2C8D1-EEC1-46FD-9D88-14C40C689FE1", system = UUID().uuidString
    let dock = UUID(uuidString: "8890B075-8ADA-47EA-87EE-3329CE129C18")!
    d.set(Data((#"[{"sections":["mascot:\#(ai)","apps","folders","shelf","nowPlaying","focus"],"zone":"middle","id":"\#(dock.uuidString)"},"#
                + #"{"sections":["mascot:\#(system)"],"zone":"bottom","id":"\#(UUID().uuidString)"}]"#).utf8), forKey: "dockduo.docks")
    let rest = #""captions":true,"renewedBadge":true,"quotaInMenu":true,"besideNotch":false,"eyeSize":1,"eyeLift":0,"eyeSpread":1,"size":1"#
    let mascots = Data((#"[{"id":"\#(ai)","shape":"mostro","body":16119292,"eyes":1315866,"voice":"bubble","#
                        + #""function":{"ai":{"agents":["Codex","Claude"]}},"sounds":true,"volume":35,\#(rest)},"#
                        + #"{"id":"\#(system)","shape":"mirtillo","body":7577338,"eyes":1315866,"voice":"bottle","#
                        + #""function":{"system":{"kinds":["cpu","heat","memory"]}},"sounds":true,"volume":35,\#(rest)}]"#).utf8)
    d.set(mascots, forKey: "dockduo.mascots")
    let s = Settings(defaults: d)
    #expect(s.docks == [DockBox(id: dock, zone: .middle, sections: w(.apps, .folders, .shelf, .nowPlaying))])
    #expect(s.agentSounds && s.agentVolume == 0.35)
    #expect(d.data(forKey: "dockduo.mascots") == mascots)
}

// Spec app conclusa §2.1: la prima volta (niente Dock salvati, setup non fatto, niente larghezza) la barra nasce larga come
// il Dock di macOS (tilesize × 52/31) e si salva subito; senza tilesize (Dock mai ridimensionato) le caselle di fabbrica,
// 48. Senza Dock (le prove) resta 52 e non si scrive nulla.
@Test func aFreshInstallStartsAtTheMacOSDockSize() {
    for (tilesize, expected) in [(75.0, 126.0), (16.0, 38.0), (nil, 81.0)] {
        let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
        let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
        if let tilesize { dock.set(tilesize, forKey: "tilesize") }
        #expect(Settings(defaults: d, dock: dock).sideWidth == expected)
        #expect(d.object(forKey: "dockduo.sideWidth") as? Double == expected)
    }
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    #expect(Settings(defaults: d, dock: nil).sideWidth == 52 && d.object(forKey: "dockduo.sideWidth") == nil)
}

@Test func anExistingInstallKeepsItsSize() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (dock, dockName) = fresh(); defer { dock.removePersistentDomain(forName: dockName) }
    dock.set(75.0, forKey: "tilesize"); d.set(true, forKey: "dockduo.setupDone")
    #expect(Settings(defaults: d, dock: dock).sideWidth == 52)
    #expect(d.object(forKey: "dockduo.sideWidth") == nil)
}
