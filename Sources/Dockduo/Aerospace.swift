import Foundation

// Homebrew su Apple Silicon, altrimenti Intel/manuale: il primo che esiste, altrimenti il default homebrew
// (serve alla CLI di riserva in `aerospace(_:)`, quando la socket non si può usare).
let aerospacePath = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"].first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/aerospace"

func aerospace(_ args: String...) -> String { aerospace(args) }

// stdout del comando, "" se fallisce (es. `--focused` senza finestra a fuoco). Prima la socket, ~2,7 ms; se non si può
// usare, la CLI come prima, ~8,7 ms (misurati il 2026-09-23). Bloccante: mai sul main.
// ponytail: al timeout di `shell` la barra resta vuota per un tick; ignorare i report vuoti se capita davvero
func aerospace(_ args: [String]) -> String {
    if let answer = socketRequest(args) { return answerStdout(answer) ?? "" }
    return shell(aerospacePath, args) ?? ""
}

// Una connessione sempre aperta per tutte le richieste: la usano la coda del Poller, il Calendario e il focus dal Dock,
// quindi un lock. Se si chiude o va in timeout, quella richiesta passa dalla CLI e la prossima la riapre; se non si
// apre (AeroSpace chiusa o precedente alla 0.21), 60 s di sola CLI prima di riprovare, per non pagare ogni volta
// l'attesa.
// ponytail: al timeout la richiesta riparte dalla CLI anche se AeroSpace l'aveva già eseguita dalla socket, quindi
// può girare due volte; oggi va bene perché ogni comando che dockduo manda è idempotente (`workspace`,
// `focus --window-id`, `move-node-to-workspace --window-id`, `layout floating`) — un futuro comando che alterna
// uno stato (es. `fullscreen`, `workspace next`) non deve passare da qui senza un guard contro il doppio invio.
private let socketLock = NSLock()
private var requestConnection: AerospaceConnection?
private var socketRetryAfter = Date.distantPast

private func socketRequest(_ args: [String]) -> Data? {
    socketLock.lock()
    defer { socketLock.unlock() }
    guard Date() >= socketRetryAfter else { return nil }
    if requestConnection == nil {
        requestConnection = AerospaceConnection()
        if requestConnection == nil { socketRetryAfter = Date() + 60; return nil }
    }
    guard let connection = requestConnection, connection.send(requestPayload(args)), let answer = connection.receive() else {
        requestConnection = nil
        return nil
    }
    return answer
}

// Eventi di AeroSpace su una connessione a parte, letti in un ciclo bloccante su un thread dedicato. Da chiamare fuori
// dal main. Tutte e tre le callback girano sul main, in quest'ordine: onStart (iscritti), onEvent (uno per evento),
// onEnd (connessione chiusa, o mai aperta: AeroSpace chiusa o precedente alla 0.21). Appena iscritti AeroSpace manda lo
// stato attuale (focus, spazio, monitor). `mode-changed` no: non cambia la barra.
func subscribeAerospace(onStart: @escaping () -> Void, onEvent: @escaping (AerospaceEvent) -> Void, onEnd: @escaping () -> Void) {
    let events = ["focus-changed", "focused-workspace-changed", "focused-monitor-changed", "window-detected", "binding-triggered"]
    guard let connection = AerospaceConnection(), connection.send(requestPayload(["subscribe"] + events)) else {
        DispatchQueue.main.async(execute: onEnd)
        return
    }
    connection.waitForever()
    DispatchQueue.main.async(execute: onStart)   // prima del thread: sul main onStart arriva sempre prima di onEnd
    Thread {
        while let payload = connection.receive() {
            if let event = parseEvent(payload) { DispatchQueue.main.async { onEvent(event) } }
            else if isRejection(payload) { break }   // subscribe rifiutato: AeroSpace tiene aperta la connessione lo stesso, la chiudiamo noi
        }
        DispatchQueue.main.async(execute: onEnd)
    }.start()
}

func readWorkspaces() -> [Workspace] {
    parseWorkspaces(aerospace("list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"))
}

func readWindows() -> [Window] {
    parseWindows(aerospace("list-windows", "--all", "--format",
        "%{workspace}|%{app-name}|%{window-id}|%{app-pid}|%{app-bundle-id}|%{window-title}"))
}

func focusedWindow() -> Int? {
    Int(aerospace("list-windows", "--focused", "--format", "%{window-id}").trimmingCharacters(in: .whitespacesAndNewlines))
}

