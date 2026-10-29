import AppKit
import SwiftUI

// La barra di lato (spec 2026-10-23-siigil-barra-di-lato-design.md e dockduo §3): le regole pure delle cornici, poi i pannelli.

// macOS 27.2: la barra dei menu è del nuovo MenuBarAgent e le sue finestre restano sulla fascia alta anche da nascoste,
// sopra di noi, mangiandosi mouse e click (stesso bug aperto in SketchyBar #852, misurato da Siigil l'1/10). Da lì in poi
// la barra sta un gradino SOPRA di loro (aboveParkedMenuBar), prima sotto la barra dei menu (belowMenuBar).
// ponytail: pezza a una beta, tutta dietro `parkedMenuBar`; se una 27.x rimette le finestre fuori strada, toglierla.
let parkedMenuBar = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 27, minorVersion: 2, patchVersion: 0))

// Il bordo alto della barra, in punti dalla cima dello schermo (spec dockduo §4): dove cominciano le finestre, cioè l'area
// visibile più il margine in alto di AeroSpace su quello schermo, ma mai sopra la striscia della barra dei menu (`strip`):
// lì, anche da nascosta, le sue finestre parcheggiate si mangiano i click.
func barTop(strip: CGFloat, visibleTop: CGFloat, topGap: CGFloat?) -> CGFloat { max(strip, visibleTop + (topGap ?? 0)) }

// Il margine fra la barra e i bordi dello schermo, fisso (spec dock-degli-agenti §5): 2, così la capsula del Dock (45 in una
// barra da 52, mezzo punto verso il bordo: DockBoxView) resta a 5 pt dal bordo, come quella di macOS (2 + 3; autore, 25/10).
let barEdge: CGFloat = 2

// Cornice della barra, in coordinate AppKit: `edge` dal bordo e dal fondo; il bordo alto a `top` dalla cima (barTop).
func sideBarFrame(screen: CGRect, side: Side, width: CGFloat, edge: CGFloat, top: CGFloat) -> CGRect {
    CGRect(x: side == .left ? screen.minX + edge : screen.maxX - edge - width, y: screen.minY + edge,
           width: width, height: screen.height - top - edge)
}

// Il pannello delle etichette (360 pt) sta sul lato interno della barra, alto quanto lei.
func labelPanelFrame(bar: CGRect, side: Side) -> CGRect {
    CGRect(x: side == .left ? bar.maxX : bar.minX - 360, y: bar.minY, width: 360, height: bar.height)
}

