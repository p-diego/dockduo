import AppKit

// Il Dock in modifica (spec impostazioni-nel-dock §1-2), come il Centro di Controllo: "Modifica Dock…" la accende su tutte le
// barre, Fine (in fondo alla barra o alla galleria), Esc o un clic (sinistro o destro) fuori da dockduo la spengono
// (endsEditing). `display`: lo schermo da cui è partita, dove compare la galleria (GalleryPanel; nil = quello principale).
// I monitor ci sono solo in modifica: quello di dockduo per Esc e i clic, quello di fuori solo per i clic (uno dei tasti
// chiederebbe il permesso di Monitoraggio dell'input).
// Col nascondi automatico la barra esce e resta fuori finché dura (SidePanel.autohideTick); all'uscita rientra da sé.
@Observable @MainActor final class Editing {
    static let shared = Editing()
    private(set) var on = false
    private(set) var display: CGDirectDisplayID?
    @ObservationIgnored private var monitors: [Any] = []
    var monitorsInstalled: Int { monitors.count }   // per le prove
    @ObservationIgnored var gallery: GalleryPanel?   // la galleria (main.swift; le prove ne danno una loro)
    static let outsideClicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]   // i clic di fuori che la chiudono

    func begin(on display: CGDirectDisplayID? = nil) {
        guard !on else { return }
        (on, self.display) = (true, display)
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            self?.check(e, local: true)
            return e   // Esc e il clic arrivano comunque dove andavano
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: Self.outsideClicks) { [weak self] e in self?.check(e, local: false) }
        monitors = [local, global].compactMap { $0 }
        (NSApp?.windows ?? []).compactMap { $0 as? SidePanel }.filter(\.active).forEach { $0.reveal() }
        gallery?.show(on: display)
    }

    func end() {
        guard on else { return }
        monitors.forEach(NSEvent.removeMonitor)
        (monitors, on, display) = ([], false, nil)
        gallery?.hide()
    }

    private func check(_ e: NSEvent, local: Bool) {
        if endsEditing(key: e.type == .keyDown ? e.keyCode : nil, local: local, window: e.window) { end() }
    }

    // Una finestra aperta da un menu della barra: la galleria sta sopra le finestre (al livello della barra) e la coprirebbe.
    // Un'azione della modifica (lo "Scegli…" dello Stato) la tiene: la sua finestra va un gradino sopra la galleria, prima di
    // aprirsi. Le altre (Configurazione iniziale…, Informazioni su dockduo) non sono modifica: la chiudono, poi si aprono come
    // sempre.
    func opensWindow(keepingEditing window: NSWindow? = nil) {
        guard let window else { end(); return }
        if let gallery { window.level = NSWindow.Level(rawValue: gallery.level.rawValue + 1) }
    }
}

// Un evento chiude la modifica: Esc (53) in una finestra della modifica (la barra, la galleria: EditWindow), non in un'altra
// nostra come il "Scegli…" dello Stato, dove annulla il pannello; un clic fuori da dockduo (in un'altra app, sulla
// scrivania: `local` falso), mai in una finestra nostra. `key` nil = un clic.
func endsEditing(key: UInt16?, local: Bool, window: NSWindow?) -> Bool {
    local ? key == 53 && window is EditWindow : key == nil
}

// Le finestre della modifica: Esc lì la chiude. La barra (che non prende mai i tasti) e la galleria.
protocol EditWindow {}
extension SidePanel: EditWindow {}

// In fondo a ogni menu della barra (spec §1): Modifica Dock…, sullo schermo di quella barra, e il sottomenu Impostazioni. Staccate dalle
// voci di prima; un menu che non ne ha (il vetro del Dock) comincia da qui.
@MainActor func addEditItems(to menu: NSMenu, from view: NSView) {
    let display = (view.window as? SidePanel)?.place.display
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    menu.addItem(ActionItem(String(localized: "Edit Dock…")) { Editing.shared.begin(on: display) })
    menu.addItem(settingsMenuItem())   // il sottomenu Impostazioni (SettingsMenu.swift)
}
