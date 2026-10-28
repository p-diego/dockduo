import SwiftUI

// Trascinare l'icona di una finestra su un'altra pillola spazio (spec 2026-09-26-siigil-trascina-icone-design.md):
// la finestra passa a quello spazio. Qui lo stato, le due decisioni pure e le regole del trascinamento (IconDragging),
// in colonna; il gesto sta in WorkspacePill. Sul modello del ⌘-trascina dei Dock (SideRearrange.swift).

// Il trascinamento in corso, nello spazio di coordinate "bar": la finestra, lo spazio di partenza, il punto di presa
// (dove torna la copia se il rilascio non va a segno), il puntatore e il lato della copia (iconCopySize).
struct IconDrag {
    let app: AppEntry
    let from: String
    let start: CGPoint
    var location: CGPoint
    let size: CGFloat
}

// La copia è grande quanto le icone della pillola da cui parte: 20 dei suoi 26 (WorkspacePill, AppIconView). La cornice è
// quella disegnata, quindi vale anche dentro il Dock (inDockScale) e coi Dock rimpiccioliti (barFit). Senza cornice (non
// dovrebbe capitare) la grandezza di prima, 20 alla scala della barra (fallback).
func iconCopySize(pill: CGRect?, fallback: CGFloat) -> CGFloat { pill.map { $0.width * 20 / 26 } ?? fallback }

// Su quale pillola cade: quella la cui riga (intervallo verticale, estremi inclusi) contiene il puntatore, purché il
// puntatore sia dentro la larghezza della barra (`thickness`). Nessuna se è la pillola di partenza, se cade tra due
// pillole o fuori dalla barra.
func iconDropTarget(at point: CGPoint, from: String, pills: [String: CGRect], thickness: CGFloat) -> String? {
    guard (0...thickness).contains(point.x) else { return nil }
    let hit = pills.first { $0.value.minY <= point.y && point.y <= $0.value.maxY }?.key
    return hit == from ? nil : hit
}

// Il trascina icone di una barra: ognuna ne tiene uno (@State) e lo passa alle sue pillole spazio
// (hooks), con la larghezza della barra per iconDropTarget. Tutto nello spazio "bar" della barra.
@Observable final class IconDragging {
    // Quanti trascinamenti sono in corso, fra le barre di tutti gli schermi: col nascondi automatico tengono fuori la
    // barra (BarHold). Conta i passaggi fra niente e qualcosa, così la fine di uno non spegne quello di un'altra barra.
    private(set) static var inProgress = 0
    private(set) var drag: IconDrag? {
        didSet { if (oldValue == nil) != (drag == nil) { Self.inProgress += drag == nil ? -1 : 1 } }
    }
    deinit { if drag != nil { Self.inProgress -= 1 } }
    // Le cornici delle pillole spazio. Mai azzerate a onDisappear: nel passaggio allo sfondo unito (e ritorno) la fila
    // vecchia e quella nuova convivono per la transizione con le stesse chiavi, e l'onDisappear della vecchia cancellava le
    // misure della nuova — il primo spazio, che nessuno rimisura, non riceveva più niente (16/10). Lo stesso modello delle
    // cornici dei widget (target in SideBarView): filtrate al momento dell'uso, così uno spazio sparito non cattura rilasci.
    private var pillFrames: [String: CGRect] = [:]

    // Lo stato (la pillola su cui cadrebbe l'icona, bordo bianco; l'icona in mano) e i gesti, per le pillole di una barra.
    func hooks(_ state: BarState, thickness: CGFloat) -> IconDragHooks {
        IconDragHooks(target: drag.flatMap { iconDropTarget(at: $0.location, from: $0.from, pills: livePillFrames(state), thickness: thickness) },
                      dragging: drag?.app.windowID,
                      onDrag: { [self] app, name, start, at in moved(app, from: name, start: start, location: at, fallback: 20 * thickness / 38) },   // thickness / 38: la scala della barra
                      onDrop: { [self] at in dropped(at: at, state, thickness: thickness) },
                      pillFrame: { [self] in pillFrames[$0] = $1 })
    }

    // La finestra si è chiusa o ha lasciato la sua pillola a metà trascinamento: la view del gesto non c'è più, quindi nemmeno la copia.
    func reportsChanged(_ reports: [SpaceReport]) {
        if let d = drag, !reports.contains(where: { $0.workspace.name == d.from && $0.apps.contains { $0.windowID == d.app.windowID } }) { drag = nil }
    }

    private func livePillFrames(_ state: BarState) -> [String: CGRect] { pillFrames.filter { f in state.reports.contains { $0.workspace.name == f.key } } }

    // Il gesto dell'icona parte qui al primo movimento oltre i 4 pt. Con ⌘ premuto è il ⌘-trascina del gruppo: niente.
    // Un gesto di un'altra finestra riparte da capo (la precedente può essere ancora appesa nel ritorno a vuoto). `start` e
    // `location`: il punto di presa e il puntatore del gesto (le prove li danno da sé).
    func moved(_ app: AppEntry, from: String, start: CGPoint, location: CGPoint, fallback: CGFloat) {
        if drag?.app.windowID != app.windowID {
            guard !NSEvent.modifierFlags.contains(.command) else { return }
            drag = IconDrag(app: app, from: from, start: start, location: location,
                            size: iconCopySize(pill: pillFrames[from], fallback: fallback))
        } else {
            drag?.location = location
        }
    }

    // Su un'altra pillola: AeroSpace sposta la finestra (lo spazio la segue se era quella a fuoco) e la barra si aggiorna
    // come dopo ogni azione. Altrove: la copia torna al punto di presa e sparisce.
    func dropped(at location: CGPoint, _ state: BarState, thickness: CGFloat) {
        guard let d = drag else { return }
        if let to = iconDropTarget(at: location, from: d.from, pills: livePillFrames(state), thickness: thickness) {
            drag = nil
            moveWindow(id: d.app.windowID, to: to, follow: d.app.windowID == state.frontWindow)
        } else {
            // Solo se nel frattempo non è partito un altro trascinamento.
            withAnimation(.smooth(duration: 0.2)) { drag?.location = d.start } completion: { [self] in if drag?.location == d.start { drag = nil } }
        }
    }
}

// La copia dell'icona trascinata: sopra tutta la barra (in un overlay in alto a sinistra), non riceve click.
struct IconDragCopy: View {
    let drag: IconDrag?

    var body: some View {
        if let d = drag, let icon = appIcon(d.app) {
            Image(nsImage: icon).resizable().frame(width: d.size, height: d.size)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .position(d.location)
                .allowsHitTesting(false)
        }
    }
}

// Il comando di AeroSpace. `follow`: la finestra era quella a fuoco, lo spazio la segue. `--` prima del nome: uno spazio
// che si chiama "-1" non diventa un'opzione.
func moveWindowArgs(windowID: Int, to workspace: String, follow: Bool) -> [String] {
    ["move-node-to-workspace"] + (follow ? ["--focus-follows-window"] : []) + ["--window-id", String(windowID), "--", workspace]
}
