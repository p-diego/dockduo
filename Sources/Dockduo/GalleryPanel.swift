import AppKit
import SwiftUI

// La galleria delle sezioni (spec impostazioni-nel-dock §3), il pannello "Modifica controlli" del Centro di Controllo: in
// modifica compare al centro dello schermo da cui è partita (Editing.display; nil: quello principale). Creata una volta
// (main.swift), mai chiusa, ricreata o tolta dallo schermo (regola del vetro): fuori dalla modifica è trasparente e vuota,
// il suo contenuto c'è solo in modifica (GalleryRoot), quindi a riposo non costa niente. Prende i tasti senza attivare
// dockduo (pannello che non attiva): il campo di ricerca scrive ed Esc chiude la modifica (EditWindow). Non prende le sezioni
// trascinate: una lasciata qui esce dal Dock (DockDrop.ended), come dal Centro di Controllo.
class GalleryPanel: NSPanel, EditWindow {
    // Il pannello della cattura: 735 × 900 (la barra laterale 245, il resto tre colonne da 140 coi loro margini).
    static let size = CGSize(width: 735, height: 900)
    private let settings: Settings   // il lato e la larghezza della barra (galleryFrame)

    init(editing: Editing, state: BarState, settings: Settings = .shared) {
        self.settings = settings
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = parkedMenuBar ? SidePanel.aboveParkedMenuBar : SidePanel.belowMenuBar   // con la barra, sopra le finestre
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        canHide = false
        alphaValue = 0
        let host = NSHostingView(rootView: GalleryRoot(editing: editing, state: state, settings: settings))
        host.sizingOptions = []   // la misura è quella del pannello
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    // Dove dice galleryFrame; prende i tasti, come il campo di ricerca del Centro di Controllo. Solo una galleria davanti
    // (quella vera): quelle delle prove restano fuori.
    func show(on display: CGDirectDisplayID?) {
        let screen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display }
            ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            setFrame(galleryFrame(visible: visible, side: settings.barSide, bar: barEdge + settings.sideWidth), display: false)
        }
        alphaValue = 1
        guard isVisible else { return }
        makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.invalidateShadow() }   // a contenuto comparso
    }

    // Trasparente. I tasti tornano all'app davanti: li aveva la galleria senza attivare dockduo, e da trasparente se li
    // terrebbe. Un attimo dopo, e solo se li ha ancora: chiusa da un clic in un'altra app, quella li ha già presi e resta lei.
    // Con dockduo davanti (dopo "Scegli…" dello Stato, o riaperta dal Finder) li ridà lasciando il posto all'app di prima.
    func hide() {
        alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, alphaValue == 0, isKeyWindow else { return }
            if NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { NSApp.deactivate() }
            else { NSWorkspace.shared.frontmostApplication?.activate() }
        }
    }
}

// Al centro della parte libera dello schermo (`visible`: senza barra dei menu e Dock), mai più alta di lei meno 80. Con la
// barra in basso, della parte sopra la barra (`bar`: margine dal bordo più spessore; spec app conclusa §3.2).
func galleryFrame(visible: CGRect, side: Side, bar: CGFloat) -> CGRect {
    let free = side == .bottom ? visible.divided(atDistance: bar, from: .minYEdge).remainder : visible
    let size = GalleryPanel.size, height = min(size.height, free.height - 80)
    return CGRect(x: free.midX - size.width / 2, y: free.midY - height / 2, width: size.width, height: height)
}

// Il contenuto della galleria solo in modifica, sul vetro del pannello del Centro di Controllo (gli angoli dalla cattura: 16).
// Compare sfumando; sparisce subito, col pannello già trasparente.
struct GalleryRoot: View {
    let editing: Editing
    let state: BarState
    let settings: Settings

    var body: some View {
        ZStack {
            if editing.on {
                GalleryView(editing: editing, state: state, settings: settings)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.2), value: editing.on)
    }
}
