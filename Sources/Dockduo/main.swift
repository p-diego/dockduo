import AppKit
import ServiceManagement

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()   // riaprire dockduo entra in modifica, uscire rimette AeroSpace; NSApp tiene il delegate debole
app.delegate = appDelegate

// Il primo avvio della copia installata (in una cartella Applications, non la build di sviluppo): avvio al login
// (registrazione idempotente; mai se l'utente ha già scelto dalle Impostazioni, anche "spento"). La barra dei menu e lo
// snap delle finestre di macOS non si toccano: li gestisce Siigil per la sua barra (spec dockduo §3).
if inApplications(Bundle.main.bundlePath), UserDefaults.standard.object(forKey: "dockduo.launchAtLogin") == nil {
    try? SMAppService.mainApp.register()
}

let state = BarState()
allowCursorInBackground()   // il cursore a frecce sopra la linea del Dock (DockLineMenuView)
DockDrop.shared.watchDrags()   // il velo della barra durante i trascinamenti (DockDrop.dragAround)
let poller = Poller(state: state)
let agents = AgentServer(state: state) { poller.tick() }
// La galleria delle sezioni (GalleryPanel): una sola, davanti e trasparente finché non serve, mai chiusa (regola del vetro).
MainActor.assumeIsolated {
    let gallery = GalleryPanel(editing: .shared, state: state)
    gallery.orderFrontRegardless()
    Editing.shared.gallery = gallery
}

// Per schermo una barra sul lato scelto (il menu della linea). Ogni lato nasce la prima volta che serve, poi si sposta soltanto. I
// pannelli non si chiudono mai: chiudere o nascondere un pannello più vecchio spegne la pressione del glass interattivo in
// quelli creati dopo (misurato su macOS 27.0, vedi ANALISI.md). Quello di uno schermo sparito o dell'altro lato resta
// com'è, solo spento (alpha 0, applyBarSide).
var sidePanels: [[Side: SidePanel]] = []
func showPanels() {
    updateAutohide()   // prima: a interruttore spento le barre tornano fuori (revealed) prima di rimettersi a posto
    let side = Settings.shared.barSide
    for (i, screen) in NSScreen.screens.enumerated() {
        if i == sidePanels.count { sidePanels.append([:]) }
        if sidePanels[i][side] == nil { sidePanels[i][side] = SidePanel(screen: screen, side: side, state: state) }
        for p in sidePanels[i].values { p.move(to: screen); p.orderFrontRegardless(); p.hideIfCovered() }
    }
    applyBarSide()
}

// Si vede la barra del lato scelto, sugli schermi che ci sono; le altre restano spente (alpha), mai orderOut.
func applyBarSide() {
    let side = Settings.shared.barSide, live = NSScreen.screens.count
    for (i, pair) in sidePanels.enumerated() { pair.values.forEach { $0.active = i < live && $0.side == side } }
}

// Nascondi automaticamente (spec cartelle §4): a interruttore acceso un battito leggero ogni 0,1 s guarda dov'è il mouse
// (SidePanel.beat, autohideTick); niente monitor degli eventi, che in Siigil rendevano a scatti i menu. Misurato il 25/10 con un
// programma di prova: 0,13% di CPU (una lettura del mouse costa 7 µs, quella dei tasti 3 µs). Spento, il battito non c'è e le barre sono fuori.
// I tempi del Dock si rileggono a ogni showPanels. Modo .common: batte anche mentre si trascina un file verso il bordo.
var autohideTimer: Timer?
func updateAutohide() {
    guard Settings.shared.autohide else {
        autohideTimer?.invalidate(); autohideTimer = nil
        // Le nascoste rientrano scorrendo (autore, 25/10); riaccendendo l'interruttore scorrono via, animate. Il controllo
        // del tutto schermo di showPanels le vede a metà strada: si rifà a scorrimento finito.
        if sidePanels.flatMap(\.values).map({ $0.reveal() }).contains(true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + SidePanel.timing.slide) { checkSidePanels() }
        }
        return
    }
    if let dock = UserDefaults(suiteName: "com.apple.dock") { SidePanel.timing = autohideTiming(dock) }
    guard autohideTimer == nil else { return }
    let timer = Timer(timeInterval: SidePanel.beat, repeats: true) { _ in
        let mouse = NSEvent.mouseLocation, now = ProcessInfo.processInfo.systemUptime
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        SidePanel.adjustedAt = keptAdjusting(lastChange: SidePanel.adjustedAt, now: now, buttonDown: buttonDown)
        sidePanels.flatMap(\.values).forEach { $0.autohideTick(mouse, now: now) }
    }
    timer.tolerance = 0.02
    RunLoop.main.add(timer, forMode: .common)
    autohideTimer = timer
}

// Il margine in alto di AeroSpace per ogni schermo (SidePanel.move, barTop): il config si rilegge all'avvio e quando gli
// schermi cambiano, fuori dal main; le barre si rimettono a posto solo se è cambiato.
func readTopGap() {
    readAerospaceConfig { text in
        guard text != SidePanel.aerospaceConfig else { return }
        SidePanel.aerospaceConfig = text
        showPanels()
    }
}