// Nascondi automaticamente (spec cartelle §4). I tempi del Dock di macOS: il ritardo prima di comparire e la durata dello
// scorrimento, da `autohide-delay` e `autohide-time-modifier` di com.apple.dock se l'utente li ha cambiati; senza, 0,2 e
// 0,5 s, quelli di macOS (macos-defaults.com, Dock › autohide-delay e autohide-time-modifier, letto il 25/10).
func autohideTiming(_ dock: UserDefaults) -> (delay: TimeInterval, slide: TimeInterval) {
    func seconds(_ key: String, _ fallback: Double) -> TimeInterval { max(0, (dock.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback) }
    return (seconds("autohide-delay", 0.2), seconds("autohide-time-modifier", 0.5))
}

// Un altro schermo tocca quel bordo, anche per un tratto solo (il secondo schermo dell'autore sta a sinistra o a destra
// del Mac): lì la barra non scorre fuori, finirebbe sull'altro schermo.
func edgeIsShared(screen: CGRect, side: Side, screens: [CGRect]) -> Bool {
    screens.contains { other in
        abs(side == .left ? other.maxX - screen.minX : other.minX - screen.maxX) < 1 && other.maxY > screen.minY && other.minY < screen.maxY
    }
}

// Da nascosta: fuori dal bordo esterno del tutto (larghezza più il margine dal bordo); su un bordo condiviso resta al suo
// posto e sfuma.
func hiddenFrame(shown: CGRect, side: Side, shared: Bool, edge: CGFloat) -> CGRect {
    shared ? shown : shown.offsetBy(dx: side == .left ? -(shown.width + edge) : shown.width + edge, dy: 0)
}

// Dov'è il mouse per una barra col nascondi acceso, in coordinate AppKit: sull'ultimo punto del bordo dello schermo
// all'altezza della barra (`edge`: da nascosta la chiama), sulla barra o fra lei e il bordo (`bar`: da fuori la tiene),
// altrove (`away`).
enum MouseSpot { case away, bar, edge }
func mouseSpot(_ m: CGPoint, bar: CGRect, screen: CGRect, side: Side) -> MouseSpot {
    let fromEdge = side == .left ? m.x - screen.minX : screen.maxX - m.x   // 0 sul bordo, cresce verso il centro
    let reach = side == .left ? bar.maxX - screen.minX : screen.maxX - bar.minX
    guard m.y >= bar.minY, m.y <= bar.maxY, fromEdge >= 0, fromEdge <= reach else { return .away }
    return fromEdge <= 1 ? .edge : .bar
}

// Un battito del nascondi automatico: nascosta esce col mouse sul bordo per tutto il ritardo (`since`: da quando c'è;
// passarci sopra non basta), fuori resta finché il mouse è sulla barra o qualcosa la tiene (`held`, BarHold).
func autohideStep(revealed: Bool, spot: MouseSpot, held: Bool, since: TimeInterval?, now: TimeInterval,
                  delay: TimeInterval) -> (revealed: Bool, since: TimeInterval?) {
    if revealed { return (spot != .away || held, nil) }
    guard spot == .edge else { return (false, nil) }
    let start = since ?? now
    return now - start >= delay ? (true, nil) : (false, start)
}

// Regolando larghezza, margine o lato col nascondi acceso la barra esce per far vedere l'effetto e resta fuori fino ad
// `adjustGrace` dopo l'ultimo cambio, come il Dock di macOS col cursore della sua misura (autore, 25/10): fra due passi del
// cursore non rientra. 1 s, non misurato sul Dock vero: servirebbe cambiare la misura del Dock dell'autore.
let adjustGrace: TimeInterval = 1
func stillAdjusting(lastChange: TimeInterval?, now: TimeInterval) -> Bool { lastChange.map { now - $0 < adjustGrace } ?? false }
// Col tasto sinistro ancora giù dopo un cambio si sta ancora regolando (il cursore tenuto fermo, o trascinato piano fra due
// numeri interi): l'attimo riparte da adesso, e la barra rientra 1 s dopo che lasci il tasto.
func keptAdjusting(lastChange: TimeInterval?, now: TimeInterval, buttonDown: Bool) -> TimeInterval? {
    buttonDown && stillAdjusting(lastChange: lastChange, now: now) ? now : lastChange
}

// Col nascondi automatico la barra la tiene fuori, anche col mouse altrove, quello che parte da lei (spec cartelle §4): un
// suo menu aperto (popUpFromBar), il trascinamento di una voce del Dock (DockDrop.source), un'icona verso uno spazio
// (IconDragging) e il ⌘-trascina (SideDrag). Quello che le passa sopra (un trascinamento dal Finder, il nome del Dock) la
// tiene già il puntatore sulla barra: tenerla anche da qui terrebbe fuori quelle degli altri schermi, o tutte per
// un'uscita persa.
@Observable final class BarHold {
    static let shared = BarHold()
    var menuOpen = false
    var dragging = false
    var any: Bool { menuOpen || dragging || SideDrag.shared.current != nil || IconDragging.inProgress > 0 }
}

// Una cornice AppKit (origine in basso a sinistra dello schermo principale) nelle coordinate dall'alto del suo schermo:
// origine nel suo angolo in alto a sinistra, y in giù. Quelle del ⌘-trascina di lato (SideDrag).
func screenTop(_ frame: CGRect, in screen: CGRect) -> CGRect {
    CGRect(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height)
}

// Dove sta una barra di lato, per il ⌘-trascina (SideDrag): lo schermo e il pannello nelle sue coordinate dall'alto. La
// aggiorna move(to:): la rootView non si riassegna (spegne il glass).
@Observable final class SidePlace {
    var display: CGDirectDisplayID = 0
    var bar = CGRect.zero
}

// Si vede la barra (SidePanel la tiene e la mette nell'ambiente): fuori, non coperta e per macOS visibile (non fuori dallo
// schermo, Mac non bloccato). Il traguardo delle sue sfumature, non l'alpha di adesso: mentre compare l'alpha è ancora 0, e
// un giro o un testo partiti lì andrebbero persi. L'anello parte solo se la si vede e i testi degli agenti aspettano lei.
@Observable final class BarVisibility { var visible = false }

extension EnvironmentValues {
    @Entry var barVisibility: BarVisibility? = nil   // nessuna fuori dalla barra (anteprime, icone dei menu): anelli fermi
}

// Una finestra copre la barra se le passa sopra ed è un tutto schermo: larga quanto lo schermo e alta quasi quanto lui
// (stessa tolleranza di coversTheScreen: 44). Il tutto schermo di macOS e l'alt-enter (fullscreen --no-outer-gaps), mai
// una finestra affiancata che ci passa sotto (senza i gaps di lato) né una flottante. Sopra anche in verticale: quella di
// uno schermo impilato sopra o sotto non è di questo schermo (review 3/10).
// Coordinate dall'alto.
func coversTheSide(window: CGRect, bar: CGRect, screenWidth: CGFloat, screenHeight: CGFloat) -> Bool {
    window.intersects(bar) && window.width >= screenWidth - 2 && window.height >= screenHeight - 44
}

// Una barra di lato (§9): un pannello senza cornice che non prende il focus, sta su tutti gli spazi e non si muove con
// Mission Control, dal bordo alto (barTop) fino in fondo, staccato dai bordi di barEdge. Una per schermo, sul lato scelto
// (main.swift); quella dell'altro lato, se è nata, resta spenta. Non si chiude e non si ricrea mai
// (regola del glass): si sposta e si nasconde con l'alpha, anche col nascondi automatico (scorre fuori o sfuma). I testi
// che escono (SideLabels) stanno in un pannello figlio largo 360 verso il centro, che non prende click e segue la barra.
final class SidePanel: NSPanel {
    // Sotto la barra dei menu nativa (24); con la barra dei menu parcheggiata (27.2) sopra le sue finestre (25).
    static let belowMenuBar = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
    static let aboveParkedMenuBar = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    // Il config di AeroSpace per il margine in alto (gapValue): lo rilegge main.swift all'avvio e al cambio di schermi.
    static var aerospaceConfig = ""

    let side: Side
    let labels = SideLabels()
    let place = SidePlace()
    let visibility = BarVisibility()
    private let labelPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

    // Accesa da applyBarSide (main.swift); spenta ha alpha 0 (i click passano) e hideIfCovered la lascia lì.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            if active { hideIfCovered() } else { show(false) }
        }
    }

    // Nascondi automaticamente: `revealed` è la barra fuori (a interruttore spento, sempre). move(to:) fissa la cornice da
    // visibile, il suo schermo e se quel bordo confina con un altro schermo; autohideTick la fa uscire e rientrare.
    var revealed = !Settings.shared.autohide
    private var shown = CGRect.zero, screenFrame = CGRect.zero, shared = false
    private var edgeSince: TimeInterval?
    private var alpha: (bar: CGFloat, text: CGFloat) = (0, 0)   // l'ultimo traguardo, anche a metà di una sfumatura
    static var timing = (delay: 0.2, slide: 0.5)   // i tempi del Dock (autohideTiming), riletti da main.swift
    static let beat: TimeInterval = 0.1   // ogni quanto il battito del nascondi guarda il mouse (main.swift)
    static var adjustedAt: TimeInterval?   // l'ultimo cambio di larghezza, margine o lato col nascondi acceso (stillAdjusting)
    private var slideEnds: TimeInterval = 0   // quando finisce lo scorrimento in corso (slide)
    private var hiding: Bool { Settings.shared.autohide && !revealed }

    init(screen: NSScreen, side: Side, state: BarState) {
        self.side = side
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for p in [self, labelPanel] {
            p.level = parkedMenuBar ? Self.aboveParkedMenuBar : Self.belowMenuBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.canHide = false   // ⌘H "Nascondi dockduo" non deve portarsi via la barra
            p.alphaValue = 0    // nasce spenta (active)
        }
        labelPanel.ignoresMouseEvents = true   // le etichette non prendono mai click (spec §4)
        move(to: screen)
        let bar = NSHostingView(rootView: SideBarView(state: state, side: side, place: place).environment(\.sideLabels, labels)
            .environment(\.barVisibility, visibility))
        bar.sizingOptions = []   // la misura è quella del pannello, anche con una zona che non ci sta
        contentView = bar
        labelPanel.contentView = NSHostingView(rootView: SideLabelsView(labels: labels, opensLeft: side == .right).modifier(SideLook()))
        addChildWindow(labelPanel, ordered: .above)   // compare, sparisce e si sposta con la barra
        // Uscendo dal bordo o col Mac sbloccato macOS la vede dopo: è da lì che si vede (noteVisibility).
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main) { [weak self] _ in
            self?.noteVisibility()
        }
    }

    // Sullo schermo dato, con la larghezza di adesso, dove cominciano le finestre (barTop).
    func move(to screen: NSScreen) {
        let s = Settings.shared
        let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let visibleTop = screen.frame.maxY - screen.visibleFrame.maxY
        let topGap = gapEntry("top", in: Self.aerospaceConfig).flatMap { parseGapValue($0.value) }.flatMap { gapValue($0, on: MonitorFacts(screen)) }
        let top = barTop(strip: max(visibleTop, NSStatusBar.system.thickness), visibleTop: visibleTop, topGap: topGap.map { CGFloat($0) })
        shown = sideBarFrame(screen: screen.frame, side: side, width: s.sideWidth, edge: barEdge, top: top)
        (screenFrame, shared) = (screen.frame, edgeIsShared(screen: screen.frame, side: side, screens: NSScreen.screens.map(\.frame)))
        slide(max(0, slideEnds - ProcessInfo.processInfo.systemUptime))   // uno scorrimento in corso prosegue verso il posto nuovo
        labelPanel.setFrame(labelPanelFrame(bar: frame, side: side), display: true)   // alta quanto la barra: le y delle etichette sono le sue
        place.display = display
        place.bar = screenTop(shown, in: screen.frame)
    }

    // Al suo posto o, nascosta, fuori dallo schermo (hiddenFrame), in `duration` secondi. Anche subito passa dall'animatore
    // di AppKit: un setFrame diretto a metà di uno scorrimento lo vince lo scorrimento (misurato il 25/10) e la barra
    // resterebbe fuori. Il pannello dei testi è figlio: scorre con lei, e alla fine si rimette al suo lato (se la larghezza
    // è cambiata a metà, il figlio segue solo lo spostamento).
    private func slide(_ duration: TimeInterval) {
        let target = hiding ? hiddenFrame(shown: shown, side: side, shared: shared, edge: barEdge) : shown
        slideEnds = ProcessInfo.processInfo.systemUptime + duration
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; animator().setFrame(target, display: true) }) { [self] in
            labelPanel.setFrame(labelPanelFrame(bar: frame, side: side), display: true)
        }
    }

    // Fuori, nei tempi del Dock: regolando la barra col nascondi acceso, e spegnendo il nascondi mentre è nascosta
    // (main.swift). Vero se era nascosta.
    @discardableResult func reveal() -> Bool {
        guard !revealed else { return false }
        setRevealed(true)
        return true
    }

    // Esce o rientra nei tempi del Dock: scorre, o sfuma su un bordo condiviso. Una spenta cambia stato senza muoversi.
    private func setRevealed(_ out: Bool) {
        revealed = out
        if active { slide(Self.timing.slide); show(true, duration: Self.timing.slide) }
    }

    // Un battito del nascondi automatico (main.swift, solo a interruttore acceso): se la barra deve uscire o rientrare,
    // scorre (o sfuma) nei tempi del Dock. In modifica resta fuori (Editing, che entrando la fa uscire). Il ritardo ha mezzo
    // battito in meno: in media il mouse era già sul bordo da mezzo battito quando lo si vede.
    func autohideTick(_ mouse: CGPoint, now: TimeInterval) {
        let spot = mouseSpot(mouse, bar: shown, screen: screenFrame, side: side)
        dropStaleDockName(spot)   // anche da spenta: uno schermo staccato col puntatore su una voce
        guard active else { return }
        let step = autohideStep(revealed: revealed, spot: spot,
                                held: BarHold.shared.any || Editing.shared.on || stillAdjusting(lastChange: Self.adjustedAt, now: now),
                                since: edgeSince,
                                now: now, delay: Self.timing.delay - Self.beat / 2)
        edgeSince = step.since
        if step.revealed != revealed { setRevealed(step.revealed) }
    }

    // Un nome del Dock col mouse lontano dalla barra è rimasto appeso: un'uscita persa (uno stop, uno schermo cambiato sotto
    // il puntatore fermo). Si toglie dalla raccolta. Lo guarda il battito del nascondi e, spento, ogni controllo delle barre
    // (checkSidePanels).
    private func dropStaleDockName(_ spot: MouseSpot) {
        if spot == .away, let name = labels.items[SideLabels.dock] { labels.hide(SideLabels.dock, ifText: name.text) }
    }

    // A schermo intero la barra si fa invisibile, etichette comprese: solo alpha, mai orderOut (regola del glass). Si
    // guarda all'accensione, allo spostamento e in checkSidePanels (main.swift). Col nascondi automatico no: la fa uscire
    // il mouse dal bordo, anche a tutto schermo, e qui si rimette solo l'alpha del suo stato. `windows`: le finestre a
    // schermo (onScreenWindows), lette solo se servono; checkSidePanels ne dà una lettura sola per tutte le barre.
    func hideIfCovered(windows list: @autoclosure () -> [[String: Any]] = onScreenWindows()) {
        dropStaleDockName(mouseSpot(NSEvent.mouseLocation, bar: shown, screen: screenFrame, side: side))
        guard active else { return }   // spenta: ferma
        if Settings.shared.autohide { return show(true) }
        guard let windows = windowsOnOurScreen(list()) else { return }   // nessuno schermo: ferma
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.frame ?? .zero
        let bar = CGRect(origin: CGPoint(x: frame.minX, y: 0), size: frame.size)   // dalla nostra cima, come le finestre
        show(!windows.contains { w, b in
            coversTheSide(window: b, bar: bar, screenWidth: screen.width, screenHeight: screen.height) && isAppWindow(w)
        })
    }

    // Spenta o coperta non si vede niente. Col nascondi automatico, da nascosta il pannello dei testi non mostra niente
    // (nessuna novità la fa uscire) e la barra sparisce solo sul bordo condiviso: su quello esterno è fuori dallo schermo.
    // Dall'animatore come slide(_:).
    private func show(_ visible: Bool, duration: TimeInterval = 0) {
        let new: (bar: CGFloat, text: CGFloat) = (visible && !(hiding && shared) ? 1 : 0, visible && !hiding ? 1 : 0)
        guard new != alpha else { return }
        alpha = new
        noteVisibility()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            animator().alphaValue = new.bar
            labelPanel.animator().alphaValue = new.text
        }
    }

    // Si vede la barra (BarVisibility): i suoi testi sono accesi (fuori e non coperta) e macOS la mostra.
    private func noteVisibility() {
        let visible = alpha.text > 0 && occlusionState.contains(.visible)
        if visibility.visible != visible { visibility.visible = visible }
    }
}

