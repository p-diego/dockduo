import AppKit
import Testing
@testable import Dockduo

private let apps = BarItem.widget(.apps), workspaces = BarItem.widget(.workspaces), nowPlaying = BarItem.widget(.nowPlaying)

@Test func sideBarFrameStartsBelowTheMenuBarStrip() {
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    // Il bordo alto proprio a `top` (dove cominciano le finestre), il fondo al margine: 6 + 1067 = 1107 - 34.
    #expect(sideBarFrame(screen: screen, side: .right, width: 52, edge: 6, top: 34) == CGRect(x: 1652, y: 6, width: 52, height: 1067))
    #expect(sideBarFrame(screen: screen, side: .left, width: 52, edge: 6, top: 24) == CGRect(x: 6, y: 6, width: 52, height: 1077))
    #expect(labelPanelFrame(bar: CGRect(x: 1652, y: 6, width: 52, height: 1061), side: .right) == CGRect(x: 1292, y: 6, width: 360, height: 1061))
}
// La barra comincia dove cominciano le finestre (l'area visibile più il margine in alto di AeroSpace), mai sopra la striscia
// della barra dei menu: schermo del Mac (striscia 33, margine 5) → 38; esterno con la barra dei menu nascosta (striscia 24,
// area visibile da 0, margine 43) → 43; senza margine → la striscia.
@Test func barStartsWhereTheWindowsStartButBelowTheStrip() {
    #expect(barTop(strip: 33, visibleTop: 33, topGap: 5) == 38)
    #expect(barTop(strip: 24, visibleTop: 0, topGap: 43) == 43)
    #expect(barTop(strip: 24, visibleTop: 0, topGap: nil) == 24)
    #expect(barTop(strip: 33, visibleTop: 33, topGap: 0) == 33)
}
// Una finestra a schermo intero in uno spazio nativo (la pillola delle nascoste, System.swift): alta quasi quanto lo schermo
// ED entra nella striscia in alto. Le finestre di AeroSpace partono sotto (y 39) e non contano, il video a schermo intero
// parte sotto il notch (y 33-34).
@Test func aWindowCoversTheScreenOnlyIfTallAndIntoTheTopStrip() {
    #expect(coversTheScreen(top: 34, height: 1073, screenHeight: 1107, barHeight: 38))    // video sotto il notch
    #expect(coversTheScreen(top: 0, height: 1107, screenHeight: 1107, barHeight: 38))     // gioco senza bordi
    #expect(!coversTheScreen(top: 39, height: 1062, screenHeight: 1107, barHeight: 38))   // finestra di AeroSpace: sotto la striscia
    #expect(!coversTheScreen(top: 34, height: 500, screenHeight: 1107, barHeight: 38))    // bassa: non copre
    #expect(!coversTheScreen(top: -1107, height: 1080, screenHeight: 1107, barHeight: 38))  // finestra d'un altro schermo sopra
    #expect(!coversTheScreen(top: 1061, height: 1062, screenHeight: 1107, barHeight: 38))   // d'un altro schermo sotto
}
@Test func coversTheSideOnlyForWindowsOverTheBar() {
    let bar = CGRect(x: 1652, y: 40, width: 52, height: 1061)
    func covers(_ window: CGRect) -> Bool { coversTheSide(window: window, bar: bar, screenWidth: 1710, screenHeight: 1107) }
    #expect(covers(CGRect(x: 0, y: 0, width: 1710, height: 1107)))       // tutto schermo
    #expect(covers(CGRect(x: 0, y: 39, width: 1710, height: 1068)))      // alt-enter, senza gaps
    #expect(!covers(CGRect(x: 5, y: 39, width: 1641, height: 1063)))     // affiancata da AeroSpace
    #expect(!covers(CGRect(x: 1500, y: 300, width: 400, height: 400)))   // piccola, flottante
    #expect(!covers(CGRect(x: 0, y: -1107, width: 1710, height: 1107)))  // schermo impilato sopra
}
// Prima che i gaps di lato siano scritti, le finestre affiancate passano sotto la barra: non è un tutto schermo (misurata
// il 24/10 sullo schermo del Mac: VS Code 1700 × 1063 in 5, 39).
@Test func aTiledWindowWithoutGapsDoesNotHideTheSideBar() {
    #expect(!coversTheSide(window: CGRect(x: 5, y: 39, width: 1700, height: 1063), bar: CGRect(x: 1652, y: 40, width: 52, height: 1061),
                           screenWidth: 1710, screenHeight: 1107))
}
// Una barra sola: la zona dal terzo dell'altezza, l'indice dal midY; il lato dello schermo non conta più.
@Test func dropTargetIsAZoneOfTheOneBar() {
    let cols: [Zone: [BarItem]] = [.top: [nowPlaying, apps]]
    let f = [nowPlaying: CGRect(x: 1660, y: 50, width: 36, height: 40), apps: CGRect(x: 1660, y: 100, width: 36, height: 36)]
    #expect(sideDropTarget(at: CGPoint(x: 1680, y: 95), barTop: 40, barBottom: 1100, dragging: workspaces, columns: cols, frames: f) == (Zone.top, 1))
    #expect(sideDropTarget(at: CGPoint(x: 20, y: 1050), barTop: 40, barBottom: 1100, dragging: nowPlaying, columns: cols, frames: f) == (Zone.bottom, 0))
    #expect(sideDropTarget(at: CGPoint(x: 1680, y: 500), barTop: 40, barBottom: 1100, dragging: nowPlaying, columns: cols, frames: f).zone == .middle)
}
// Una barra senza altezza (pannello non ancora piazzato) non fa Int(NaN): cade in cima.
@Test func dropOnAZeroHeightBarGoesToTheTopZone() {
    #expect(sideDropTarget(at: CGPoint(x: 1680, y: 500), barTop: 40, barBottom: 40, dragging: nowPlaying, columns: [:], frames: [:]) == (Zone.top, 0))
}
// Le cornici AppKit nelle coordinate dall'alto del loro schermo: la barra di destra dello schermo del Mac (come sopra) e
// una su uno schermo esterno a destra, più in alto.
@Test func screenTopFlipsAppKitFrames() {
    #expect(screenTop(CGRect(x: 1652, y: 6, width: 52, height: 1061), in: CGRect(x: 0, y: 0, width: 1710, height: 1107)) == CGRect(x: 1652, y: 40, width: 52, height: 1061))
    #expect(screenTop(CGRect(x: 1716, y: 106, width: 52, height: 1040), in: CGRect(x: 1710, y: 100, width: 1920, height: 1080)) == CGRect(x: 6, y: 34, width: 52, height: 1040))
}
@Test func menuOriginOpensTowardTheCenter() {
    #expect(menuOrigin(in: CGRect(x: 0, y: 0, width: 40, height: 30), menuWidth: 240, opensLeft: true) == NSPoint(x: -248, y: 30))
    #expect(menuOrigin(in: CGRect(x: 0, y: 0, width: 40, height: 30), menuWidth: 240, opensLeft: false) == NSPoint(x: 48, y: 30))
}

