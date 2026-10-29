import AppKit
import SwiftUI
import IOKit.ps
import SystemConfiguration

// Rimanda `f` di `delay` secondi sul main, annullando il giro precedente: segnali ravvicinati riprogrammano
// l'esecuzione (il rilascio del mouse, i segnali da fuori, il cambio degli schermi in main.swift).
func debounce(_ work: inout DispatchWorkItem?, after delay: TimeInterval, _ f: @escaping () -> Void) {
    work?.cancel()
    let w = DispatchWorkItem(block: f)
    work = w
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
}

// Il clic sul Dock da seguire (Poller.start): nei 120 pt in basso dello schermo che contiene il punto (coordinate di
// AppKit, y in su), su un'app che era davanti al clic e lo è ancora 0,4 s dopo, non dockduo. Un clic sul desktop passa
// al Finder: app diversa, niente. nil = niente da fare.
func dockClickFollows(at p: CGPoint, screens: [CGRect], front: String?, frontLater: String?, me: String?) -> String? {
    guard let screen = screens.first(where: { $0.contains(p) }), (0..<120).contains(p.y - screen.minY),
          let front, front == frontLater, front != me else { return nil }
    return front
}

// AeroSpace sparito o tornato, guardato a ogni giro (spec app conclusa §2.3), anche senza gli eventi: sparito, la barra non ha
// più spazio (.notOpen; "non installato" resta quello); tornato con uno di quei due motivi, lo spazio si rifà (Poller.tick). Gli
// altri motivi sono del file: da aperto li cambia solo un sync.
enum SpaceStep: Equatable { case stay, gone, back }
func spaceStep(alive: Bool, problem: SpaceProblem?) -> SpaceStep {
    let absent = problem == .notOpen || problem == .notInstalled
    return alive ? (absent ? .back : .stay) : (absent ? .stay : .gone)
}

final class Poller {
    let state: BarState
    // Le chiamate ad AeroSpace (socket o CLI) girano qui; lo stato si scrive sul main.
    private let queue = DispatchQueue(label: "dockduo.poll")
    private var inFlight = false
    private var pending = false
    private var wifiEvents: WiFiEvents?
    private var networkStore: SCDynamicStore?
    // Eventi di AeroSpace (Aerospace.swift): con la connessione aperta la barra si aggiorna a ogni evento e il timer fa
    // solo da rete di sicurezza; senza, il timer aggiorna ogni 5 s e riprova a iscriversi.
    private var eventsConnected = false
    private var connecting = false
    private var focusedWindowID: Int?     // dall'ultimo focus-changed; nil = nessuna finestra a fuoco
    private var lastTick = Date.distantPast
    private var mouseUpTick: DispatchWorkItem?
    // Gli ultimi avvisi di SkyLight (WindowEvents.swift): finestra a schermo o no, e quando. Valgono per `settle`.
    private var recent = [Int: (onScreen: Bool, at: Date)]()
    // L'ultima riga di AeroSpace di ogni finestra: serve per quelle che AeroSpace toglie dalla lista (minimizzate).
    private var lastKnown = [Int: Window]()
    private var settleTick: DispatchWorkItem?
    // Il tempo che AeroSpace e l'elenco di macOS impiegano a raggiungere un avviso di macOS: AeroSpace rimette in lista
    // una finestra riaperta 0,9 s dopo, l'elenco di macOS è indietro fino a 0,1 s (misurato il 2026-09-26).
    private let settle: TimeInterval = 1.5
    private var badgeTimer: Timer?   // i numeri rossi del Dock (refreshBadges): vive solo col widget Dock acceso
    private var resolvingDock = false   // cartelle e mensola in corso di risoluzione (refreshDockItems)
    private var resyncing = false   // il sync di AeroSpace tornato (spaceStep) è in corso: uno alla volta, non uno a giro

    init(state: BarState) { self.state = state }

