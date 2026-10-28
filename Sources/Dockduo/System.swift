import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import os

// Errori nel log unificato (Console.app, o `/usr/bin/log stream --predicate 'subsystem == "com.dockduo.app"'`): l'app installata
// parte da LaunchServices con stdout e stderr su /dev/null (lsof, 2026-09-25), quindi `fputs` non arrivava a nessuno.
let logger = Logger(subsystem: "com.dockduo.app", category: "dockduo")

// Una CLI: stdout se esce con 0, nil se non parte o fallisce (stderr scartato). Bloccante: non sul main.
// Una CLI bloccata congelerebbe chi la aspetta per sempre (la barra, con AeroSpace): dopo `timeout` s viene uccisa.
func shell(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { logger.error("\(path, privacy: .public): \(String(describing: error), privacy: .public)"); return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate(); logger.error("\(path, privacy: .public): timeout \(args.joined(separator: " "), privacy: .public)") }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

// Le app aperte davvero: tutte, o quelle di un bundle. Su macOS 27 un'app uscita con processi ancora in background resta
// registrata ("exited-with-subordinates" in lsappinfo, pallino grigio nel Dock) e, quando un'altra app si apre o esce,
// rientra per un momento nell'elenco come un'app del Dock qualunque, col pid del processo già finito (riprodotto il
// 2026-09-27): si scarta chi non ha più il processo.
func runningApps(bundle: String? = nil) -> [NSRunningApplication] {
    let apps = bundle.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? NSWorkspace.shared.runningApplications
    return apps.filter { processAlive($0.processIdentifier) }
}

// Segnale 0: niente di inviato, solo il controllo. EPERM = esiste ma è di un altro utente (root).
func processAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

// `open` di macOS, senza aspettarlo: NSWorkspace.openApplication da un'app mai attiva lancia senza finestra, `open` no.
func open(_ args: String...) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = args
    try? p.run()
}

// Quello che il Finder dice di un file (icona, nome), chiesto fuori dal thread principale: per un disco di rete bloccato
// resta vuoto il posto, non la barra né le Impostazioni.
func offMain<T>(_ read: @escaping () -> T) async -> T {
    await withCheckedContinuation { done in DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: read()) } }
}

// Icona e nome di un file come nel Finder (Download, Scrivania): per le voci del Dock e per la loro lista in Impostazioni.
func finderIconAndName(_ url: URL) async -> (icon: NSImage, name: String) {
    await offMain { (NSWorkspace.shared.icon(forFile: url.path), FileManager.default.displayName(atPath: url.path)) }
}

// Per il menu della batteria (autore, 4/10): i watt dell'alimentatore quando è collegato, altrimenti nil.
func adapterWatts() -> Int? {
    (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? Int
}

func readBattery() -> Battery? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    guard let src = list.first,
          let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any]
    else { return nil }
    return Battery(percent: min(max(d[kIOPSCurrentCapacityKey] as? Int ?? 0, 0), 100),
                   // Fulmine quando è attaccato alla corrente, come la menu bar: la ricarica ottimizzata
                   // ferma la carica all'80% e kIOPSIsChargingKey diventa false.
                   charging: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                   lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
}

// Id delle finestre da mostrare. AeroSpace elenca anche palette e pannelli flottanti (layer > 0 del window server,
// es. Affinity): con il documento ridotto a icona resterebbe un'icona in barra per un pannello invisibile. Si tengono
// le finestre a layer 0 e, per i processi che non ne hanno nessuna (quick terminal di Ghostty, hotkey window di
// iTerm, player sempre in primo piano), anche quelle a layer > 0: lì la finestra flottante è l'app.
// Nella stessa lettura, quali di queste sono fuori schermo per macOS: minimizzate o di un'app nascosta. Quelle degli
// altri spazi di AeroSpace no: AeroSpace le sposta in un angolo, ma restano a schermo (misurato il 2026-09-26).
// Una finestra in uno spazio nativo a schermo intero è fuori schermo allo stesso modo, e ci sta: non è più nel suo
// workspace, da dove sei non la vedi, quindi l'app va nella pillola delle nascoste e da lì un click la raggiunge —
// ma piena, non attenuata: è parcheggiata, non minimizzata (deciso con l'autore il 3/10, su 27.2). La si riconosce
// dalla taglia: fuori schermo ma grande quanto il suo schermo (coversTheScreen).
// Schermi da CoreGraphics, non da NSScreen: screenWindows gira sulla coda del Poller e NSScreen vuole il main
// thread (review 3/10); i bounds CG sono già con l'origine in alto a sinistra, senza conversioni.
// Una finestra copre lo schermo (video o gioco a schermo intero): alta quasi quanto lui E parte dentro la striscia in alto
// (`barHeight`) — dentro, non sopra: una finestra alta di uno schermo impilato sopra ha top molto negativo e non è di
// questo schermo (review 3/10). Le finestre di AeroSpace partono sotto (y 39, il margine alto di Siigil) e non contano; il
// video a schermo intero parte sotto il notch (y 33-34). Coordinate dall'alto, riferite allo schermo.
func coversTheScreen(top: CGFloat, height: CGFloat, screenHeight: CGFloat, barHeight: CGFloat) -> Bool {
    (0..<barHeight).contains(top) && height >= screenHeight - 44
}

private func fullscreenSized(_ b: CGRect) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
    CGGetActiveDisplayList(8, &ids, &n)
    return ids.prefix(Int(n)).map(CGDisplayBounds).contains { s in
        b.minX < s.maxX && b.maxX > s.minX &&
            coversTheScreen(top: b.minY - s.minY, height: b.height, screenHeight: s.height, barHeight: 38)   // la striscia di Siigil
    }
}

func screenWindows() -> (normal: Set<Int>, offscreen: Set<Int>, fullscreen: Set<pid_t>, visible: Set<pid_t>) {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { w -> (id: Int, pid: pid_t, layer: Int, onScreen: Bool, bounds: CGRect?)? in
            guard let id = w[kCGWindowNumber as String] as? Int, let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let layer = w[kCGWindowLayer as String] as? Int else { return nil }
            return (id, pid_t(pid), layer, w[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    (w[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:)))
        }
    let withNormal = Set(list.filter { $0.layer == 0 }.map(\.pid))
    let normal = list.filter { $0.layer == 0 || !withNormal.contains($0.pid) }
    let parked = normal.filter { !$0.onScreen && ($0.bounds.map(fullscreenSized) ?? false) }
    // `visible`: i pid con almeno una finestra normale a schermo — la pillola ridotta senza AeroSpace (Model.swift).
    return (Set(normal.map(\.id)), Set(normal.filter { !$0.onScreen }.map(\.id)), Set(parked.map(\.pid)),
            Set(normal.filter { $0.onScreen && $0.layer == 0 }.map(\.pid)))
}
