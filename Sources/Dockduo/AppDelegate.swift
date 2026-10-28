import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // dockduo riaperta mentre gira (Finder, Spotlight, Dock): il Dock in modifica (spec impostazioni-nel-dock §1), con la
    // galleria sullo schermo principale.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Editing.shared.begin()
        return false   // fatto qui: niente altro da riaprire
    }

    // Chiusa dal suo menu (spec dockduo §4): i lati di AeroSpace tornano quelli di prima prima di uscire (AerospaceGaps). Un
    // sync rimandato (main.swift) non deve riscriverli mentre il ripristino aspetta i comandi, che fanno girare il run loop.
    func applicationWillTerminate(_ notification: Notification) {
        gapsSync?.cancel()
        restoreGapsAtQuit()
    }
}

// dockduo è accessory (niente Dock, niente ⌘-Tab): da lì NSApp.activate() non basta quando la chiamata parte da un
// NSMenu, alla chiusura del tracking AppKit rimette avanti l'app di prima (verificato il 2026-09-21 con System Events).
// Diventare un'app normale mentre la sua finestra (il Benvenuto, l'unica) è aperta risolve; chiusa, si torna accessory. Il
// menu dell'app (i ⌘-tasti, vedi appMenu) si imposta quando la finestra si apre: prima non serve a nessuno.
enum Activation {
    static func opened(_ window: NSWindow) {
        NSApp.mainMenu = appMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func closed() { NSApp.setActivationPolicy(.accessory) }

    // Con la finestra aperta l'app è .regular: questo menu SI vede (mouse in alto), e AppKit usa il primo item come menu
    // dell'app (dalla posizione, non dal titolo). Il primo item è quindi il menu di dockduo; gli altri instradano i tasti
    // standard (⌘C/⌘V/⌘X/⌘A/⌘Z, ⌘W) nella finestra attraverso la responder chain (target nil, come il menu dell'app).
    // Niente Impostazioni… con ⌘,: le impostazioni sono il sottomenu della barra, non una finestra.
    private static func appMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(title: "dockduo")
        app.addItem(NSMenuItem(title: String(localized: "About dockduo"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: String(localized: "Hide dockduo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: String(localized: "Quit dockduo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: String(localized: "Window"))
        win.addItem(NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        winItem.submenu = win
        return main
    }
}