    func start() {
        tick()
        refreshBattery()
        refreshWiFi()
        wifiEvents = WiFiEvents { [weak self] in self?.refreshWiFi() }
        // VPN collegata o scollegata: cambia l'IPv4 di un'interfaccia (State:/Network/Interface/utun9/IPv4). SCDynamicStore,
        // nessun permesso; callback C senza contesto come quella della batteria, passa dal globale `poller`.
        networkStore = SCDynamicStoreCreate(nil, "dockduo" as CFString, { _, _, _ in poller.refreshWiFi() }, nil)
        if let store = networkStore {
            SCDynamicStoreSetNotificationKeys(store, nil, ["State:/Network/Interface/.*/IPv4"] as CFArray)
            CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .commonModes)
        }
        connectEvents()
        // I Timer e la source IOPS li trattiene il run loop; nessuno li invalida mai. Modo .common:
        // continuano anche con un menu aperto. La batteria si rilegge al minuto (la percentuale scende senza notifica IOPS).
        // Rete di sicurezza per AeroSpace: con gli eventi un aggiornamento ogni 60 s, senza ogni 5 s più un nuovo
        // tentativo di iscriversi (così dopo un riavvio di AeroSpace gli eventi ripartono da soli).
        RunLoop.main.add(Timer(timeInterval: 5, repeats: true) { [self] _ in
            if !eventsConnected { connectEvents(); tick() } else if Date().timeIntervalSince(lastTick) >= 60 { tick() }
            refreshDockItems()
        }, forMode: .common)
        // Al minuto anche il Wi-Fi, come rete di sicurezza se gli eventi CoreWLAN si fermano (wifid riavviato, sleep/wake).
        // Allo stesso ritmo, all'avvio e poi al minuto: le quote Claude e ChatGPT (la rete solo per gli account che una
        // sessione può usare su questo Mac, cioè con le sue credenziali, e solo quando è passato l'intervallo delle
        // impostazioni, default 5 min; anche senza sessioni: il menu delle app li mostra ripartiti la volta dopo, spec
        // dock-degli-agenti §3) e l'aggiornamento (Updater.swift; la rete solo quando è dovuto: 24 h dopo un controllo
        // riuscito, 1 h dopo uno fallito).
        func checks() {
            Task { await QuotaCache.shared.refreshIfDue(accounts: Set(Agent.allCases)) }
            Task { await Updater.shared.checkIfDue() }
        }
        checks()
        RunLoop.main.add(Timer(timeInterval: 60, repeats: true) { [self] _ in
            refreshBattery(); refreshWiFi(); checks()
        }, forMode: .common)
        // Callback C senza contesto: raggiunge il Poller tramite il globale `poller` di main.swift.
        if let s = IOPSNotificationCreateRunLoopSource({ _ in poller.refreshBattery() }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        }
        // App lanciate: un aggiornamento subito, la finestra nuova arriva poi con window-detected.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [self] _ in tick() }
        // Risparmio energetico acceso/spento: l'anello della batteria si tinge subito (l'avviso arriva fuori dal main).
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [self] _ in refreshBattery() }
        // Cambio di app in primo piano: le attese di quell'app sono viste (markSeen; clic sul Dock, ⌘-Tab, una sua finestra),
        // e se ne ha l'anello e il testo cambiano subito. Altrimenti solo in ridotto: con AeroSpace il focus arriva dai suoi
        // eventi, e questo avviso faceva sfarfallare (spec M2 §1); senza, il nome e l'app a fuoco aspetterebbero il timer.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] note in
            var sessions = state.sessions
            if let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier {
                markSeen(bundle: bundle, sessions: &sessions)
            }
            let seen = sessions != state.sessions
            if seen { state.sessions = sessions }   // solo se cambia: ogni scrittura avvisa chi la osserva
            if seen || state.reports.first?.workspace.name.isEmpty == true { tick() }
        }
        // App chiuse: AeroSpace se ne accorge dopo il sistema (lo elabora in modo asincrono) e per le finestre chiuse non
        // manda eventi, quindi anche un aggiornamento a cose assestate (refresh).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [self] _ in
            refresh()
        }
        // Pulsante rosso di una finestra non a fuoco: AeroSpace lo scopre al rilascio del mouse e non manda eventi.
        // Rilasci ravvicinati riprogrammano l'aggiornamento. Monitor globale del mouse: nessun permesso.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [self] _ in
            debounce(&mouseUpTick, after: 0.3) { [weak self] in self?.tick() }
        }
        // Click sul Dock sull'app già in primo piano mentre il workspace a fuoco è vuoto (tipico dopo un cambio di space):
        // macOS manda solo un "reopen", nessuna attivazione, e AeroSpace non ha un focus da seguire (riprodotto il
        // 2026-09-20; attivando un'app diversa AeroSpace segue da solo). Monitor globale del mouse: non serve Accessibilità.
        // Quale app seguire lo decide dockClickFollows, 0,4 s dopo, con il punto e l'app davanti del momento del clic.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [self] e in
            let p = e.locationInWindow, front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                if let bundle = dockClickFollows(at: p, screens: NSScreen.screens.map(\.frame), front: front,
                                                 frontLater: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                                 me: Bundle.main.bundleIdentifier) { followActivated(bundle: bundle) }
            }
        }
    }

    // Il workspace a fuoco è vuoto e `bundle` è in primo piano: alla sua prima finestra visibile, ovunque sia.
    private func followActivated(bundle: String) {
        queue.async {
            guard focusedWindow() == nil else { return }   // c'è già una finestra a fuoco qui: ci pensa AeroSpace
            guard let id = firstShowableWindow(bundle: bundle) else { return }
            focusWindow(id: id)
        }
    }

    // Iscrizione agli eventi di AeroSpace, fuori dal main (la connessione è bloccante). `connecting` evita due
    // iscrizioni in parallelo se il timer riprova mentre la prima è ancora in corso. A ogni connessione anche i gap dei lati:
    // se al login la prova (dry-run) è fallita perché AeroSpace non rispondeva ancora, qui si riprova; senza cambi non scrive.
    private func connectEvents() {
        guard !eventsConnected, !connecting else { return }
        connecting = true
        DispatchQueue.global().async { [weak self] in
            subscribeAerospace(
                onStart: { self?.connecting = false; self?.eventsConnected = true
                    MainActor.assumeIsolated { syncAerospaceGaps { self?.state.spaceProblem = $0 } } },
                onEvent: { self?.handle($0) },
                onEnd: { self?.connecting = false; self?.eventsConnected = false })
        }
    }

    private func handle(_ event: AerospaceEvent) {
        if event.type == "focus-changed" { focusedWindowID = event.windowId }
        tick()
    }

    // Un tick in corso assorbe le richieste arrivate nel frattempo in un solo tick successivo.
    func tick() {
        if inFlight { pending = true; return }
        inFlight = true
        let now = Date(), apps = runningApps(), frontmost = NSWorkspace.shared.frontmostApplication
        lastTick = now
        let bundles = Set(apps.compactMap(\.bundleIdentifier))
        state.sessions = state.sessions.filter { !expired($0.value, now: now, front: frontmost?.bundleIdentifier, running: bundles) }
        let sessions = Array(state.sessions.values)   // letto sul main, prima di lasciare il thread
        // Le app del Dock (policy .regular): AppKit, sul main. Servono alle nascoste e, senza AeroSpace, alla pillola ridotta.
        let running = apps
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.localizedName.map { AppEntry(name: $0, pid: a.processIdentifier, windowID: 0, bundle: a.bundleIdentifier ?? "") } }
        let frontApp = frontmost?.processIdentifier
        // Le app del Dock solo da accese: da spente nessun lavoro in più (la loro lista resta vuota).
        let dockOn = Settings.shared.isOn(.apps)
        let launched = dockOn ? Dictionary(apps.compactMap { a in a.launchDate.map { (a.processIdentifier, $0) } }, uniquingKeysWith: { a, _ in a }) : [:]
        // AeroSpace spento: non lo si interroga proprio — niente socket né CLI che falliscono a ogni giro, costavano 1,6% misurato il 3/10.
        let aerospaceAlive = aerospaceRunning()
        // Sparito, la barra si nasconde (barHides); tornato, lo spazio si rifà anche senza gli eventi (prima della 0.21).
        switch spaceStep(alive: aerospaceAlive, problem: state.spaceProblem) {
        case .gone: state.spaceProblem = .notOpen
        case .back where !resyncing:
            resyncing = true
            MainActor.assumeIsolated { syncAerospaceGaps { [self] in state.spaceProblem = $0; resyncing = false } }
        default: break
        }
        // Con gli eventi la finestra a fuoco è già nota (.some(nil) = nessuna); senza, la si chiede ad AeroSpace.
        let focus: Int?? = eventsConnected ? .some(focusedWindowID) : nil
        let settle = settle
        let recent = self.recent.filter { now.timeIntervalSince($0.value.at) < settle }.mapValues(\.onScreen), lastKnown = self.lastKnown
        queue.async { [self] in
            let screen = screenWindows()
            let windows = aerospaceAlive ? readWindows() : []
            let workspaces = aerospaceAlive ? readWorkspaces() : []
            let visible = visibleWindows(windows.filter { screen.normal.contains($0.id) }, offscreen: screen.offscreen, recent: recent,
                                         lastKnown: lastKnown, focusedWorkspace: workspaces.first(where: \.isFocused)?.name)
            // Senza AeroSpace (spazi vuoti: da vivo ne ha sempre almeno uno a fuoco) la barra passa al rapporto
            // ridotto, con quello che macOS ha già dato in questo stesso giro; al primo giro buono torna alle
            // pillole vere (spec senza-aerospace §1).
            let reduced = workspaces.isEmpty
            let reports = reduced ? [reducedReport(running: running, visible: screen.visible, sessions: sessions)]
                                  : report(workspaces: workspaces, windows: visible, sessions: sessions)
            let front = reduced ? frontApp.map { -Int($0) } : (focus ?? focusedWindow())
            DispatchQueue.main.async { [self] in
                remember(windows, offscreen: screen.offscreen)
                let hidden = hiddenApps(running: running, reports: reports, sessions: sessions, fullscreen: screen.fullscreen)
                // Piene le app con un'icona negli spazi, come le vede la barra (stessa regola delle nascoste, avvisi di SkyLight
                // compresi), e quelle a tutto schermo in uno spazio nativo: parcheggiate altrove, piene come tra le nascoste.
                let shown = Set(reports.flatMap { $0.apps.map(\.pid) }).union(screen.fullscreen)
                let dock = dockOn ? dockApps(running: running, launched: launched, visible: shown,
                                             windowed: Set(windows.map(\.pid)), sessions: sessions) : []
                // Un valore uguale a quello di prima non ridisegna niente: @Observable non avvisa (verificato il 27/9).
                withAnimation(.smooth(duration: 0.3)) {
                    state.reports = reports
                    state.hidden = hidden
                    state.dock = dock
                    state.frontWindow = front
                }
                if dockOn, badgeTimer == nil { refreshBadges() }
                inFlight = false
                checkSidePanels()   // un tutto schermo entrato o uscito (main.swift)
                if pending { pending = false; tick() }
            }
        }
    }

    // Cartelle e mensola del Dock, ogni 5 s e solo con una delle due accese: risolte di nuovo fuori dal main (un file nel Cestino
    // o cancellato sparisce, uno che non si raggiunge si nasconde e torna), una risoluzione alla volta se un disco di rete è lento.
    private func refreshDockItems() {
        let s = Settings.shared
        guard s.isOn(.folders) || s.isOn(.shelf), !resolvingDock, !(s.dockFolders.isEmpty && s.dockShelf.isEmpty) else { return }
        resolvingDock = true
        s.resolveDockItemsInBackground { [self] in resolvingDock = false }
    }

    // I numeri rossi delle app del Dock (Badges.swift), ogni 2 s fuori dal main e solo con le app aperte accese: parte al primo
    // tick da acceso (anche quello della prima lettura, firstRead), si ferma da solo al primo giro da spento. La barra si
    // ridisegna solo quando un numero cambia.
    // shortcut: si rilegge ogni 2 s; passare a un avviso di LaunchServices se se ne trova uno
    private func refreshBadges() {
        guard Settings.shared.isOn(.apps) else {
            badgeTimer?.invalidate(); badgeTimer = nil
            state.badges = [:]
            return
        }
        if badgeTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [self] _ in refreshBadges() }
            timer.tolerance = 0.5   // il sistema può accorparlo ad altri risvegli
            RunLoop.main.add(timer, forMode: .common)
            badgeTimer = timer
        }
        let pids = state.dock.map(\.pid)
        DispatchQueue.global(qos: .utility).async { [self] in
            let badges = readBadges(pids)
            DispatchQueue.main.async { [self] in
                guard badges != state.badges, badgeTimer != nil else { return }   // spento nel frattempo: resta vuoto
                withAnimation(.smooth(duration: 0.3)) { state.badges = badges }
            }
        }
    }

    // Un segnale da fuori (app chiusa, avviso di SkyLight): un aggiornamento subito e uno a cose assestate, quando anche
    // AeroSpace e l'elenco di macOS lo hanno raggiunto. Segnali ravvicinati riprogrammano il secondo.
    func refresh() {
        tick()
        debounce(&settleTick, after: settle) { [weak self] in self?.tick() }
    }

    // Un avviso di SkyLight: 816 la finestra esce dallo schermo (⌘M, ⌘H), 815 ci rientra. Solo per le finestre che
    // AeroSpace conosce o conosceva (non menu e popup); vale per `settle` (visibleWindows).
    func windowEvent(id: Int, onScreen: Bool) {
        guard lastKnown[id] != nil else { return }
        recent[id] = (onScreen, Date())
        refresh()
    }

    // Dopo ogni lettura: l'ultima riga di ogni finestra in lista, più quelle fuori lista ma ancora vive (minimizzate:
    // macOS le ha fuori schermo) o appena segnalate. Una finestra chiusa sparisce da macOS e da qui. Poi gli avvisi
    // di SkyLight per tutte.
    private func remember(_ windows: [Window], offscreen: Set<Int>) {
        recent = recent.filter { Date().timeIntervalSince($0.value.at) < settle }
        lastKnown = lastKnown.filter { id, _ in offscreen.contains(id) || recent[id] != nil }
            .merging(windows.map { ($0.id, $0) }) { _, new in new }
        windowEvents.watch(Set(lastKnown.keys))
    }

    // Batteria e Wi‑Fi servono solo allo Stato: da spento non si leggono (e il primo giro da acceso lo chiede chi
    // lo accende).
    func refreshBattery() {
        state.battery = Settings.shared.isOn(.status) ? readBattery() : nil
    }

    // La qualità del segnale arriva spesso (ogni pochi secondi): la barra si ridisegna solo se le tacche cambiano.
    func refreshWiFi() {
        state.wifi = Settings.shared.isOn(.status) ? readWiFi() : nil
    }
}
