import AppKit
import SwiftUI

// La galleria (spec impostazioni-nel-dock §3), copiata dal pannello "Modifica controlli" del Centro di Controllo (cattura
// dell'autore del 26/10, a 2×; qui in punti). A sinistra la barra laterale larga 245, staccata da una linea: il campo di
// ricerca alto 28 a 20 dai bordi e, 10 sotto, una riga alta 46 per categoria ("Tutte" in cima), con l'icona da 26 a 10 dal
// bordo della riga e il nome a 13 a 11,5 dall'icona; la scelta su un velo al 12 % con gli angoli da 10. A destra, a 17 dai
// bordi, le categorie una sotto l'altra, staccate da una linea (il titolo a 13 sotto di lei): il titolo a 12 seminero
// grigio, 22 sotto le caselle, in tre colonne da 140 a 6 dai bordi e a 12 l'una dall'altra; il nome di ogni casella a 11,
// 8 sotto; 25 dopo l'ultima riga. Una grandezza sola (§3): il modulo largo del Centro di Controllo, 140 × 64. In fondo, alto
// 67 sotto una linea, "Trascina una sezione nel Dock…" a 13 e Fine, 19 dal bordo.
struct GalleryView: View {
    let editing: Editing
    let state: BarState
    let settings: Settings
    var drop = DockDrop.shared   // la casella in mano si attenua, come la sezione sulla barra
    @State private var category: SectionCategory?   // nil: Tutte
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 245)
            Divider()
            content
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SearchField(text: $search).frame(height: 28).padding(.bottom, 10)
            row(nil)
            ForEach(SectionCategory.allCases, id: \.self) { row($0) }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top], 20)
    }

    private func row(_ c: SectionCategory?) -> some View {
        let chosen = category == c
        return HStack(spacing: 11.5) {
            CategoryIcon(category: c)
            Text(c?.name() ?? String(localized: "All")).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(height: 46)
        .background { if chosen { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.12)) } }
        .contentShape(Rectangle())
        .onTapGesture { category = c }
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private var content: some View {
        let shown = catalogShown(category: category, search: search)
        let categories = SectionCategory.allCases.filter { c in shown.contains { $0.category == c } }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(categories, id: \.self) { c in
                        if c != categories.first { Divider().padding(.bottom, 13) }
                        Text(c.name()).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(140), spacing: 12, alignment: .top), count: 3),
                                  alignment: .leading, spacing: 18) {
                            ForEach(galleryTiles(shown.filter { $0.category == c }, settings: settings), id: \.entry.item, content: tile)
                        }
                        .padding(.horizontal, 6).padding(.top, 22).padding(.bottom, 25)
                    }
                }
                .padding(.horizontal, 17).padding(.top, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.horizontal, 17)
            HStack {
                Text("Drag a section into the Dock…").font(.system(size: 13))
                Spacer()
                EditDoneButton(width: 60, editing: editing)   // il Fine del Centro di Controllo, 60 × 28
            }
            .padding(.leading, 17).padding(.trailing, 19)
            .frame(height: 67)
        }
    }

    // Una casella col nome sotto. Già in un Dock: attenuata, con "nel Dock", ferma; se no si trascina sulla barra
    // (SectionLiftView). Quello che mostra non prende clic: la galleria non apre e non suona niente.
    private func tile(_ t: GalleryTile) -> some View {
        VStack(spacing: 8) {
            SectionPreview(item: t.entry.item, state: state, settings: settings)
                .allowsHitTesting(false)
                .frame(width: 140, height: 64)
                .background(TileGlass())
                .opacity(t.inDock ? 0.45 : t.entry.item == drop.movingSection ? lifted : 1)
                .overlay { if !t.inDock { MenuAnchor { SectionLiftView(item: t.entry.item) } } }
            VStack(spacing: 1) {
                Text(t.entry.name).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(2)
                if t.inDock { Text("In the Dock").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SectionCategory {
    var color: Color {
        switch self { case .dock: .blue; case .workspaces: .teal; case .nowPlaying: .pink; case .status: .green }
    }
}

// L'icona di una categoria, come quelle del Centro di Controllo: in scuro un quadrato quasi nero (da 37 a 18 dall'alto, sulla
// cattura) col simbolo colorato, in chiaro bianco; "Tutte" i quattro pallini, senza quadrato.
private struct CategoryIcon: View {
    let category: SectionCategory?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let category {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(scheme == .dark ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.145), Color(white: 0.07)], startPoint: .top,
                                                                      endPoint: .bottom)) : AnyShapeStyle(.white))
                .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .overlay(Image(systemName: category.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(category.color))
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "circle.grid.2x2.fill").font(.system(size: 15)).frame(width: 26, height: 26)
        }
    }
}

// La capsula di vetro di un modulo del Centro di Controllo: sulla cattura, in scuro, bianco al 5,6 % sul pannello, col bordo
// sottile chiaro sopra e sotto e scuro ai lati. In chiaro bianco a metà, col bordo appena scuro.
private struct TileGlass: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let rim = dark ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.3), .black.opacity(0.6), .white.opacity(0.25)],
                                                      startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.black.opacity(0.08))
        let shape = Capsule(style: .circular)   // le punte tonde della cattura, non quelle continue
        shape.fill(.white.opacity(dark ? 0.056 : 0.5)).overlay(shape.strokeBorder(rim, lineWidth: 0.5))
    }
}

