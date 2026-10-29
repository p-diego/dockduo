import AppKit
import Foundation
import SwiftUI

// La finestra Benvenuto (spec 2026-09-25-siigil-benvenuto-design.md): lista di controllo al primo avvio, riaperta una
// volta quando un aggiornamento azzera un permesso. Qui le regole pure; il modello, le azioni e la finestra seguono.

// La fotografia (Settings.setupSnapshot) contiene solo le voci che un aggiornamento può rompere, chiave → a posto.
// `regressed`: qualcosa era a posto e ora non lo è. Chiavi nuove o sparite (widget acceso o spento) non contano.
func regressed(previous: [String: Bool], now: [String: Bool]) -> Bool {
    previous.contains { key, wasOK in wasOK && now[key] == false }
}

// Stesso criterio di main.swift per "copia installata": sotto una cartella Applications, di sistema o dell'utente.
func inApplications(_ bundlePath: String) -> Bool { bundlePath.contains("/Applications/") }

// Vero se il bundle gira dal disco immagine del DMG (montato sotto /Volumes) o da una copia tradotta da Gatekeeper
// (Scaricati, prima della quarantena): il Benvenuto deve apparire anche lì, non solo dalla copia installata.
func launchedFromDiskImage(_ bundlePath: String) -> Bool {
    bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
}

// Dove spostare l'app: /Applications se scrivibile (utente amministratore), altrimenti ~/Applications.
func applicationsDestination(applicationsWritable: Bool, home: URL) -> URL {
    (applicationsWritable ? URL(fileURLWithPath: "/Applications") : home.appendingPathComponent("Applications"))
        .appendingPathComponent("dockduo.app")
}

// La fotografia: il permesso TCC dell'elemento di stato acceso (chiave "location", l'unica cosa che può mancargli: il nome
// della rete) e ogni integrazione che esiste (chiave = id, a posto = installata). AeroSpace non c'è: non riapre la finestra.
// La chiave "fda" di quando c'era Concentrazione, rimasta in una fotografia salvata, sparisce alla prossima: una chiave
// sparita non conta (regressed).
func snapshot(noLocation: Bool, hooks: [String: IntegrationStatus], wifiOn: Bool) -> [String: Bool] {
    var s = hooks.filter { !$0.value.isMissing }.mapValues { $0 == .installed }
    if wifiOn { s["location"] = !noLocation }
    return s
}

// MARK: AeroSpace

let aerospaceBundle = "bobko.aerospace"
func aerospaceInstalled() -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: aerospaceBundle) != nil }
func aerospaceRunning() -> Bool { !runningApps(bundle: aerospaceBundle).isEmpty }
let homebrewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
let aerospaceGuideURL = "https://nikitabobko.github.io/AeroSpace/guide#installation"

// Con Homebrew: il Terminale con il cask già in esecuzione (come per Codex). Senza: la guida di AeroSpace.
func installAerospaceInTerminal() {
    guard let brew = homebrewPath else { open(aerospaceGuideURL); return }
    openTerminal(script: "printf '\\nInstalling AeroSpace with Homebrew.\\n\\n'\n'\(brew)' install --cask nikitabobko/tap/aerospace\nprintf '\\nDone. Open AeroSpace from Applications, then come back to dockduo.\\n'\n", name: "aerospace")
}

// "Crea il file di AeroSpace" (spec app conclusa §2.3): senza un file dell'utente AeroSpace usa quello di fabbrica dentro
// l'app, che non si scrive; la sua copia in ~/.aerospace.toml, come dice la guida di AeroSpace, si comporta uguale e lì
// dockduo può fare posto. Mai sopra un file che c'è, nemmeno accanto a ~/.config/aerospace/aerospace.toml: con due file
// AeroSpace non sa quale leggere.
func createAerospaceConfig(app: URL, home: URL) throws {
    guard !FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/aerospace/aerospace.toml").path) else {
        throw CocoaError(.fileWriteFileExists)
    }
    try FileManager.default.copyItem(at: app.appendingPathComponent("Contents/Resources/default-config.toml"),
                                     to: home.appendingPathComponent(".aerospace.toml"))   // se c'è già: errore, non sovrascrive
}

