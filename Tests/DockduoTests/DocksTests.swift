import Foundation
import Testing
@testable import Dockduo

// I Dock come si vedono, senza l'id: nei confronti gli id appena nati non contano.
private let noID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
private func look(_ docks: [DockBox]) -> [DockBox] { docks.map { var d = $0; d.id = noID; return d } }
// Il Dock di prima, nelle sue tre sezioni.
private let dock: [BarItem] = [.widget(.apps), .widget(.folders), .widget(.shelf)]

// Review Focus 1: le zone di prima diventano un Dock per zona, nello stesso ordine (spec dock-contenitori §7). Sul Mac
// dell'autore {"top": ["dock"]} diventa un Dock in cima col Dock di oggi; cartelle, mensola e la vecchia chiave restano.
@Test func oldZonesBecomeOneDockPerZone() {
    #expect(look(migratedDocks(zones: ["top": ["dock"]])) == look([DockBox(zone: .top, sections: dock)]))
    // Token sconosciuti e mascotte (non ci sono più) si scartano; ora e batteria diventano l'elemento di stato, e la zona
    // che resta senza niente non fa un Dock.
    let two = migratedDocks(zones: ["top": ["clock", "teapot", "battery"], "bottom": ["mascot:\(UUID().uuidString)", "nowPlaying"]])
    #expect(look(two) == look([DockBox(zone: .bottom, sections: [.widget(.nowPlaying)])]))
    // Un token in due zone resta nella prima dall'alto.
    let dup = migratedDocks(zones: ["bottom": ["workspaces"], "middle": ["workspaces", "nowPlaying"], "top": ["workspaces"]])
    #expect(look(dup) == look([DockBox(zone: .top, sections: [.widget(.workspaces)]), DockBox(zone: .middle, sections: [.widget(.nowPlaying)])]))

    // All'avvio i Dock fatti dalle zone si salvano subito; la vecchia chiave resta lì, non più letta.
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let items = [DockItem(id: UUID(), bookmark: Data([1, 2, 3]), url: nil, hidden: false)]
    d.set(["top": ["dock"]], forKey: "dockduo.side.zones")
    d.set(encodeDockItems(items), forKey: "dockduo.dock.folders"); d.set(encodeDockItems(items), forKey: "dockduo.dock.shelf")
    let s = Settings(defaults: d)
    #expect(look(s.docks) == look([DockBox(zone: .top, sections: dock)]) && !s.isOn(.status))
    #expect(d.data(forKey: "dockduo.docks") != nil && d.dictionary(forKey: "dockduo.side.zones") as? [String: [String]] == ["top": ["dock"]])
    #expect(decodeDockItems(d.object(forKey: "dockduo.dock.folders")) == items && decodeDockItems(d.object(forKey: "dockduo.dock.shelf")) == items)
    d.set(["bottom": ["nowPlaying"]], forKey: "dockduo.side.zones")
    #expect(Settings(defaults: d).docks == s.docks)
}

// La prima volta (nessuna zona salvata) solo il Dock, al centro (autore, 24/10), con le sue tre sezioni.
@Test func firstLaunchIsOnlyTheDock() {
    #expect(look(migratedDocks(zones: nil)) == look([DockBox(zone: .middle, sections: dock)]))
}

// Review Focus 1: il Dock di prima diventa App aperte · Cartelle · Mensola, nello stesso posto; le app nascoste non sono più
// una sezione (il Dock mostra già attenuate le app senza finestre) e spariscono.
@Test func theOldDockBecomesThreeSections() {
    #expect(look(migratedDocks(zones: ["top": ["dock", "hidden"]])) == look([DockBox(zone: .top, sections: dock)]))
    #expect(upgradeToken("dock") == ["apps", "folders", "shelf"] && upgradeToken("nowPlaying") == ["nowPlaying"])
    // Lo stesso nei Dock già salvati (una versione di prova di questo piano).
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let id = UUID()
    d.set(Data(#"[{"id":"\#(id.uuidString)","zone":"top","sections":["dock","hidden","nowPlaying"]}]"#.utf8), forKey: "dockduo.docks")
    #expect(Settings(defaults: d).docks == [DockBox(id: id, zone: .top, sections: dock + [.widget(.nowPlaying)])])
}

// Review Focus 5: un Dock che resta senza sezioni perché se n'è andata l'ultima sparisce; uno salvato vuoto resta.
@Test func aDockLeavesWithItsLastSection() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d), playing = BarItem.widget(.nowPlaying), empty = DockBox(zone: .middle, sections: [])
    s.docks = [DockBox(zone: .top, sections: [playing]), empty]
    s.removeSection(playing)
    #expect(!s.isOn(playing) && s.docks == [empty] && Settings(defaults: d).docks == s.docks)
}