// Quello che la sezione mostra adesso, in fila nella casella (spec §3: la sezione vera e viva): le prime app, cartelle o file
// del Dock, gli spazi di AeroSpace, il brano, lo Stato. Senza niente, il suo simbolo, come la sua casella vuota in modifica.
// In riproduzione fuori da ogni Dock mostra una copertina d'esempio: la sua lettura chiede l'Automazione, la galleria mai.
// Lo Stato spento legge batteria e Wi‑Fi per sé, una volta: da spento la barra non li legge.
private struct SectionPreview: View {
    let item: BarItem
    let state: BarState
    let settings: Settings
    @State private var sample = BarState()   // lo Stato spento
    @Environment(\.colorScheme) private var scheme

    // Ogni casella legge solo quello della sua sezione (le condizioni dei casi si guardano solo per lei): un cambio altrove non
    // la ridisegna.
    var body: some View {
        switch item {
        case .widget(.apps) where !state.dock.isEmpty:
            HStack(spacing: 4) {
                ForEach(state.dock.prefix(3), id: \.pid) { app in
                    Group { if let icon = appIcon(app) { Image(nsImage: icon).resizable() } }
                        .frame(width: 36, height: 36).opacity(app.dimmed ? 0.6 : 1)
                }
            }
        case .widget(.folders) where !firstURLs(settings.dockFolders).isEmpty: files(firstURLs(settings.dockFolders))
        case .widget(.shelf) where !firstURLs(settings.dockShelf).isEmpty: files(firstURLs(settings.dockShelf))
        case .widget(.workspaces) where !spaces.isEmpty:
            HStack(spacing: 5) {
                ForEach(spaces, id: \.workspace.name) { r in
                    Text(r.workspace.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(r.workspace.isFocused ? 0.22 : 0.08)))
                }
            }
        case .widget(.nowPlaying): nowPlaying(settings.isOn(.nowPlaying) ? state.track : nil)
        case .widget(.status):
            // Bianco come sullo sfondo; in chiaro, sulla casella chiara, col colore del testo (i colori dell'anello si perdono).
            let element = StatusElement(state: settings.isOn(.status) ? state : sample).environment(\.barScale, 1.6)
            Group { if scheme == .dark { element } else { Color.primary.mask(element) } }
                .onAppear { if !settings.isOn(.status) { (sample.battery, sample.wifi) = (readBattery(), readWiFi()) } }
        case .widget(let w):
            Image(systemName: w.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private var spaces: ArraySlice<SpaceReport> { state.reports.filter { !$0.workspace.name.isEmpty }.prefix(4) }
    private func firstURLs(_ items: [DockItem]) -> [URL] { items.filter(\.shown).prefix(3).compactMap(\.url) }

    private func files(_ urls: [URL]) -> some View {
        HStack(spacing: 4) { ForEach(urls, id: \.self) { FileIcon(url: $0) } }
    }

    // La copertina (d'esempio senza brano o senza la sua) e, col brano, titolo e artista, come il modulo del Centro di Controllo.
    private func nowPlaying(_ track: Track?) -> some View {
        HStack(spacing: 10) {
            Group {
                if track != nil, let art = state.artwork {
                    Image(nsImage: art).resizable()
                } else {
                    LinearGradient(colors: [.pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                }
            }
            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let track {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 12, weight: .semibold))
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .lineLimit(1).frame(maxWidth: 66, alignment: .leading)
            }
        }
    }
}

// Una cartella o un file con l'icona del Finder, chiesta fuori dal main (come DockFileTile).
private struct FileIcon: View {
    let url: URL
    @State private var icon: NSImage?

    var body: some View {
        Group { if let icon { Image(nsImage: icon).resizable() } }
            .frame(width: 36, height: 36)
            .task(id: url) { icon = await finderIconAndName(url).icon }
    }
}

// Il campo di ricerca del Centro di Controllo: quello di macOS, grande, coi tasti suoi quando la galleria compare.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search Sections")
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) { if field.stringValue != text { field.stringValue = text } }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) { text.wrappedValue = (note.object as? NSSearchField)?.stringValue ?? "" }
    }
}

// Il trascinamento di una casella, come quello di una sezione sulla barra (SectionMenuView): oltre 4 punti la sezione passa ad
// AppKit (DockDrop.lift), con la casella come immagine, e la barra la mette dove la lasci. Prende anche il primo clic: la
// galleria non attiva dockduo.
final class SectionLiftView: NSView {
    let item: BarItem
    private var press = LiftTracker()
    init(item: BarItem) {
        self.item = item
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { press.pressedAt = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        if press.shouldLift(at: event.locationInWindow) { DockDrop.shared.lift(section: item, from: self, event: event) }
    }
    override func mouseUp(with event: NSEvent) { press.pressedAt = nil }
}
