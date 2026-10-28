import AppKit

// Click sull'ora dell'elemento di stato: attiva l'app scelta nelle opzioni dello Stato (Il click apre), come dal Dock:
//   non in esecuzione   → la lancia
//   in primo piano      → la nasconde (⌘H): torni dov'eri
//   altrimenti          → la mostra e mette a fuoco la sua prima finestra visibile (AeroSpace cambia spazio se serve);
//                         senza finestre, il "reopen" del Dock
// Come si vede (flottante, su quale spazio) lo decide la config di AeroSpace (`on-window-detected`), non dockduo.
func toggleApp(bundle: String) {
    guard !bundle.isEmpty else { return }
    guard let app = runningApps(bundle: bundle).first else { open("-b", bundle); return }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { app.hide(); return }
    app.unhide()
    DispatchQueue.global().async {
        if let id = firstShowableWindow(bundle: bundle) { _ = aerospace("focus", "--window-id", String(id)) } else { open("-b", bundle) }
        DispatchQueue.main.async { poller.tick() }
    }
}
