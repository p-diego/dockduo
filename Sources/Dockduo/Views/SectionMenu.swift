import AppKit
import UniformTypeIdentifiers

// Le opzioni di una sezione (spec impostazioni-nel-dock §4): in modifica un clic sulla sezione apre questo menu accanto a lei,
// con quello che stava nella sua schermata delle impostazioni, e in fondo Togli dal Dock. App aperte, Cartelle e Mensola
// hanno i nomi al passaggio (uno per tutte e tre, come prima); lo Stato l'app del clic sull'ora e, senza la Posizione, la
// voce che la chiede (`noLocation`: le prove la danno). Il menu è la fotografia di quando si apre.
@MainActor func sectionMenu(_ item: BarItem, settings: Settings = .shared, noLocation: Bool = locationMissing()) -> NSMenu {
    let menu = NSMenu()
    switch item {
    case .widget(.apps), .widget(.folders), .widget(.shelf):
        menu.addItem(ActionItem(String(localized: "Show names on hover"), on: settings.dockHoverNames) { settings.dockHoverNames.toggle() })
    case .widget(.workspaces):
        menu.addItem(ActionItem(String(localized: "Front app name on the active workspace"), on: settings.showFrontAppName) {
            settings.showFrontAppName.toggle()
        })
    case .widget(.nowPlaying):
        menu.addItem(ActionItem(String(localized: "Large artwork in the menu"), on: settings.bigArtwork) { settings.bigArtwork.toggle() })
    case .widget(.status):
        let opens = NSMenuItem(title: String(localized: "Click opens"), action: nil, keyEquivalent: "")
        opens.submenu = clockAppMenu(settings)
        menu.addItem(opens)
        if noLocation { menu.addItem(ActionItem(String(localized: "Show network name…")) { requestLocation() }) }
    }
    menu.addItem(.separator())
    menu.addItem(ActionItem(String(localized: "Remove from Dock")) { settings.removeSection(item) })
    return menu
}

// "Il click apre": l'app di adesso con la spunta e la sua icona, come Apri con del Finder; Scegli… e Nessuna.
@MainActor private func clockAppMenu(_ settings: Settings) -> NSMenu {
    let menu = NSMenu(), bundle = settings.clockApp
    if let name = appName(bundle: bundle) {
        let app = ActionItem(name, on: true) {}
        app.image = appIcon(bundle: bundle).map { $0.size = NSSize(width: 16, height: 16); return $0 }
        menu.addItem(app)
    }
    // Dopo la chiusura del menu: aperto durante il tracking, il pannello resterebbe dietro l'app di prima.
    menu.addItem(ActionItem(String(localized: "Choose…")) { DispatchQueue.main.async { chooseClockApp(settings) } })
    menu.addItem(ActionItem(String(localized: "None"), on: bundle.isEmpty) { settings.clockApp = "" })
    return menu
}

// Scegli…: il pannello "Apri" di macOS limitato alle app, da solo (la finestra delle impostazioni non c'è più a fargli da
// foglio). Un clic o Esc lì dentro non chiudono la modifica (endsEditing): Esc annulla solo il pannello.
@MainActor private func chooseClockApp(_ settings: Settings) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = String(localized: "Choose")
    Editing.shared.opensWindow(keepingEditing: panel)
    NSApp.activate()
    panel.begin { response in
        guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        settings.clockApp = id
    }
}

// Premere e muovere di 4 punti, come le cartelle: la sezione passa ad AppKit (DockDrop.lift). Sulla barra (SectionMenuView)
// e nella galleria (SectionLiftView).
struct LiftTracker {
    var pressedAt: NSPoint?   // dove è cominciato il clic sinistro; nil quando è diventato un trascinamento
    // Vero al primo movimento oltre i 4 punti dalla pressione, una volta sola: da lì è un trascinamento.
    mutating func shouldLift(at p: NSPoint) -> Bool {
        guard let start = pressedAt, hypot(p.x - start.x, p.y - start.y) >= 4 else { return false }
        pressedAt = nil
        return true
    }
}

// La vista dei clic di una sezione in modifica, su tutto il suo bordo (EditFrame): un clic, sinistro o destro, apre le sue
// opzioni accanto a lei (al rilascio, sopra di lei), e intanto non arriva ad app, cartelle e file sotto, che in modifica non
// si aprono. Col ⌘ il clic passa alla barra, per il ⌘-trascina dei Dock. È un RightClickMenuView: così il menu del vetro del
// Dock (DockMenuView) le lascia il tasto destro. Trascinata oltre 4 punti (come le cartelle) la sezione si sposta
// (DockDrop.lift), e il rilascio non apre il menu.
final class SectionMenuView: RightClickMenuView {
    let item: BarItem
    private let settings: Settings
    private var press = LiftTracker()
    init(item: BarItem, settings: Settings) {
        (self.item, self.settings) = (item, settings)
        super.init(frame: .zero)
        // VoiceOver: la sezione come un pulsante che apre le sue opzioni.
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        let name = switch item { case .widget(let w): w.title }
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { nil }

    override func menu() -> NSMenu { sectionMenu(item, settings: settings) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let e = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(e.type), !e.modifierFlags.contains(.command),
              !isHidden, frame.contains(point) else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // la barra non è mai la finestra attiva
    override func mouseDown(with event: NSEvent) { press.pressedAt = event.locationInWindow }   // il clic è suo: senza, andrebbe alla vista sotto
    override func mouseDragged(with event: NSEvent) {
        if press.shouldLift(at: event.locationInWindow) { DockDrop.shared.lift(section: item, from: self, event: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if press.pressedAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { pop() }
        press.pressedAt = nil
    }
    override func accessibilityPerformPress() -> Bool { pop(); return true }
}
