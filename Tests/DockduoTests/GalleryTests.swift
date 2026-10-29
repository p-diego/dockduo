import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// La galleria delle sezioni (spec impostazioni-nel-dock §3). Suite nuove, finestre mai mostrate: la galleria delle prove non
// va mai davanti (main.swift lo fa solo con quella vera).

private func w(_ ids: WidgetID...) -> [BarItem] { ids.map(BarItem.widget) }

// L'italiano dell'app, letto da Resources: le prove non hanno le traduzioni nel loro bundle.
private let italian = Bundle(url: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/it.lproj"))!

// Il Dock dell'autore: App aperte, Cartelle, Mensola, In riproduzione; Spazi e Stato fuori.
private func authorDock(_ s: Dockduo.Settings) {
    s.docks = [DockBox(zone: .middle, sections: w(.apps, .folders, .shelf, .nowPlaying))]
}

// Tutte, per categoria, e la ricerca sul nome e sulla categoria, senza maiuscole né accenti; vuota (o solo spazi) = tutte.
@Test func theCatalogFiltersByCategoryAndSearch() {
    func items(_ c: SectionCategory?, _ s: String, _ b: Bundle = .main) -> [BarItem] { catalogShown(category: c, search: s, bundle: b).map(\.item) }
    let all = w(.apps, .folders, .shelf, .workspaces, .nowPlaying, .status)
    #expect(items(nil, "") == all)
    #expect(catalogShown(category: nil, search: "").map(\.category) == [.dock, .dock, .dock, .workspaces, .nowPlaying, .status])
    #expect(items(nil, "  ") == all)
    #expect(items(.dock, "") == w(.apps, .folders, .shelf))
    #expect(items(.status, "") == w(.status))
    #expect(items(nil, "dock") == w(.apps, .folders, .shelf))   // il nome della categoria
    #expect(items(nil, "wi") == w(.status))
    #expect(items(nil, "wifi") == w(.status) && items(nil, "Wi-Fi") == w(.status) && items(nil, "wifi", italian) == w(.status))
    #expect(items(nil, "-") == all)   // solo trattini: come vuota
    #expect(items(nil, "SHELF") == w(.shelf))
    #expect(items(.dock, "wi") == [])
    // In italiano: "Spazi" è la categoria e "Spazi di AeroSpace" il nome.
    #expect(items(nil, "spazi", italian) == w(.workspaces))
    #expect(items(nil, "STÀTO", italian) == w(.status))
    #expect(catalogShown(category: nil, search: "", bundle: italian).map(\.name)
            == ["App aperte", "Cartelle", "Mensola", "Spazi di AeroSpace", "In riproduzione", "Ora, batteria e Wi‑Fi"])
    #expect(SectionCategory.allCases.map { $0.name(italian) } == ["Dock", "Spazi", "In riproduzione", "Stato"])
}

// Una galleria delle prove: conta se qualcuno la chiude o la toglie dallo schermo (regola del vetro: mai).
private final class WatchedGallery: GalleryPanel {
    var gone = 0
    override func close() { gone += 1 }
    override func orderOut(_ sender: Any?) { gone += 1 }
}

// Tutte le viste dentro una vista.
@MainActor private func subviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subviews) }

// In modifica la galleria si vede al centro dello schermo da cui è partita (nil: quello principale); fuori è trasparente.
// Sempre lo stesso pannello, mai chiuso; nessuna sua vista prende una sezione (una lasciata lì esce dal Dock).
@MainActor @Test func theGalleryFollowsEditing() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let editing = Editing()
    let gallery = WatchedGallery(editing: editing, state: BarState(), settings: Dockduo.Settings(defaults: d))
    editing.gallery = gallery
    #expect(gallery.alphaValue == 0)
    let screen = try #require(NSScreen.screens.last), main = try #require(NSScreen.screens.first)
    let display = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
    func centred(on s: NSScreen) -> Bool {
        abs(gallery.frame.midX - s.visibleFrame.midX) <= 1 && abs(gallery.frame.midY - s.visibleFrame.midY) <= 1
            && s.visibleFrame.contains(gallery.frame)
    }
    editing.begin(on: display)
    #expect(gallery.alphaValue == 1 && centred(on: screen))
    #expect(gallery.frame.width == GalleryPanel.size.width && gallery.frame.height <= GalleryPanel.size.height)
    let host = try #require(gallery.contentView)
    host.layoutSubtreeIfNeeded()
    #expect(subviews(host).count > 1)   // il contenuto c'è
    #expect(!subviews(host).contains { $0.registeredDraggedTypes.contains(.init(DockDrop.sectionType.identifier)) })
    // Esc nella galleria chiude la modifica, un clic lì no (Editing.endsEditing).
    #expect(endsEditing(key: 53, local: true, window: gallery) && !endsEditing(key: nil, local: true, window: gallery))
    editing.end()
    #expect(gallery.alphaValue == 0 && editing.gallery === gallery && gallery.gone == 0)
    editing.begin()
    #expect(gallery.alphaValue == 1 && centred(on: main))
    editing.end()
    #expect(gallery.alphaValue == 0 && gallery.gone == 0)
}