// Nascondi automaticamente (spec cartelle §4). Lo schermo del Mac e, a destra, uno esterno più alto: fra i due il bordo è
// condiviso e lì la barra sfuma al suo posto; sul bordo esterno scorre fuori del tutto (larghezza più il margine dal bordo).
@Test func sharedEdgeFadesInsteadOfSliding() {
    let mac = CGRect(x: 0, y: 0, width: 1710, height: 1107), ext = CGRect(x: 1710, y: -200, width: 1920, height: 1080)
    let screens = [mac, ext]
    #expect(edgeIsShared(screen: mac, side: .right, screens: screens) && edgeIsShared(screen: ext, side: .left, screens: screens))
    #expect(!edgeIsShared(screen: mac, side: .left, screens: screens) && !edgeIsShared(screen: ext, side: .right, screens: screens))
    #expect(!edgeIsShared(screen: mac, side: .right, screens: [mac]))
    // Uno schermo sopra, allineato a sinistra, non tocca il bordo di lato.
    #expect(!edgeIsShared(screen: mac, side: .left, screens: [mac, CGRect(x: 0, y: 1107, width: 1920, height: 1080)]))
    let bar = CGRect(x: 1656, y: 2, width: 52, height: 1067)
    #expect(hiddenFrame(shown: bar, side: .right, shared: true, edge: 2) == bar)
    #expect(hiddenFrame(shown: bar, side: .right, shared: false, edge: 2) == CGRect(x: 1710, y: 2, width: 52, height: 1067))
    #expect(hiddenFrame(shown: CGRect(x: 2, y: 2, width: 52, height: 1067), side: .left, shared: false, edge: 2).maxX == 0)
}
// La barra in basso (spec app conclusa §3.2) sullo schermo del Mac, larga 71 di lato: lungo tutto il bordo a 2 dai bordi e
// alta 71 (la cima, `top`, non conta); nascosta scende sotto il bordo del tutto (altezza più il margine); le etichette
// sopra, larghe quanto lei. Corre in orizzontale, quelle di lato in verticale.
@Test func theBottomBarFrames() {
    let mac = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let bar = sideBarFrame(screen: mac, side: .bottom, width: 71, edge: 2, top: 38)
    #expect(bar == CGRect(x: 2, y: 2, width: 1508, height: 71))
    #expect(hiddenFrame(shown: bar, side: .bottom, shared: false, edge: 2) == CGRect(x: 2, y: -71, width: 1508, height: 71))
    #expect(labelPanelFrame(bar: bar, side: .bottom) == CGRect(x: 2, y: 73, width: 1508, height: 360))
    #expect(Side.bottom.axis == .horizontal && Side.left.axis == .vertical && Side.right.axis == .vertical)
}
// Uno schermo messo sotto: il bordo in basso è condiviso e lì la barra sfuma al suo posto; il mouse sull'ultimo punto in
// basso, dentro la lunghezza della barra, la chiama.
@Test func aSharedBottomEdgeFades() {
    let mac = CGRect(x: 0, y: 0, width: 1512, height: 982), below = CGRect(x: -200, y: -1080, width: 1920, height: 1080)
    #expect(edgeIsShared(screen: mac, side: .bottom, screens: [mac, below]))
    #expect(!edgeIsShared(screen: mac, side: .bottom, screens: [mac]))
    // Uno sotto ma tutto a destra (si toccano solo in un angolo) e uno a sinistra: non toccano il bordo in basso.
    #expect(!edgeIsShared(screen: mac, side: .bottom, screens: [mac, CGRect(x: 1512, y: -1080, width: 1920, height: 1080)]))
    #expect(!edgeIsShared(screen: mac, side: .bottom, screens: [mac, CGRect(x: -1920, y: 0, width: 1920, height: 1080)]))
    let bar = CGRect(x: 2, y: 2, width: 1508, height: 71)
    #expect(hiddenFrame(shown: bar, side: .bottom, shared: true, edge: 2) == bar)
    #expect(mouseSpot(CGPoint(x: 700, y: 0), bar: bar, screen: mac, side: .bottom) == .edge)
    #expect(mouseSpot(CGPoint(x: 2, y: 0.5), bar: bar, screen: mac, side: .bottom) == .edge)
    #expect(mouseSpot(CGPoint(x: 700, y: 40), bar: bar, screen: mac, side: .bottom) == .bar)
    #expect(mouseSpot(CGPoint(x: 700, y: 74), bar: bar, screen: mac, side: .bottom) == .away)
    #expect(mouseSpot(CGPoint(x: 1, y: 0), bar: bar, screen: mac, side: .bottom) == .away)     // nell'angolo, oltre la barra
    #expect(mouseSpot(CGPoint(x: 700, y: -1), bar: bar, screen: mac, side: .bottom) == .away)  // sullo schermo sotto
}
// I tempi del Dock di macOS, 0,2 s di attesa e 0,5 s di scorrimento, o quelli che l'utente ha scritto nelle sue
// impostazioni (`defaults write com.apple.dock autohide-delay -float 0`); un valore negativo vale 0.
@Test func autohideTimingFromDockDefaults() {
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    #expect(autohideTiming(d) == (delay: 0.2, slide: 0.5))
    d.set(Float(0), forKey: "autohide-delay"); d.set(Float(0.25), forKey: "autohide-time-modifier")
    #expect(autohideTiming(d) == (delay: 0, slide: 0.25))
    d.set(1, forKey: "autohide-delay"); d.set(-1.0, forKey: "autohide-time-modifier")
    #expect(autohideTiming(d) == (delay: 1, slide: 0))
}
// Dov'è il mouse per la barra a sinistra (da 2 a 54) e a destra dello schermo del Mac: sull'ultimo punto del bordo e
// all'altezza della barra la chiama, fra il bordo e il suo lato interno la tiene fuori, altrove no.
@Test func theMouseCallsTheBarOnlyFromTheEdge() {
    let mac = CGRect(x: 0, y: 0, width: 1710, height: 1107), left = CGRect(x: 2, y: 2, width: 52, height: 1067)
    #expect(mouseSpot(CGPoint(x: 0, y: 500), bar: left, screen: mac, side: .left) == .edge)
    #expect(mouseSpot(CGPoint(x: 1, y: 3), bar: left, screen: mac, side: .left) == .edge)
    #expect(mouseSpot(CGPoint(x: 30, y: 500), bar: left, screen: mac, side: .left) == .bar)
    #expect(mouseSpot(CGPoint(x: 55, y: 500), bar: left, screen: mac, side: .left) == .away)
    #expect(mouseSpot(CGPoint(x: 0, y: 1090), bar: left, screen: mac, side: .left) == .away)   // sopra la barra, nella striscia
    #expect(mouseSpot(CGPoint(x: -1, y: 500), bar: left, screen: mac, side: .left) == .away)   // sullo schermo a sinistra
    let right = CGRect(x: 1656, y: 2, width: 52, height: 1067)
    #expect(mouseSpot(CGPoint(x: 1709, y: 500), bar: right, screen: mac, side: .right) == .edge)
    #expect(mouseSpot(CGPoint(x: 1709.5, y: 500), bar: right, screen: mac, side: .right) == .edge)
    #expect(mouseSpot(CGPoint(x: 1660, y: 500), bar: right, screen: mac, side: .right) == .bar)
    #expect(mouseSpot(CGPoint(x: 1600, y: 500), bar: right, screen: mac, side: .right) == .away)
}
// Nascosta, esce solo col mouse fermo sul bordo per tutto il ritardo (passarci sopra non basta); fuori, resta finché il
// mouse è sulla barra o un menu o un trascinamento partiti da lei la tengono; poi rientra subito.
@Test func theEdgeRevealsAfterTheDelayAndTheBarHoldsIt() {
    func step(_ revealed: Bool, _ spot: MouseSpot, held: Bool = false, since: TimeInterval? = nil, now: TimeInterval) -> (Bool, TimeInterval?) {
        let r = autohideStep(revealed: revealed, spot: spot, held: held, since: since, now: now, delay: 0.2)
        return (r.revealed, r.since)
    }
    #expect(step(false, .edge, now: 0) == (false, 0))               // tocca il bordo: si comincia a contare
    #expect(step(false, .edge, since: 0, now: 0.1) == (false, 0))
    #expect(step(false, .edge, since: 0, now: 0.2) == (true, nil))  // fermo per il ritardo: esce
    #expect(step(false, .away, since: 0, now: 0.1) == (false, nil)) // passato oltre: si ricomincia
    #expect(step(false, .bar, since: 0, now: 0.3) == (false, nil))  // dentro il margine, non sul bordo
    #expect(autohideStep(revealed: false, spot: .edge, held: false, since: nil, now: 5, delay: 0).revealed)
    #expect(step(true, .bar, now: 11) == (true, nil))
    #expect(step(true, .away, held: true, now: 11) == (true, nil))    // un menu aperto la tiene fuori
    #expect(step(true, .away, now: 11) == (false, nil))
}
// Un ⌘-trascina partito dalla barra la tiene fuori anche se il puntatore esce oltre il suo lato interno.
@Test func aDragFromTheBarHoldsItOut() {
    #expect(!BarHold.shared.any)
    SideDrag.shared.current = .init(id: UUID(), display: 1, start: .zero, point: CGPoint(x: 400, y: 300), frames: [:])
    defer { SideDrag.shared.current = nil }
    #expect(BarHold.shared.any)
}
// Col nascondi automatico, regolando larghezza o margine la barra esce e resta fuori un attimo dopo l'ultimo cambio: fra
// due passi del cursore non rientra; passato l'attimo vale di nuovo la regola di sempre (autore, 25/10).
@Test func theBarStaysOutForAMomentAfterAnAdjustment() {
    #expect(!stillAdjusting(lastChange: nil, now: 5))
    #expect(stillAdjusting(lastChange: 5, now: 5))
    #expect(stillAdjusting(lastChange: 5, now: 5.9))
    #expect(!stillAdjusting(lastChange: 5, now: 5 + adjustGrace))
    // Tenuta dal regolare, col mouse altrove resta fuori; dopo rientra.
    #expect(autohideStep(revealed: true, spot: .away, held: stillAdjusting(lastChange: 5, now: 5.5), since: nil, now: 5.5, delay: 0.2).revealed)
    #expect(!autohideStep(revealed: true, spot: .away, held: stillAdjusting(lastChange: 5, now: 6.5), since: nil, now: 6.5, delay: 0.2).revealed)
    // Col tasto giù dopo un cambio (il cursore tenuto fermo) l'attimo riparte; col tasto su, o senza un cambio recente, no.
    #expect(keptAdjusting(lastChange: 5, now: 5.9, buttonDown: true) == 5.9)
    #expect(keptAdjusting(lastChange: 5, now: 5.9, buttonDown: false) == 5)
    #expect(keptAdjusting(lastChange: 5, now: 7, buttonDown: true) == 5)
    #expect(keptAdjusting(lastChange: nil, now: 7, buttonDown: true) == nil)
}
