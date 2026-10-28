import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Cornici nello spazio "bar" (y verso il basso, barra larga 52): pillola "1" da 10 a 50, pillola "2" da 56 a 156.
private let pills: [String: CGRect] = [
    "1": CGRect(x: 13, y: 10, width: 26, height: 40),
    "2": CGRect(x: 13, y: 56, width: 26, height: 100),
]
private func target(_ x: CGFloat, _ y: CGFloat) -> String? { iconDropTarget(at: CGPoint(x: x, y: y), from: "1", pills: pills, thickness: 52) }

@Test func dropOnAnotherPillTargetsIt() {
    #expect(target(26, 80) == "2")
}

// Sulla stessa pillola, tra due pillole, fuori dalla barra a destra o a sinistra: niente.
@Test func dropOnTheSamePillBetweenPillsOrOutsideTheBarIsNothing() {
    #expect(target(26, 20) == nil)
    #expect(target(26, 53) == nil)
    #expect(target(60, 80) == nil)
    #expect(target(-1, 80) == nil)
}

// Conta la riga della pillola, non il suo rettangolo: il puntatore poco a fianco della capsula, ma dentro la barra, vale.
@Test func dropBesideTheCapsuleInsideTheBarCounts() {
    #expect(target(2, 80) == "2")
    #expect(target(50, 80) == "2")
    #expect(target(0, 80) == "2")
    #expect(target(52, 80) == "2")
}

@Test func pillEdgesAreInclusive() {
    #expect(target(26, 56) == "2")
    #expect(target(26, 156) == "2")
}

@Test func moveArgsFollowOnlyWhenAsked() {
    #expect(moveWindowArgs(windowID: 42, to: "3", follow: false) == ["move-node-to-workspace", "--window-id", "42", "--", "3"])
    #expect(moveWindowArgs(windowID: 42, to: "3", follow: true)
            == ["move-node-to-workspace", "--focus-follows-window", "--window-id", "42", "--", "3"])
}

// La copia dell'icona trascinata è grande quanto le icone degli spazi, prese dalla cornice della pillola da cui parte:
// dentro il Dock (inDockScale) e coi Dock rimpiccioliti (qui a metà).
@MainActor @Test func theDraggedCopyIsAsBigAsTheWorkspaceIcons() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let state = BarState()
    state.reports = [SpaceReport(workspace: Workspace(name: "1", isFocused: false), apps: [])]
    var pill: CGRect?
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { pill = $1 })
    for scale in [52.0 / 38, 52.0 / 38 / 2] {
        pill = nil
        let host = NSHostingView(rootView: DockBoxView(box: DockBox(zone: .middle, sections: [.widget(.workspaces)]), state: state,
                                                       mirrored: false, icons: icons, settings: Dockduo.Settings(defaults: d))
            .environment(\.barScale, scale).coordinateSpace(name: "bar"))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let frame = try #require(pill)
        #expect(abs(iconCopySize(pill: frame, fallback: 0) - 20 * scale * inDockScale) < 0.01, "\(scale)")
        withExtendedLifetime(window) {}
    }
    #expect(iconCopySize(pill: nil, fallback: 27) == 27)   // senza cornice la grandezza di prima, non una copia invisibile
}

// Lo stato del trascina icone (IconDragging), col conto dei trascinamenti in corso che col nascondi tiene fuori la barra
// (inProgress). Rilasciata fuori da ogni pillola, la copia torna al punto di presa e sparisce, e il conto torna a zero; la
// finestra che si chiude (o lascia la sua pillola) a metà chiude il trascinamento subito. Nessuna pillola dove cadere: il
// rilascio su una pillola sposta la finestra con AeroSpace, qui mai.
@MainActor @Test func anIconDragThatEndsLeavesNothingInProgress() async throws {
    let app = AppEntry(name: "Notes", pid: 9, windowID: 3, bundle: "com.notes")
    let icons = IconDragging()
    icons.moved(app, from: "1", start: CGPoint(x: 26, y: 20), location: CGPoint(x: 26, y: 30), fallback: 20)
    #expect(icons.drag?.location == CGPoint(x: 26, y: 30) && IconDragging.inProgress == 1)
    icons.dropped(at: CGPoint(x: 26, y: 300), BarState(), thickness: 52)
    for _ in 0..<50 where icons.drag != nil { try await Task.sleep(for: .milliseconds(20)) }   // il ritorno, 0,2 s
    #expect(icons.drag == nil && IconDragging.inProgress == 0)

    let other = IconDragging()
    other.moved(app, from: "1", start: .zero, location: CGPoint(x: 0, y: 10), fallback: 20)
    #expect(IconDragging.inProgress == 1)
    other.reportsChanged([SpaceReport(workspace: Workspace(name: "1", isFocused: true), apps: [])])
    #expect(other.drag == nil && IconDragging.inProgress == 0)
}