// La prima finestra da mettere a fuoco di un'app che si sta mostrando, su qualunque monitor; nil se non ne ha. La usano
// il click sul Dock (Poller) e il click sull'ora (ClockApp), subito dopo che l'app è tornata avanti: le sue finestre
// per AeroSpace sono ancora "di un'app nascosta" per 0,2 s (misurato il 27/9), quindi contano; le minimizzate no.
// Bloccante: fuori dal main.
func firstShowableWindow(bundle: String) -> Int? {
    firstShowableWindow(aerospace("list-windows", "--monitor", "all", "--app-bundle-id", bundle, "--format", "%{window-id}|%{window-layout}"))
}

// Righe `window-id|layout`.
func firstShowableWindow(_ out: String) -> Int? {
    rows(out).lazy.compactMap { f in f.count == 2 && f[1] != "macos_native_minimized" ? Int(f[0]) : nil }.first
}

// Comando fuori dal main thread, poi un refresh: le azioni dell'utente si vedono subito.
func run(_ args: String...) { run(args) }
func run(_ args: [String]) {
    DispatchQueue.global().async {
        _ = aerospace(args)
        DispatchQueue.main.async { poller.tick() }
    }
}

func switchTo(workspace: String) { run("workspace", workspace) }
func focusWindow(id: Int) { run("focus", "--window-id", String(id)) }
// Il rilascio di un'icona su un'altra pillola (IconDrag.swift). Idempotente, come dice il commento sulla socket.
func moveWindow(id: Int, to workspace: String, follow: Bool) { run(moveWindowArgs(windowID: id, to: workspace, follow: follow)) }

// MARK: Socket di AeroSpace (guida, § "Socket protocol", documentata dalla 0.21.0)

let aerospaceSocket = "/tmp/bobko.aerospace-\(NSUserName()).sock"

// Cornice del protocollo: lunghezza UInt32 little-endian, poi il payload JSON.
func frame(_ payload: Data) -> Data {
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Data($0) } + payload
}

// Richiesta come la manda la CLI senza variabili d'ambiente: gli argomenti senza "aerospace", windowId e workspace a
// null esplicito.
func requestPayload(_ args: [String]) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["args": args, "stdin": "", "windowId": NSNull(), "workspace": NSNull()])) ?? Data()
}

// stdout di una risposta riuscita; nil se il comando è fallito (come `shell` con uscita ≠ 0) o il JSON è rotto.
func answerStdout(_ payload: Data) -> String? {
    guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any], json["exitCode"] as? Int == 0 else { return nil }
    return json["stdout"] as? String
}

// Un evento di `subscribe`: il tipo e, per focus-changed e window-detected, l'id della finestra.
struct AerospaceEvent: Equatable {
    let type: String
    let windowId: Int?
}

func parseEvent(_ payload: Data) -> AerospaceEvent? {
    guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
          let type = json["_event"] as? String else { return nil }
    return AerospaceEvent(type: type, windowId: json["windowId"] as? Int)
}

// Vero se `payload` è la risposta di errore a `subscribe` (JSON con `exitCode` ≠ 0): AeroSpace la manda quando
// rifiuta l'iscrizione e tiene la connessione aperta lo stesso, quindi il ciclo di lettura non la scoprirebbe da sé.
func isRejection(_ payload: Data) -> Bool {
    guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return false }
    return (json["exitCode"] as? Int ?? 0) != 0
}

// Una connessione alla socket di AeroSpace, già passata dallo scambio di versione. Socket POSIX bloccanti, timeout di
// 2 s in lettura e scrittura: mai sul main. nil se AeroSpace non c'è o non risponde con la versione 1 (precedente
// alla 0.21, o protocollo nuovo).
final class AerospaceConnection {
    private let fd = socket(AF_UNIX, SOCK_STREAM, 0)

    init?() {
        guard fd >= 0 else { return nil }
        var one: Int32 = 1   // scrivere su una socket chiusa darebbe SIGPIPE, che chiude l'app
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(2)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(aerospaceSocket.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withUnsafeBytes { dst.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, writeAll(withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) }),
              let version = readExactly(4), uint32(version) == 1 else { return nil }
    }

    deinit { close(fd) }

    func send(_ payload: Data) -> Bool { writeAll(frame(payload)) }

    // Una cornice intera (la lettura ricompone i pezzi); nil a fine flusso, errore o timeout.
    func receive() -> Data? {
        guard let header = readExactly(4) else { return nil }
        return readExactly(Int(uint32(header)))
    }

    // Per gli eventi: il flusso può tacere a lungo, niente timeout.
    func waitForever() { setTimeout(0) }

    private func setTimeout(_ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func uint32(_ data: Data) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buf in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, buf.baseAddress! + offset, count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }
}