// Un Dock va fra le zone o nella sua, con le sue sezioni; l'indice conta senza di lui, oltre la fine = in fondo.
@Test func docksMoveWhereTheyAreTold() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d), middle = s.docks[0].id   // il Dock di partenza
    let a = DockBox(zone: .top, sections: [.widget(.workspaces)])
    s.docks.append(a)
    s.moveDock(a.id, to: .middle, index: 0)
    #expect(s.docks(in: .top).isEmpty && s.docks(in: .middle).map(\.id) == [a.id, middle])
    s.moveDock(a.id, to: .middle, index: 99)
    #expect(s.docks(in: .middle).map(\.id) == [middle, a.id] && s.docks(in: .middle)[1].sections == a.sections)
    let (x, y, z) = (DockBox(zone: .middle, sections: []), DockBox(zone: .middle, sections: []), DockBox(zone: .middle, sections: []))
    s.docks = [x, y, z]
    s.moveDock(x.id, to: .middle, index: 1)
    #expect(s.docks(in: .middle).map(\.id) == [y.id, x.id, z.id])
}

// Dei Dock che questa versione non legge (una futura) resta una copia, una volta sola; intanto la
// barra riparte dalle zone di prima e all'avvio non si scrive niente.
@Test func unreadableDocksKeepACopy() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let future = Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","zone":"side","sections":[]}]"#.utf8)
    d.set(future, forKey: "dockduo.docks"); d.set(["top": ["dock"]], forKey: "dockduo.side.zones")
    let s = Settings(defaults: d)
    #expect(look(s.docks) == look([DockBox(zone: .top, sections: dock)]))
    #expect(d.data(forKey: "dockduo.docks") == future && d.data(forKey: "dockduo.docks.unreadable") == future)
    d.set(Data("[1]".utf8), forKey: "dockduo.docks")   // un altro valore illeggibile: la copia resta la prima
    _ = Settings(defaults: d)
    #expect(d.data(forKey: "dockduo.docks.unreadable") == future)
}

