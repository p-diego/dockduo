import Foundation

// La barra di lato (spec 2026-10-23-siigil-barra-di-lato-design.md e dockduo §3): una sola, a sinistra o a destra, con
// tre zone. Il modello sta qui, senza viste.
enum Zone: String, CaseIterable, Codable { case top, middle, bottom }

// Dove comincia (dall'alto) la zona di mezzo e quella in fondo, in una barra alta `bar` con la cima a 0: il mezzo al
// centro se ci sta fra le altre due, se no subito sotto la cima o subito sopra il fondo, sempre a `gap` dalle vicine.
// shortcut: se le tre insieme non ci stanno, si impilano dall'alto e il fondo esce sotto la barra; se capita davvero,
// pillole più strette o scorrimento.
func sideZoneTops(bar: CGFloat, top: CGFloat, middle: CGFloat, bottom: CGFloat, gap: CGFloat) -> (middle: CGFloat, bottom: CGFloat) {
    let mid = max(top + gap, min((bar - middle) / 2, bar - bottom - gap - middle))
    return (mid, max(bar - bottom, mid + middle + gap))
}

// La scala di tutti i Dock insieme (spec dock-contenitori §5): 1 se la barra li tiene, se no quella che porta `natural`
// (l'altezza di tutte le zone e dei loro distacchi a scala 1) dentro `bar`, mai sotto 0. Al millesimo per difetto: misure
// rilette a ogni disegno non la fanno ricalcolare per niente, e non sborda mai.
func barFit(bar: CGFloat, natural: CGFloat) -> CGFloat {
    natural <= bar ? 1 : max(0, (bar / natural * 1000).rounded(.down) / 1000)
}
