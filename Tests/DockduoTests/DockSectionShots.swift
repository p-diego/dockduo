import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// La prova a occhio delle sezioni nel vetro del Dock (DOCK_SECTION_SHOTS=cartella): a 2×, a barra 52, un Dock per ogni
// sezione da sola (Spazi, In riproduzione) e uno con Spazi · App, in fila, in scuro e in chiaro. Fuori dallo schermo il
// vetro non si disegna: sotto ogni capsula un riquadro del colore del Dock, lo scuro misurato sul blu della cattura di
// macOS, il chiaro a occhio, solo per vederne i bordi. La lente dello spazio attivo è vetro, che fuori dallo schermo svuota
// tutta la vista: nessuno spazio attivo. Le impostazioni su una suite a parte.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCK_SECTION_SHOTS"] != nil)) func dockSectionShots() async throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOCK_SECTION_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    let apps = NSWorkspace.shared.runningApplications.filter { $0.icon != nil }.prefix(4).enumerated()
        .map { AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)") }
    let state = BarState()
    state.dock = apps
    state.track = Track(player: .music, title: "Song", artist: "Artist", playing: true)
    state.artwork = NSImage(size: CGSize(width: 64, height: 64), flipped: false) { r in
        NSGradient(starting: .systemPink, ending: .systemIndigo)?.draw(in: r, angle: 45); return true
    }
    let columns: [(String, [BarItem])] = [("Spazi", [.widget(.workspaces)]), ("Musica", [.widget(.nowPlaying)]),
                                          ("Spazi · App", [.widget(.workspaces), .widget(.apps)])]
    state.reports = [("1", [0, 1]), ("2", [2]), ("3", [3])].map { n, i in
        SpaceReport(workspace: Workspace(name: n, isFocused: false), apps: i.filter(apps.indices.contains).map { apps[$0] })
    }
    for (file, dark) in [("sezioni-scuro", true), ("sezioni-chiaro", false)] {
        let backdrop = dark ? NSColor(srgbRed: 1 / 255, green: 2 / 255, blue: 8 / 255, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)
        let fill = dark ? Color(red: 13 / 255, green: 14 / 255, blue: 20 / 255) : Color(red: 0.93, green: 0.93, blue: 0.95)
        let view = HStack(alignment: .top, spacing: 16) {
            ForEach(columns, id: \.0) { title, sections in column(title, sections, state: state, settings: s, fill: fill, dark: dark) }
        }
        .padding(16)
        try await shot(view, backdrop: backdrop, to: out.appendingPathComponent("\(file).png"))
    }
}

// Un Dock in una barra larga 52, a 2 dal bordo come la barra (barEdge), col suo nome sopra.
@MainActor private func column(_ title: String, _ sections: [BarItem], state: BarState, settings: Dockduo.Settings, fill: Color,
                               dark: Bool) -> some View {
    let scale: CGFloat = 52.0 / 38
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    return VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
        DockBoxView(box: DockBox(zone: .middle, sections: sections), state: state, side: .left, icons: icons, settings: settings)
            .background { RoundedRectangle(cornerRadius: dockRadius * scale).fill(fill).offset(x: -0.5 * dockUnit * scale) }
            .environment(\.barScale, scale).modifier(SideLook())
            .frame(width: 52).padding(.leading, 2)
    }
    .environment(\.colorScheme, dark ? .dark : .light)
}

// In una finestra mai mostrata, per la scala dello schermo (2×), e sopra lo sfondo dipinto a mano: quello della vista più
// esterna in cacheDisplay non si disegna. Anche per la prova del Dock in modifica (EditingTests).
@MainActor func shot(_ view: some View, backdrop: NSColor, to url: URL) async throws {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .seconds(0.5))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    try #require(rep.pixelsWide == Int(host.bounds.width) * 2, "serve uno schermo a 2×")
    host.cacheDisplay(in: host.bounds, to: rep)
    let flat = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
    let all = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    backdrop.setFill()
    all.fill()
    rep.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try #require(flat.representation(using: .png, properties: [:])).write(to: url)
    withExtendedLifetime(window) {}
}
