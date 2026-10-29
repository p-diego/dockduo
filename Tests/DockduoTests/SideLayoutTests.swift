import AppKit
import SwiftUI
import Testing
@testable import Dockduo

private let workspaces = BarItem.widget(.workspaces)
private let apps = BarItem.widget(.apps), nowPlaying = BarItem.widget(.nowPlaying)

// Review Focus 5: il ⌘-trascina sposta il Dock intero (spec dock-contenitori §5): le sue sezioni vanno con lui, nello stesso
// ordine, e nella zona di prima non ne resta niente; oltre la fine = in fondo alla zona.
@Test func aDockMovesWithAllItsSections() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d), dock = [BarItem.widget(.apps), .widget(.folders), .widget(.shelf)]
    let box = DockBox(zone: .top, sections: dock), other = DockBox(zone: .bottom, sections: [nowPlaying])
    s.docks = [box, other]
    s.moveDock(box.id, to: .bottom, index: 0)
    #expect(s.docks(in: .top).isEmpty && s.docks(in: .bottom).first?.id == box.id && s.docks(in: .bottom).first?.sections == dock)
    #expect(s.docks(in: .bottom).map(\.id) == [box.id, other.id] && Settings(defaults: d).docks == s.docks)
    s.moveDock(box.id, to: .bottom, index: 99)
    #expect(s.docks(in: .bottom).map(\.id) == [other.id, box.id] && s.docks.flatMap(\.sections) == [nowPlaying] + dock)
}
// Le zone non si sovrappongono mai (24/10: lo spazio 1 copriva l'ora): il mezzo al centro se ci sta, se no spinto giù
// sotto la cima o su sopra il fondo; troppo per la barra = impilate dall'alto.
@Test func middleZoneNeverOverlapsTheTopZone() {
    let fits = sideZoneTops(bar: 1000, top: 100, middle: 300, bottom: 100, gap: 6)
    #expect(fits.middle == 350 && fits.bottom == 900)   // al centro esatto, come prima
    let down = sideZoneTops(bar: 1000, top: 300, middle: 500, bottom: 100, gap: 6)
    #expect(down.middle == 306 && down.bottom == 900)
    let up = sideZoneTops(bar: 1000, top: 50, middle: 500, bottom: 400, gap: 6)
    #expect(up.middle == 94 && up.bottom == 600)   // 94 + 500 + 6 = 600, sopra il fondo
    let over = sideZoneTops(bar: 1000, top: 300, middle: 600, bottom: 100, gap: 6)
    #expect(over.middle == 306 && over.bottom == 912)   // la cima resta libera, il fondo esce di 12
}

// In basso le zone sono sinistra, centro e destra (spec app conclusa §3.2): la stessa regola (sideZoneTops) lungo la
// larghezza, e al centro in altezza. I dati non cambiano: la cima è a sinistra.
@MainActor @Test func theBottomZonesGoLeftCentreRight() {
    _ = NSApplication.shared
    final class Seen { var frames: [Zone: CGRect] = [:] }
    let seen = Seen(), widths: [Zone: CGFloat] = [.top: 100, .middle: 300, .bottom: 100]
    let view = FittedZones(bar: 1000, scale: 1) { z, _ in
        Color.clear.frame(width: widths[z]!, height: 20)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { seen.frames[z] = $0 }
    }
    let host = NSHostingView(rootView: view.environment(\.barAxis, .horizontal).frame(width: 1000, height: 52).coordinateSpace(name: "bar"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 52), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    #expect(seen.frames == [.top: CGRect(x: 0, y: 16, width: 100, height: 20), .middle: CGRect(x: 350, y: 16, width: 300, height: 20),
                            .bottom: CGRect(x: 900, y: 16, width: 100, height: 20)])
    withExtendedLifetime(window) {}
}

