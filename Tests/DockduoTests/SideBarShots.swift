import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// La prova che la barra di lato non cambia di un pixel (SIDE_BAR_SHOTS=cartella, spec app conclusa §3.3): a 2×, la barra
// vera (SideBarView) larga 71, alta quanto sullo schermo del Mac, col Dock dell'autore com'era il 29/10 (App aperte,
// Cartelle, Mensola, In riproduzione al centro; cartelle e mensola vuote, niente in riproduzione), a sinistra e a destra,
// fuori e dentro la modifica, col nome di una voce del Dock nel pannello delle etichette accanto (labelPanelFrame). Si
// confrontano byte per byte (cmp) con quelle fatte prima di un cambiamento. Tutto fermo: scuro forzato, app di sistema
// sempre aperte in un ordine fisso, nessuno spazio, nessun agente, niente Stato. SideBarView legge Settings.shared ed
// Editing.shared: le chiavi che scrive nel dominio dello strumento dei test vanno via alla fine. Fuori dallo schermo il
// vetro non si disegna.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDE_BAR_SHOTS"] != nil)) func sideBarShots() async throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIDE_BAR_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let s = Settings.shared
    defer {
        forgetSharedSettings()
        for key in ["barSide", "sideWidth", "dock.folders", "dock.shelf", "dockHoverNames"] { UserDefaults.standard.removeObject(forKey: "dockduo.\(key)") }
    }
    (s.sideWidth, s.dockFolders, s.dockShelf, s.dockHoverNames) = (71, [], [], false)
    s.docks = [DockBox(zone: .middle, sections: [.widget(.apps), .widget(.folders), .widget(.shelf), .widget(.nowPlaying)])]
    let running = NSWorkspace.shared.runningApplications
    let state = BarState()
    state.dock = try ["com.apple.finder", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
                      "com.apple.systemuiserver"].enumerated().map { i, bundle in
        let app = try #require(running.first { $0.bundleIdentifier == bundle && $0.icon != nil }, "\(bundle) non è aperta")
        return AppEntry(name: "A\(i)", pid: app.processIdentifier, windowID: i, bundle: bundle)
    }
    let mac = CGRect(x: 0, y: 0, width: 1512, height: 982)
    defer { Editing.shared.end() }
    for edit in [false, true] {
        if edit { Editing.shared.begin() }
        for side in [Side.left, .right] {
            s.barSide = side
            let shown = sideBarFrame(screen: mac, side: side, width: 71, edge: barEdge, top: 38)
            let place = SidePlace()
            place.bar = screenTop(shown, in: mac)
            let labels = SideLabels()
            labels.show(SideLabels.dock, SideLabel(text: "App Store", style: .dockName, anchor: CGRect(x: 3, y: 420, width: 65, height: 60)))
            let bar = SideBarView(state: state, side: side, place: place).environment(\.sideLabels, labels)
                .environment(\.barVisibility, BarVisibility()).frame(width: shown.width, height: shown.height)
            let text = SideLabelsView(labels: labels, opensLeft: side == .right).modifier(SideLook())
                .frame(width: 360, height: shown.height)
            let view = HStack(spacing: 0) { if side == .left { bar; text } else { text; bar } }
                .padding(side == .left ? .leading : .trailing, barEdge).environment(\.colorScheme, .dark)
            try await shot(view, backdrop: NSColor(srgbRed: 1 / 255, green: 2 / 255, blue: 8 / 255, alpha: 1),
                           to: out.appendingPathComponent("barra-\(side)-\(edit ? "modifica" : "riposo").png"))
        }
    }
}
