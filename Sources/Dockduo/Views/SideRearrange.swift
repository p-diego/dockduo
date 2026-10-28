import SwiftUI

// Dove cade un Dock trascinato nella barra di lato (coordinate dall'alto): la zona dal terzo di `barTop...barBottom`, la
// posizione dopo l'ultimo altro Dock della zona con midY sopra il puntatore. Quelli senza frame non contano, come in
// dropTarget. Una barra senza altezza (pannello non ancora piazzato) dà la zona in cima: il terzo di zero farebbe
// Int(NaN).
func sideDropTarget<ID: Hashable>(at p: CGPoint, barTop: CGFloat, barBottom: CGFloat, dragging: ID,
                                  columns: [Zone: [ID]], frames: [ID: CGRect]) -> (zone: Zone, index: Int) {
    let third = barBottom > barTop ? Int(((p.y - barTop) / ((barBottom - barTop) / 3)).rounded(.down)) : 0
    let zone = Zone.allCases[min(max(third, 0), 2)]
    let others = (columns[zone] ?? []).filter { $0 != dragging }
    let before = others.lastIndex { frames[$0].map { $0.midY < p.y } ?? false }
    return (zone, before.map { $0 + 1 } ?? 0)
}

// Il ⌘-trascina di lato in corso (spec dock-contenitori §5: sposta un Dock intero), uno solo: lo fa partire la barra sotto
// il puntatore e lo vede solo la barra del suo schermo (`display`). Punti e cornici nelle coordinate dall'alto di quello
// schermo (SidePlace); le cornici sono quelle di quando è cominciato: chi fa posto non fa ballare l'anteprima.
@Observable final class SideDrag {
    static let shared = SideDrag()
    var current: Current?
    // Il Dock, lo schermo, dove era il puntatore all'inizio e dove è adesso, le cornici dei Dock di allora.
    struct Current { let id: UUID; let display: CGDirectDisplayID; let start: CGPoint; var point: CGPoint; let frames: [UUID: CGRect] }
}