@Test func sideSettingsDefaultAndReadBack() throws {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d, dock: nil)
    #expect(s.barSide == .left && s.sideWidth == 52)
    s.barSide = .right; s.sideWidth = 300
    #expect(s.sideWidth == 300)   // la scrittura non limita, la lettura sì
    s.docks.append(DockBox(zone: .top, sections: [nowPlaying]))
    s.moveDock(try dockID(s, of: nowPlaying), to: .bottom, index: 0)
    let t = Settings(defaults: d)
    #expect(t.barSide == .right && t.sideWidth == 150 && sections(t, in: .bottom).first == nowPlaying)
}
// Il rilascio del ⌘-trascina salva l'anteprima: dove cade il Dock (sideDropTarget sui Dock della zona e le loro cornici)
// conta i Dock senza quello trascinato, e la mossa dell'anteprima (dockMoved) è quella che salva moveDock. Un Dock tolto a
// metà trascinamento non torna col rilascio.
@Test func theReleaseSavesThePreview() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Settings(defaults: d)
    let (a, b, c) = (DockBox(zone: .top, sections: [nowPlaying]), DockBox(zone: .top, sections: [apps]), DockBox(zone: .top, sections: [workspaces]))
    s.docks = [a, b, c]
    let columns = Dictionary(uniqueKeysWithValues: Zone.allCases.map { ($0, s.docks(in: $0).map(\.id)) })
    let frames = [a.id: CGRect(x: 0, y: 50, width: 36, height: 40), b.id: CGRect(x: 0, y: 100, width: 36, height: 40),
                  c.id: CGRect(x: 0, y: 150, width: 36, height: 40)]
    func target(_ id: UUID, _ y: CGFloat) -> (zone: Zone, index: Int) {
        sideDropTarget(at: CGPoint(x: 20, y: y), barTop: 40, barBottom: 1100, dragging: id, columns: columns, frames: frames)
    }
    // a appena sotto il centro di b: dopo b, contando b e c e non a (con a l'indice sarebbe 2, dopo c).
    #expect(target(a.id, 125) == (Zone.top, 1))
    #expect(target(c.id, 95) == (Zone.top, 1) && target(a.id, 1050) == (Zone.bottom, 0))
    // In una zona senza Dock va lui, col suo id: l'anteprima non ne fa uno nuovo a ogni disegno.
    #expect(dockMoved(a.id, to: .bottom, index: 0, docks: s.docks).map(\.id) == [b.id, c.id, a.id])
    let t = target(a.id, 125), preview = dockMoved(a.id, to: t.zone, index: t.index, docks: s.docks)
    s.moveDock(a.id, to: t.zone, index: t.index)
    #expect(preview.map(\.id) == [b.id, a.id, c.id] && s.docks == preview)
    s.docks.removeAll { $0.id == c.id }   // tolto a metà trascinamento
    s.moveDock(c.id, to: .bottom, index: 0)
    #expect(s.docks.map(\.id) == [b.id, a.id])
}

@Observable private final class Knob { var value = 0 }

// withObservationTracking avvisa una volta sola: whenChanged si riarma, e agisce solo se il valore cambia davvero.
@Test @MainActor func whenChangedActsOnEveryRealChange() async {
    let knob = Knob()
    var acts = 0
    whenChanged({ knob.value }) { acts += 1 }
    for v in [1, 1, 2, 3] {
        knob.value = v
        // Il main esegue in ordine: questo blocco arriva dopo quello che il cambio ha messo in coda (whenChanged).
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }
    #expect(acts == 3)
}

// Le zone di prima si leggono così come sono; chiavi e token sconosciuti, mascotte (non ci sono più) e doppioni (vince il
// primo dall'alto) si scartano. Nei Dock salvati un token sconosciuto si perde da solo, il resto si legge.
@Test func unknownSavedZonesDoNotCrash() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    d.set(["top": ["nowPlaying", "teapot", "mascot:\(UUID().uuidString)"], "top.": ["apps"], "left.top": ["apps"], "bottom": ["nowPlaying"]],
          forKey: "dockduo.side.zones")
    let s = Settings(defaults: d)
    #expect(s.docks.map(\.zone) == [.top] && s.docks.map(\.sections) == [[nowPlaying]])
    let id = UUID()
    d.set(Data(#"[{"id":"\#(id.uuidString)","zone":"bottom","sections":["teapot","nowPlaying","nowPlaying"]}]"#.utf8), forKey: "dockduo.docks")
    #expect(Settings(defaults: d).docks == [DockBox(id: id, zone: .bottom, sections: [nowPlaying])])
}

// Review Focus 3: quando i Dock non ci stanno si rimpiccioliscono tutti insieme, con una scala sola (spec dock-contenitori
// §5): quella che porta l'altezza di tutte le zone e dei distacchi (a scala 1) dentro la barra, mai sopra 1 né sotto 0, al
// millesimo per difetto (misure rilette a ogni disegno non la fanno ricalcolare per niente, e non sborda mai).
@Test func allDocksShrinkTogether() {
    #expect(barFit(bar: 1000, natural: 800) == 1)
    #expect(barFit(bar: 1000, natural: 2000) == 0.5)
    #expect(barFit(bar: -5, natural: 100) == 0)   // la barra non c'è: niente misure negative
    #expect(barFit(bar: 1000, natural: 3000) == 0.333)
}

// Il Dock trascinato sta sopra anche le altre zone (si disegnano cima, centro, fondo): la sua zona alza l'indice, le altre no.
@Test func theDraggedDocksZoneDrawsOnTop() {
    let top = DockBox(zone: .top, sections: [apps]), mid = DockBox(zone: .middle, sections: [nowPlaying])
    let docks = [top, mid]
    #expect(zoneZIndex(zone: .top, dragging: top.id, in: docks) == 1)
    #expect(zoneZIndex(zone: .middle, dragging: top.id, in: docks) == 0 && zoneZIndex(zone: .bottom, dragging: top.id, in: docks) == 0)
    #expect(Zone.allCases.allSatisfy { zoneZIndex(zone: $0, dragging: nil, in: docks) == 0 })
}