// Le finestre a schermo di tutte le app: una copia della lista del WindowServer, che costa (una per giro, checkSidePanels).
func onScreenWindows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

extension NSWindow {
    // Di quelle finestre (onScreenWindows), quelle che stanno sul nostro schermo (in orizzontale), con la y dalla nostra cima:
    // in coordinate CG (origine in alto a sinistra dello schermo principale) la cima è frame.maxY. nil = nessuno schermo.
    func windowsOnOurScreen(_ list: [[String: Any]]) -> [(info: [String: Any], bounds: CGRect)]? {
        guard let mainMaxY = NSScreen.screens.first?.frame.maxY else { return nil }
        let top = mainMaxY - frame.maxY
        return list.compactMap { w in
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d),
                  b.minX < frame.maxX, b.maxX > frame.minX else { return nil }
            return (w, b.offsetBy(dx: 0, dy: -top))
        }
    }
}

// Una finestra che può coprire una barra: del livello delle app, visibile, e di un'app vera (Dock e ⌘Tab). Le cornici di
// servizio come JankyBorders sporgono nella striscia e sono alte quanto lo schermo, ma sono app .accessory — scambiarle
// per coperture inchiodava la barra.
func isAppWindow(_ w: [String: Any]) -> Bool {
    guard w[kCGWindowLayer as String] as? Int == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1 else { return false }
    let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
    return NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
}