// `act` sul main a ogni cambio vero di quel che legge `read` (impostazioni @Observable). withObservationTracking avvisa
// una volta sola, e prima del cambio: si riarma e si rilegge dopo.
func whenChanged<T: Equatable>(_ read: @escaping () -> T, _ act: @escaping () -> Void) {
    var last = read()
    func arm() {
        withObservationTracking { _ = read() } onChange: {
            DispatchQueue.main.async {
                let now = read()
                if now != last { last = now; act() }
                arm()
            }
        }
    }
    arm()
}
// Le barre si fanno invisibili a schermo intero, e ricompaiono: si guarda al cambio di spazio di macOS e a ogni giro della
// barra (Poller.tick: eventi di AeroSpace — spazio, fuoco, alt-enter, finestre nuove —, app chiuse, azioni dalla barra).
// Subito e, a cose assestate, ancora dopo 0,8 s: la lista delle finestre può arrivare in ritardo. La lista si copia una
// volta per giro, per tutte le barre, e solo se una guarda (le spente e col nascondi automatico no).
var sideCheck: DispatchWorkItem?
func checkSidePanels() {
    let check = {
        lazy var windows = onScreenWindows()
        sidePanels.flatMap(\.values).forEach { $0.hideIfCovered(windows: windows) }
    }
    check()
    debounce(&sideCheck, after: 0.8, check)
}
Settings.shared.resolveDockItemsInBackground()   // cartelle e mensola del Dock, risolte fuori dal main
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
    checkSidePanels()
}
// Cambiare lato, larghezza o il nascondi automatico: le barre si spostano e si accendono o si spengono subito;
// AeroSpace segue mezzo secondo dopo l'ultimo cambio (i margini delle sue finestre ai lati si riscrivono). Il nascondi
// riscrive lo spazio solo qui, all'interruttore, mai a ogni comparsa della barra. Col nascondi acceso, cambiare lato
// o larghezza fa uscire la barra per vederla (adjustGrace); dopo che si è rimessa a posto, così scorre già lì.
var gapsSync: DispatchWorkItem?
func barShape() -> [AnyHashable] { let s = Settings.shared; return [s.barSide, s.sideWidth] }
var lastBarShape = barShape()
whenChanged({ barShape() + [Settings.shared.autohide] }) {
    let adjusted = barShape() != lastBarShape
    lastBarShape = barShape()
    showPanels()
    if adjusted, Settings.shared.autohide {
        SidePanel.adjustedAt = ProcessInfo.processInfo.systemUptime
        sidePanels.flatMap(\.values).filter(\.active).forEach { $0.reveal() }
    }
    debounce(&gapsSync, after: 0.5) { MainActor.assumeIsolated { syncAerospaceGaps() } }
}
// La prima lettura parte subito, con la richiesta del suo permesso: Automazione per In riproduzione. Lo Stato anche appena
// spento: il Poller legge batteria e Wi‑Fi solo con lo Stato acceso, quindi si svuotano.
@MainActor func firstRead(_ w: WidgetID) {
    if w == .nowPlaying { NowPlaying.readNow() }
    if w == .apps { poller.tick() }   // le app subito, e con loro parte la lettura dei numeri rossi
    if w == .status { poller.refreshBattery(); poller.refreshWiFi() }
}
// Le prime letture seguono le sezioni accese, da qualunque parte si accendano (galleria, trascinamenti): una
// regola sola, chi accende non ci pensa (sectionsToRead, firstRead).
func sectionsOn() -> Set<BarItem> { Set(Settings.shared.docks.flatMap(\.sections)) }
var lastSectionsOn = sectionsOn()
whenChanged(sectionsOn) {
    let now = sectionsOn()
    for case .widget(let w) in sectionsToRead(old: lastSectionsOn, new: now) { MainActor.assumeIsolated { firstRead(w) } }
    lastSectionsOn = now
}
// La notifica arriva a raffica (3-5 volte per dock/undock/risveglio): un solo rebuild dopo 0,3 s.
var rebuild: DispatchWorkItem?
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in
    debounce(&rebuild, after: 0.3) { showPanels(); readTopGap() }
}

MainActor.assumeIsolated { NowPlaying.start() }   // "In riproduzione": gli annunci di Spotify e Music (NowPlaying.swift)
poller.start()
readTopGap()   // prima in coda sulla coda dei gap: la barra nasce già al posto giusto
MainActor.assumeIsolated { syncAerospaceGaps() }   // a ogni avvio: dopo un'uscita forzata riallinea i lati senza risalvare
// Benvenuto (spec 2026-09-25): al primo avvio della copia installata, e dopo un aggiornamento se un permesso è sparito
// (dal disco immagine o da una copia tradotta si apre subito, non da qui: showSetupIfNeeded). Da un Timer, come
// l'avviso di prima: tiene i 2 s di attesa a barra già visibile e gira fuori da un blocco GCD.
// Il CLLocationManager nasce qui, non al controllo: appena creato dice "mai chiesta" finché macOS non risponde (meno di
// 1 s), e il Benvenuto la contava come permesso perso a ogni avvio (misurato il 2026-09-26).
_ = locationManager
Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in showSetupIfNeeded() }
ejectInstallerDiskImage()   // dopo "Move to Applications": il DMG dell'installazione non resta montato
agents.start()
showPanels()
app.run()
