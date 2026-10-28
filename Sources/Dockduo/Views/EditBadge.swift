import SwiftUI

// Il Dock in modifica (spec impostazioni-nel-dock §2), copiato dal Centro di Controllo in modifica (screenshot dell'autore
// del 26/10, a 2×): ogni sezione staccata da un bordo leggero, col "−" in alto a sinistra. Sulla cattura un modulo piccolo
// è largo 63,5 e il "−" è un cerchio di 19,75 (0,31 del modulo) col centro sull'angolo curvo del modulo, a 45° e un filo
// fuori (8,5 e 7,75 dall'angolo del riquadro, col modulo a raggio 31,75); grigio scuro velato: 74,63,58 sul fondo chiaro a
// 149,137,125 e 38,38,49 su quello scuro a 0,4,16, cioè un grigio 51 al 76 %. Il segno bianco al 90 %, lungo 0,45 e spesso
// 0,075 del cerchio, con le punte tonde. Da noi il modulo è la sezione dentro il suo bordo: larga 37 (le caselle da 31 e 3
// per lato), con gli angoli concentrici alla capsula (15,5 a 4 dal suo bordo: 11,5); quindi il "−" largo 0,31 × 37 = 11,5,
// col centro a 3 dall'angolo del bordo. Il bordo è la linea del Dock (DockSeparator) attorno alla sezione: spesso 1, al 27 %;
// quello di una sezione vuota è il tratteggio della mensola vuota (EmptyShelfTile). Il bordo non cambia la misura della
// sezione: sta nei margini della capsula e nel posto della linea, che in modifica non c'è. Niente si muove da solo: il
// Centro di Controllo in modifica sta fermo.
// In modifica la barra ha il velo quasi invisibile (SideBarView): il "−" che sporge e le parti vuote del bordo e dello Stato
// prendono i clic, invece di lasciarli a chi c'è sotto. Un clic non apre e non alterna niente, col ⌘ o senza: il contenuto
// della sezione non prende clic. Senza ⌘ lo prende la sezione (SectionMenuView, il suo menu), col ⌘ la barra sotto, che col ⌘
// trascina i Dock.
struct EditFrame: ViewModifier {
    let item: BarItem
    let on: Bool   // in modifica; fuori, la sezione resta com'è (e non perde il suo stato)
    var empty = false
    let settings: Settings
    var shift: CGFloat = 0   // lo Stato sta mezzo punto verso il bordo dello schermo (StatusElement): il bordo con lui
    @Environment(\.barScale) private var scale

    func body(content: Content) -> some View {
        let u = dockUnit * scale, badge = 11.5 * u, reach = 3 * u   // il "−" prende i clic anche un filo attorno
        let corner = 3 * u - badge / 2   // dove comincia il "−", per avere il centro a 3 dall'angolo del bordo
        let name = switch item { case .widget(let w): w.title }
        content.allowsHitTesting(!on).overlay {
            if on {
                ZStack(alignment: .topLeading) {
                    MenuAnchor { SectionMenuView(item: item, settings: settings) }
                    // Il bordo non passa sotto il "−", velato: come quello del modulo sotto il "−" del Centro di Controllo.
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 11.5 * u, style: .continuous)
                            .strokeBorder(.foreground.opacity(empty ? 0.5 : 0.27),
                                          style: StrokeStyle(lineWidth: 1 * u, dash: empty ? [3 * u, 2 * u] : []))
                        Circle().frame(width: badge, height: badge).offset(x: corner, y: corner).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .allowsHitTesting(false)
                    EditBadge(size: badge).padding(reach).contentShape(Circle())
                        .offset(x: corner - reach, y: corner - reach)
                        .onTapGesture { settings.removeSection(item) }
                        .accessibilityElement().accessibilityLabel(Text("Remove \(name)")).accessibilityAddTraits(.isButton)
                }
                .padding(.vertical, -3 * u)
                .frame(width: 37 * u)
                .offset(x: shift)
                .transition(.opacity)
            }
        }
    }
}

// Il "−" del Centro di Controllo in modifica (misure sopra).
struct EditBadge: View {
    let size: CGFloat

    var body: some View {
        Circle().fill(Color(white: 0.2).opacity(0.76))
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 0.45 * size, height: 0.075 * size))
            .frame(width: size, height: size)
    }
}

// Una sezione vuota in modifica (§2: Cartelle senza cartelle, Mensola senza file, In riproduzione ferma, App aperte senza
// app): solo il suo simbolo, senza nome (autore, 27/10: «mantieni solo l'icona senza etichetta»), nel posto di una casella
// del Dock (31), dentro il bordo tratteggiato di EditFrame. Il nome resta per VoiceOver.
struct EmptySectionBox: View {
    let id: WidgetID
    @Environment(\.barScale) private var scale

    var body: some View {
        let u = dockUnit * scale
        Image(systemName: id.symbol).font(.system(size: 12 * u, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: dockIcon * scale, height: dockIcon * scale)
            .accessibilityLabel(Text(id.title))
    }
}

extension WidgetID {
    // Già tradotto (String, non chiave): sta anche dentro "Rimuovi %@" per VoiceOver.
    var title: String {
        switch self {
        case .workspaces: String(localized: "Workspaces"); case .apps: String(localized: "Open apps")
        case .folders: String(localized: "Folders"); case .shelf: String(localized: "Shelf")
        case .nowPlaying: String(localized: "Now Playing"); case .status: String(localized: "Status")
        }
    }
    // Il simbolo della sezione: nella sua casella vuota in modifica.
    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"; case .folders: "folder"; case .shelf: "doc"
        case .workspaces: "rectangle.split.3x1"; case .nowPlaying: "music.note"; case .status: "clock"
        }
    }
}

// Fine, subito sotto l'ultimo Dock in modifica (§2): il pulsante blu del Centro di Controllo alla sua misura vera (sulla
// cattura 59 × 28, il testo a 13 medio, bianco sul blu di sistema), non in scala con la barra (autore, 27/10: «è enorme il
// testo»); in una barra stretta non più largo della capsula del Dock. Chiude la modifica su tutte le barre. Lo stesso in
// fondo alla galleria, largo 60 come quello del Centro di Controllo (`width`).
struct EditDoneButton: View {
    var width: CGFloat?   // nil: quella della barra
    var editing = Editing.shared   // la galleria dà la sua
    @Environment(\.barScale) private var scale

    var body: some View {
        Text("Done").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
            .frame(width: width ?? min(59, dockWidth * scale), height: 28)
            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
            .contentShape(Capsule())
            .onTapGesture { editing.end() }
            .accessibilityAddTraits(.isButton)
    }
}