// Una sezione già in un Dock resta nella galleria attenuata, con "nel Dock", e non si trascina; le altre sì (le viste del
// trascinamento ci sono solo per loro).
@MainActor @Test func aSectionAlreadyInADockIsDimmed() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    let tiles = galleryTiles(catalogShown(category: nil, search: ""), settings: s)
    #expect(tiles.map(\.inDock) == [true, true, true, false, true, false])
    let editing = Editing()
    editing.begin(); defer { editing.end() }
    let host = NSHostingView(rootView: GalleryView(editing: editing, state: BarState(), settings: s).frame(width: 735, height: 700))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 735, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    #expect(subviews(host).compactMap { ($0 as? SectionLiftView)?.item } == w(.workspaces, .status))
    // Messo in un Dock (dalla barra o dalla galleria) si attenua anche lui.
    s.docks[0].sections.append(.widget(.workspaces))
    #expect(galleryTiles(catalogShown(category: .workspaces, search: ""), settings: s).map(\.inDock) == [true])
    withExtendedLifetime(window) {}
}

// Una casella lasciata sulla barra: la sezione entra lì (Settings.place), dentro un Dock o in un Dock suo; lo Stato mai
// insieme ad altre. Lasciata fuori dalla barra non succede niente: non era in nessun Dock.
@MainActor @Test func aGalleryTileDropsIntoTheBar() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    let box = s.docks[0]
    let drop = DockDrop(settings: s)
    drop.bars = { [CGRect(x: 0, y: 0, width: 52, height: 1000)] }
    drop.source = .section(.widget(.workspaces))   // quello che fa lift dalla casella
    drop.dropped(at: .into(dock: box.id, index: 1))
    #expect(s.docks.map(\.sections) == [w(.apps, .workspaces, .folders, .shelf, .nowPlaying)] && drop.source == nil)
    drop.source = .section(.widget(.status))
    drop.dropped(at: .into(dock: box.id, index: 2))
    #expect(s.docks.map(\.sections) == [w(.status), w(.apps, .workspaces, .folders, .shelf, .nowPlaying)])
    s.removeSection(.widget(.nowPlaying))
    let before = s.docks
    drop.source = .section(.widget(.nowPlaying))
    drop.ended([], at: CGPoint(x: 600, y: 500), cancelled: false)   // sulla galleria o sulla scrivania
    #expect(s.docks == before && drop.source == nil)
}

// La galleria al centro della parte libera dello schermo del Mac (sotto la barra dei menu, senza Dock), mai più alta di lei
// meno 80; con la barra in basso, alta 71 a 2 dal bordo, al centro della parte sopra la barra (spec app conclusa §3.2).
@Test func theGalleryCentresAboveTheBottomBar() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    #expect(galleryFrame(visible: visible, side: .left, bar: 73) == CGRect(x: 388.5, y: 40, width: 735, height: 869))
    #expect(galleryFrame(visible: visible, side: .right, bar: 73) == galleryFrame(visible: visible, side: .left, bar: 73))
    #expect(galleryFrame(visible: visible, side: .bottom, bar: 73) == CGRect(x: 388.5, y: 113, width: 735, height: 796))
}

// La prova a occhio della galleria (GALLERY_SHOTS=cartella): a 2×, in scuro e in chiaro, col Dock dell'autore (App aperte,
// Cartelle, Mensola, In riproduzione in un Dock; Spazi e Stato fuori). Fuori dallo schermo il vetro non si disegna: sotto,
// il colore del pannello del Centro di Controllo misurato sulla cattura (scuro) e un grigio chiaro a occhio.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["GALLERY_SHOTS"] != nil)) func galleryShots() async throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GALLERY_SHOTS"]!)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let s = Dockduo.Settings(defaults: d)
    authorDock(s)
    let state = BarState()
    state.dock = NSWorkspace.shared.runningApplications.filter { $0.icon != nil && $0.activationPolicy == .regular }.prefix(5).enumerated()
        .map { AppEntry(name: "A\($0.offset)", pid: $0.element.processIdentifier, windowID: $0.offset, bundle: "test.\($0.offset)") }
    state.reports = ["1", "2", "3", "4"].map { SpaceReport(workspace: Workspace(name: $0, isFocused: $0 == "2"), apps: []) }
    let editing = Editing()
    editing.begin(); defer { editing.end() }
    for (file, dark) in [("galleria-scuro", true), ("galleria-chiaro", false)] {
        let backdrop = dark ? NSColor(srgbRed: 41 / 255, green: 46 / 255, blue: 58 / 255, alpha: 1)
            : NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
        let view = GalleryView(editing: editing, state: state, settings: s)
            .frame(width: GalleryPanel.size.width, height: GalleryPanel.size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        try await shot(view, backdrop: backdrop, to: out.appendingPathComponent("\(file).png"))
    }
}