// Spec dock-degli-agenti §5: Volume e Bluetooth non sono più sezioni. I loro token si perdono dai Dock salvati e dalle zone
// di prima; un Dock che la lettura lascia senza sezioni sparisce, come quando se ne toglie l'ultima, e uno salvato vuoto
// resta.
@Test func volumeAndBluetoothLeaveTheDocks() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (a, b, c) = (UUID(), UUID(), UUID())
    let saved = [(a, "top", #"["volume","bluetooth"]"#), (b, "middle", #"["dock","volume","nowPlaying"]"#), (c, "bottom", "[]")]
        .map { #"{"id":"\#($0.uuidString)","zone":"\#($1)","sections":\#($2)}"# }
    d.set(Data("[\(saved.joined(separator: ","))]".utf8), forKey: "dockduo.docks")
    #expect(Settings(defaults: d).docks == [DockBox(id: b, zone: .middle, sections: dock + [.widget(.nowPlaying)]), DockBox(id: c, zone: .bottom, sections: [])])
    #expect(look(migratedDocks(zones: ["top": ["bluetooth"], "middle": ["dock", "volume"]])) == look([DockBox(zone: .middle, sections: dock)]))
}

// Spec dock-degli-agenti §5 (autore, 25/10: «rimuovi anche il dnd»): nemmeno Concentrazione è più una sezione. Il suo token
// si perde dai Dock salvati e dalle zone di prima; il Dock che aveva solo lei sparisce (readDocks), gli altri restano.
@Test func focusLeavesTheDocks() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let (a, b) = (UUID(), UUID())
    d.set(Data(#"[{"id":"\#(a.uuidString)","zone":"top","sections":["focus"]},{"id":"\#(b.uuidString)","zone":"middle","sections":["dock","focus","nowPlaying"]}]"#.utf8),
          forKey: "dockduo.docks")
    #expect(Settings(defaults: d).docks == [DockBox(id: b, zone: .middle, sections: dock + [.widget(.nowPlaying)])])
    #expect(look(migratedDocks(zones: ["top": ["focus"], "bottom": ["focus", "nowPlaying"]])) == look([DockBox(zone: .bottom, sections: [.widget(.nowPlaying)])]))
}

// Review Focus 5 (spec impostazioni-nel-dock §7): lo Stato acceso in cima alla barra diventa un Dock suo, in cima; spento
// non c'è. I Dock dell'autore come sono salvati sul suo Mac (con i token di mascotte e Concentrazione, che non ci sono più)
// restano quelli di oggi; la vecchia chiave si legge una volta e se ne va, e un secondo avvio non aggiunge un altro Stato.
@Test func theStatusMovesIntoTheDocks() {
    let id = UUID(uuidString: "8890B075-8ADA-47EA-87EE-3329CE129C18")!
    let author = #"[{"sections":["mascot:37D2C8D1-EEC1-46FD-9D88-14C40C689FE1","apps","folders","shelf","nowPlaying","focus"],"zone":"middle","id":"\#(id.uuidString)"}]"#
    let his = DockBox(id: id, zone: .middle, sections: dock + [.widget(.nowPlaying)])
    for on in [true, false] {
        let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
        d.set(Data(author.utf8), forKey: "dockduo.docks"); d.set(on, forKey: "dockduo.statusElement")
        let s = Settings(defaults: d)
        #expect(s.docks.filter { !$0.isStatus } == [his])
        #expect(s.docks.first { $0.isStatus }?.zone == (on ? .top : nil) && s.docks.filter(\.isStatus).count == (on ? 1 : 0))
        #expect(d.object(forKey: "dockduo.statusElement") == nil)
        #expect(Settings(defaults: d).docks == s.docks)
    }
}

// Lo Stato entra nei Dock come Dock suo, prima di ogni altro Dock in cima; già in un Dock, o spento, i Dock restano come sono.
@Test func theStatusGetsItsOwnDockAtTheTop() {
    let status = BarItem.widget(.status), playing = DockBox(zone: .top, sections: [.widget(.nowPlaying)])
    let docks = [DockBox(zone: .middle, sections: dock), playing]
    let with = docksWithStatus(docks, statusElement: true)
    #expect(with.filter { !$0.isStatus } == docks && with.filter { $0.zone == .top }.map(\.isStatus) == [true, false])
    #expect(docksWithStatus(docks, statusElement: false) == docks && docksWithStatus(with, statusElement: true) == with)
    let elsewhere = [DockBox(zone: .bottom, sections: [status]), playing]   // già spostato in fondo: resta lì
    #expect(docksWithStatus(elsewhere, statusElement: true) == elsewhere)
    #expect(!DockBox(zone: .top, sections: [status, .widget(.nowPlaying)]).isStatus && !DockBox(zone: .top, sections: []).isStatus)
}

// Le prime letture seguono le sezioni accese, da qualunque parte si accendano (main.swift, firstRead): quelle appena accese;
// lo Stato anche appena spento, così batteria e Wi‑Fi si svuotano. Quelle che restano accese, o si spengono, niente.
@Test func theSectionsToReadAreTheOnesJustTurnedOn() {
    let (apps, playing, status) = (BarItem.widget(.apps), BarItem.widget(.nowPlaying), BarItem.widget(.status))
    #expect(sectionsToRead(old: [apps], new: [apps, playing, status]) == [playing, status])
    #expect(sectionsToRead(old: [apps, playing], new: [apps]).isEmpty && sectionsToRead(old: [apps], new: [apps]).isEmpty)
    #expect(sectionsToRead(old: [apps, status], new: [apps]) == [status])
}
