import Foundation

// Notifiche private di SkyLight, le stesse che usa SketchyBar: 816 quando una finestra esce dallo schermo (fine
// dell'animazione di ⌘M, app nascosta), 815 quando ci rientra (riapertura dal Dock). Per il minimizzare AeroSpace non
// manda eventi e aggiorna la sua lista dopo: 0,18 s all'uscita, 0,85 s alla riapertura (misurato il 2026-09-26).
// API non documentate, scelte dall'autore il 26/9 al posto di un secondo aggiornamento ritardato: si caricano a
// runtime e, se un simbolo manca (macOS cambiato), non si fa niente e la barra resta com'era, con la sola AeroSpace.
// Arrivano solo a un'app vera (NSApplication), non a un programma nudo: `app` esiste già quando si passa di qui.
final class WindowEvents {
    private typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias Request = @convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Int32
    private var request: Request?
    private var cid: Int32 = 0
    private var watched = Set<Int>()

    init() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(sky, name).map { unsafeBitCast($0, to: T.self) } }
        guard let connection = sym("SLSMainConnectionID", (@convention(c) () -> Int32).self),
              let register = sym("SLSRegisterConnectionNotifyProc", (@convention(c) (Int32, Handler, UInt32, UnsafeMutableRawPointer?) -> Int32).self),
              let request = sym("SLSRequestNotificationsForWindows", Request.self)
        else { logger.error("SkyLight: simboli mancanti, niente eventi delle finestre"); return }
        cid = connection()
        // Callback C senza contesto: raggiunge il Poller tramite il globale `poller`, come la batteria.
        let handler: Handler = { type, data, length, _ in
            guard let data, length >= 4 else { return }
            let id = Int(data.load(as: UInt32.self))
            DispatchQueue.main.async { poller.windowEvent(id: id, onScreen: type == 815) }
        }
        _ = register(cid, handler, 815, nil)
        _ = register(cid, handler, 816, nil)
        self.request = request
    }

    // Le notifiche arrivano solo per le finestre chieste: tutte quelle note, comprese le minimizzate, che AeroSpace
    // toglie dalla lista ma che devono avvisare quando si riaprono. Si richiede solo se l'insieme cambia.
    func watch(_ ids: Set<Int>) {
        guard let request, ids != watched else { return }
        watched = ids
        let list = ids.map { UInt32($0) }
        _ = request(cid, list, Int32(list.count))
    }
}

let windowEvents = WindowEvents()


// Il permesso di cambiare il cursore da dietro (SkyLight, privato): dockduo non è mai l'app davanti, e senza questo macOS
// ignora il cursore a frecce sopra la linea del Dock. Una volta, all'avvio; senza il simbolo resta la freccia di sempre.
func allowCursorInBackground() {
    let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    typealias Main = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let main = dlsym(sky, "SLSMainConnectionID").map({ unsafeBitCast($0, to: Main.self) }),
          let set = dlsym(sky, "SLSSetConnectionProperty").map({ unsafeBitCast($0, to: SetProperty.self) }) else { return }
    let cid = main()
    _ = set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}