// Il Benvenuto lo offre solo con AeroSpace aperto e senza un file suo; chiuso o assente, la riga offre di aprirlo o installarlo.
func offersAerospaceConfig(_ aerospace: SetupModel.AerospaceState, _ problem: SpaceProblem?) -> Bool {
    aerospace == .running && problem == .noUserConfig
}

// Dal Benvenuto e da Impostazioni ›: fuori dal main la copia, poi AeroSpace rilegge (cerca di nuovo il file dell'utente:
// finora usava quello di fabbrica) e lo spazio per la barra si rifà, così il motivo sparisce.
@MainActor func createAerospaceConfigAndSync() {
    DispatchQueue.global().async {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: aerospaceBundle) {
            do { try createAerospaceConfig(app: app, home: FileManager.default.homeDirectoryForCurrentUser) }
            catch { logger.error("file di AeroSpace non creato: \(error.localizedDescription)") }
            _ = shell(aerospacePath, ["reload-config", "--no-gui"])
        }
        DispatchQueue.main.async { syncAerospaceGaps { BarState.shared.spaceProblem = $0 } }
    }
}

// MARK: Spostamento in Applicazioni

// Questa copia gira dal DMG o da Scaricati: la copia in una cartella Applications, le toglie la quarantena (l'utente ha
// già approvato quest'app una volta: non deve rifarlo per la copia), la lancia come istanza nuova (`open -n`: con lo
// stesso bundle id in esecuzione, `open` da solo attiverebbe questa) ed esce. La copia nuova espelle il DMG all'avvio.
func moveToApplications() throws {
    let fm = FileManager.default
    let dest = applicationsDestination(applicationsWritable: fm.isWritableFile(atPath: "/Applications"), home: fm.homeDirectoryForCurrentUser)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    // ponytail: se la copia sotto fallisce, la copia vecchia è già sparita (l'errore comunque si vede in rosso);
    // copiare con un nome temporaneo e sostituire con `replaceItemAt` se capita davvero.
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }   // una copia vecchia: sostituita
    try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
    _ = shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
    open("-n", dest.path, "--args", "--eject-installer")   // solo la copia nata da uno spostamento espelle il DMG
    NSApp.terminate(nil)
}

// La copia installata, all'avvio: se è nata da "Move to Applications" (passato `--eject-installer`, §5) e il DMG
// dell'installazione è ancora montato, lo espelle qualche secondo dopo, quando la vecchia copia è uscita. Senza quel
// flag non tocca il DMG: altrimenti ogni avvio della copia installata lo espellerebbe, anche quando è già smontato o
// non c'entra niente con questo lancio. Fuori dal main, errori ignorati.
// ponytail: guarda solo /Volumes/dockduo, il nome del volume di make dmg.
func ejectInstallerDiskImage() {
    let volume = "/Volumes/dockduo"
    guard CommandLine.arguments.contains("--eject-installer"),
          inApplications(Bundle.main.bundlePath), FileManager.default.fileExists(atPath: volume + "/dockduo.app") else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { _ = shell("/usr/bin/hdiutil", ["detach", volume], timeout: 15) }
}

// MARK: Modello

// Lo stato delle voci del Benvenuto (spec §1). `refresh()`: i controlli veloci sul main (path, AeroSpace, Posizione),
// quelli bloccanti fuori (i JSON degli hook), risultato sul main; poi la fotografia.
@Observable final class SetupModel {
    static let shared = SetupModel()
    enum AerospaceState { case running, installedNotRunning, notInstalled }

    var isInApplications = true
    var aerospace = AerospaceState.running
    var noLocation = false   // lo Stato non ha la Posizione per il nome della rete
    var hooks: [String: IntegrationStatus] = [:]
    var moveError: String?   // l'errore dell'ultimo "Sposta in Applicazioni"
    var step = 0   // passo corrente della finestra: qui e non in WelcomeView, che viene ricreata a ogni apertura

