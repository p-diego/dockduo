import SwiftUI

// Se una sezione ha qualcosa da mostrare adesso. Una vuota resta fuori dal suo Dock, senza linee (spec dock-contenitori
// §3), e un Dock senza niente da mostrare non disegna niente (DockBoxView). Cartelle e mensola: solo le voci risolte e su un disco montato; la cartella che stai trascinando
// ha lasciato il suo posto. Durante un trascinamento sopra il Dock, o dal Finder sopra la barra, la mensola vuota e il
// posto in fondo alle cartelle contano come pieni: quello lo sa il Dock. `drop`: il trascinamento della barra (le prove ne danno uno loro).
// In modifica si vedono tutte, anche vuote (spec impostazioni-nel-dock §2): una vuota è la sua casella tratteggiata.
@MainActor func barItemShows(_ id: BarItem, state: BarState, settings: Settings = .shared, drop: DockDrop = .shared,
                             editing: Editing? = nil) -> Bool {
    (editing ?? .shared).on || barItemHasContent(id, state: state, settings: settings, drop: drop)
}

func barItemHasContent(_ id: BarItem, state: BarState, settings: Settings, drop: DockDrop) -> Bool {
    switch id {
    case .widget(.apps): !state.dock.isEmpty
    case .widget(.folders): settings.dockFolders.contains { $0.shown && $0.id != drop.moving }
    case .widget(.shelf): settings.dockShelf.contains(where: \.shown)
    case .widget(.nowPlaying): state.track != nil
    case .widget(.workspaces), .widget(.status): true   // lo Stato ha sempre l'ora
    }
}

// Quello che serve alle pillole degli spazi per il trascina icone: lo stato (bersaglio, icona in mano) e i gesti,
// che restano della barra che li possiede.
struct IconDragHooks {
    let target: String?   // la pillola su cui cadrebbe l'icona
    let dragging: Int?   // la finestra trascinata
    let onDrag: (AppEntry, String, CGPoint, CGPoint) -> Void   // l'app, la sua pillola, il punto di presa e il puntatore
    let onDrop: (CGPoint) -> Void
    let pillFrame: (String, CGRect) -> Void   // la cornice di una pillola nello spazio "bar"
}

// Una sezione di un Dock: un widget, la pillola di prima. App aperte, cartelle e mensola le disegna il Dock stesso
// (DockBoxView), con le sue caselle; lo Stato anche, al posto della capsula.
struct BarItemView: View {
    let id: BarItem
    let state: BarState
    let icons: IconDragHooks
    private let settings = Settings.shared

    var body: some View {
        switch id {
        case .widget(let w): widget(w)
        }
    }

    // Un widget per id (impostazioni: Barra). Le pillole degli spazi sono un widget solo.
    @ViewBuilder private func widget(_ id: WidgetID) -> some View {
        switch id {
        case .workspaces:
            WorkspacesRow {
                ForEach(state.reports, id: \.workspace.name) { r in
                    let name = r.workspace.name
                    let reduced = name.isEmpty   // la pillola ridotta non riceve trascinamenti (spec senza-aerospace §3)
                    WorkspacePill(report: r, frontWindow: settings.showFrontAppName ? state.frontWindow : nil,
                                  highlighted: icons.target == name, dragging: icons.dragging,
                                  onDrag: reduced ? { _, _, _ in } : { app, start, at in icons.onDrag(app, name, start, at) },
                                  onDrop: reduced ? { _ in } : icons.onDrop)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { icons.pillFrame(name, $0) }
                        .transition(.blurReplace)
                }
            }
        case .apps, .folders, .shelf, .status: EmptyView()
        case .nowPlaying: if let t = state.track { NowPlayingView(track: t, artwork: state.artwork) }
        }
    }
}