    func refresh() {
        isInApplications = inApplications(Bundle.main.bundlePath)
        aerospace = aerospaceRunning() ? .running : aerospaceInstalled() ? .installedNotRunning : .notInstalled
        noLocation = locationMissing()
        let s = Settings.shared
        DispatchQueue.global().async {
            let hooks = integrationStatuses()
            DispatchQueue.main.async {
                self.hooks = hooks
                // Solo la copia installata scrive la fotografia: una build di sviluppo o la copia nel DMG condivide
                // lo stesso dominio defaults e non deve sovrascrivere quella della copia vera (§6 delle findings).
                if inApplications(Bundle.main.bundlePath) {
                    s.setupSnapshot = snapshot(noLocation: self.noLocation, hooks: hooks, wifiOn: s.isOn(.status))
                }
            }
        }
    }
}

// Chiamata 2 s dopo l'avvio (main.swift). Dal disco immagine o da una copia tradotta, sotto: si apre subito. Dalla
// copia installata: al primo avvio sempre; poi solo se una voce della fotografia era a posto e ora non lo è. La
// fotografia si riscrive in ogni caso: una regressione apre la finestra una volta, non a ogni avvio. Le build di
// sviluppo non aprono mai niente da sole.
func showSetupIfNeeded() {
    let path = Bundle.main.bundlePath
    // Dal disco immagine o da una copia tradotta: si apre subito, senza leggere né scrivere la fotografia (quella
    // esiste solo per la copia installata, §6). Le build di sviluppo restano zitte, come sempre.
    if launchedFromDiskImage(path) { WelcomeWindow.shared.open(); return }
    guard inApplications(path) else { return }
    let s = Settings.shared
    let noLocation = locationMissing()
    let wifiOn = s.isOn(.status)
    DispatchQueue.global().async {
        let hooks = integrationStatuses()
        let now = snapshot(noLocation: noLocation, hooks: hooks, wifiOn: wifiOn)
        DispatchQueue.main.async {
            let open = !s.setupDone || regressed(previous: s.setupSnapshot, now: now)
            s.setupSnapshot = now
            if open { WelcomeWindow.shared.open() }
        }
    }
}

// MARK: Finestra

// Una sola, mai distrutta (chiudere = nascondere), sempre scura. Misura fissa:
// una finestra ridimensionabile AeroSpace la affianca alle altre, così la lascia fluttuare. Chiuderla segna setupDone.
final class WelcomeWindow: NSWindow, NSWindowDelegate {
    static let shared = WelcomeWindow()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = String(localized: "Welcome to dockduo")   // Mission Control; nella finestra non si vede
        isReleasedWhenClosed = false
        delegate = self
        appearance = NSAppearance(named: .darkAqua)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = NSHostingView(rootView: WelcomeView(model: SetupModel.shared) { [weak self] in self?.close() })
        if !setFrameUsingName("Welcome") { center() }
        setContentSize(NSSize(width: 520, height: 520))   // l'autosave ricorda anche la misura: la posizione sì, la misura no
        setFrameAutosaveName("Welcome")
    }

    func open() {
        SetupModel.shared.step = 0   // riapertura da Impostazioni › Configurazione iniziale: sempre dal passo 1, non da dove l'ha lasciata l'ultima
        SetupModel.shared.refresh()
        Activation.opened(self)
    }

    // La finestra torna in primo piano dopo un permesso concesso altrove: rilegge le voci (spec §3).
    func windowDidBecomeKey(_ notification: Notification) { SetupModel.shared.refresh() }

    func windowWillClose(_ notification: Notification) {
        // Solo la copia installata: chiudere la finestra nella copia del DMG non deve far sparire il primo avvio
        // della copia vera in Applicazioni.
        if inApplications(Bundle.main.bundlePath) { Settings.shared.setupDone = true }
        Activation.closed()
    }
}
