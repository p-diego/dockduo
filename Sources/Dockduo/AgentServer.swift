import AppKit
import Network
import os

// Messaggio di `dockduo-hook` (spec agenti §1): {"agent","state","bundle","pid","payload":{"session_id","cwd",…}}; `pid` è
// chi chiama il hook: l'agente, o una shell di passaggio fra i due (agentPid).
// `end` non è uno stato: torna (id, nil) e la sessione va rimossa. nil = messaggio da scartare.
// `idle`: la notifica di Claude "fermo da un minuto" (`notification_type` idle_prompt) torna come un end, e apply la usa solo
// per chiudere un turno ancora al lavoro (ruling #5, 27/10); un turno finito resta finito (spec dock-degli-agenti §1, "Ti
// aspetta" solo quando l'agente chiede davvero).
private let agentStates: [String: AgentState] = ["working": .working, "waiting": .waiting, "done": .done]

func parseAgentMessage(_ data: Data, now: Date = Date()) -> (id: String, session: AgentSession?, pid: pid_t?, idle: Bool)? {
    guard let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = m["payload"] as? [String: Any],
          let id = payload["session_id"] as? String, !id.isEmpty,
          let state = m["state"] as? String else { return nil }
    let pid = (m["pid"] as? Int).flatMap { pid_t(exactly: $0) }   // fuori da Int32 pid_t($0) farebbe crashare
    let idle = payload["notification_type"] as? String == "idle_prompt"
    if state == "end" || idle { return (id, nil, pid, idle) }
    guard let s = agentStates[state] else { return nil }
    let bundle = (m["bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let agent: Agent = m["agent"] as? String == "codex" ? .codex : .claude   // assente o sconosciuto: il default dello script
    return (id, AgentSession(id: id, agent: agent, state: s, cwd: payload["cwd"] as? String ?? "", bundle: bundle,
                             since: now, updatedAt: now), pid, false)
}

// Il processo responsabile, come i gruppi di Monitoraggio Attività: funzione privata, caricata una volta; se un macOS
// futuro la toglie, nil.
private typealias Responsible = @convention(c) (pid_t) -> pid_t
private let responsible: Responsible? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: Responsible.self) }

func responsiblePid(_ pid: pid_t) -> pid_t? { responsible.map { $0(pid) } }

// Il processo dell'agente: il $PPID del hook può essere uno `sh -c` di passaggio, quindi si sale al primo antenato che non è
// una shell. nil se restano solo shell fino a launchd o il processo non c'è più. `lookup` = genitore e nome (i test ne danno uno).
private let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu"]

func agentPid(_ pid: pid_t, lookup: (pid_t) -> (ppid: pid_t, name: String)? = parentAndName) -> pid_t? {
    var p = pid
    while p > 1, let info = lookup(p) {
        if !shells.contains(info.name) { return p }
        p = info.ppid
    }
    return nil
}

// Genitore e nome di un processo dal kernel (sysctl KERN_PROC_PID): niente `ps` da lanciare sul main. nil se non c'è.
func parentAndName(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }   // pid assente: 0 byte, non un errore
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return (info.kp_eproc.e_ppid, name)
}

// L'app di un agente che non la dice da sé: il hook manda $__CFBundleIdentifier, che manca a chi gira in un servizio di
// sfondo avviato da launchd, come i bot di Gravity nel suo in.mikolajczuk.gravityd (autore, 12/10). È l'app che macOS
// ritiene responsabile del processo, o, se il responsabile è un servizio, l'app aperta il cui identificativo è l'inizio
// della sua etichetta.
func hostBundle(pid: pid_t) -> String? {
    guard let r = responsiblePid(pid) else { return nil }
    if let bundle = NSRunningApplication(processIdentifier: r)?.bundleIdentifier { return bundle }
    guard let label = launchdLabel(pid: r, list: shell("/bin/launchctl", ["list"]) ?? "") else { return nil }
    return appForLabel(label, running: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
}

// L'etichetta del servizio col pid dato, dalle righe "pid  stato  etichetta" di `launchctl list`.
func launchdLabel(pid: pid_t, list: String) -> String? {
    for line in list.split(separator: "\n") {
        let f = line.split(separator: "\t")
        if f.count == 3, f[0] == "\(pid)" { return String(f[2]) }
    }
    return nil
}

// ponytail: basta l'inizio del nome (in.mikolajczuk.gravityd → in.mikolajczuk.gravity), quindi com.foo prenderebbe anche
// com.foobar.servizio; se capita, chiedere un punto o la fine dopo l'identificativo. Fra più app, la più lunga.
func appForLabel(_ label: String, running: [String]) -> String? {
    running.filter { label.hasPrefix($0) }.max { $0.count < $1.count }
}

// Il suono di un agente: con l'interruttore e il volume di Impostazioni › Suoni; al più uno ogni 5 s (agentSound).
func eventSound(_ s: AgentSession) {
    if Settings.shared.agentSounds { agentSound(s.state, volume: Settings.shared.agentVolume) }
}

// Socket Unix per-utente su cui gli hook degli agenti scrivono una riga JSON e chiudono (spec agenti §3).
// ponytail: nessuna autenticazione, il socket è locale e per-utente; il contenuto al massimo colora un anello
final class AgentServer {
    static let path = "/tmp/dockduo-\(getuid()).sock"
    let state: BarState
    private var listener: NWListener?
    private let path: String
    private let changed: () -> Void   // una sessione è cambiata in modo visibile: il Poller rifà i report
    private let front: () -> String?   // il bundle dell'app davanti (i test ne danno uno loro)
    private let sound: (AgentSession) -> Void   // suona per quella sessione (i test ne danno uno loro)

    init(state: BarState, path: String = AgentServer.path, changed: @escaping () -> Void,
         front: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         sound: @escaping (AgentSession) -> Void = eventSound) {
        self.state = state; self.path = path; self.changed = changed; self.front = front; self.sound = sound
    }

    func start() {
        unlink(path)   // residuo di un crash: bind fallirebbe
        let params = NWParameters(tls: nil)
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        do { listener = try NWListener(using: params) } catch { logger.error("agents: \(String(describing: error), privacy: .public)"); return }
        listener?.newConnectionHandler = { [self] c in
            c.start(queue: .main)
            read(c, Data())
        }
        // Un bind fallito dopo lo start (es. path già occupato) arriva solo qui, non altrove.
        listener?.stateUpdateHandler = { if case .failed(let e) = $0 { logger.error("agents: \(String(describing: e), privacy: .public)") } }
        listener?.start(queue: .main)
    }

    // Un messaggio per connessione, chiuso da newline; chiudiamo noi appena letto così `nc` esce subito. Fino ad allora
    // la connessione la trattiene il receive in sospeso (la sua closure): non serve tenerle da parte.
    // oltre 1 MB il JSON è troncato e scartato: la sessione resta com'era fino al prossimo evento
    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] data, _, complete, error in
            var buf = buf
            if let data { buf.append(data) }
            if complete || error != nil || buf.last == UInt8(ascii: "\n") || buf.count >= 1_048_576 {
                c.cancel()
                apply(buf)
            } else {
                read(c, buf)
            }
        }
    }

    func apply(_ data: Data) {   // non privata: i test la chiamano senza socket
        guard let m = parseAgentMessage(data) else { logger.error("agents: messaggio scartato"); return }
        // Un turno interrotto (Esc) non manda Stop: Claude fermo da un minuto chiude in silenzio una sessione ancora al
        // lavoro, come un end (niente suono, attesa né testo). In ogni altro stato non cambia niente.
        if m.idle, state.sessions[m.id]?.state != .working { return }
        // Un tick solo, e solo se cambia qualcosa di visibile: PreToolUse arriva a ogni tool call.
        let old = state.sessions[m.id]
        var new = m.session.map { continuing($0, from: old) }
        // L'app si cerca una volta, al primo messaggio della sessione: dopo la tiene continuing.
        if old == nil, new?.bundle == nil, let pid = m.pid { new?.bundle = hostBundle(pid: pid) }
        // Il processo dell'agente, a ogni messaggio (pochi sysctl): senza, resta quello di prima (continuing).
        if let pid = m.pid.flatMap({ agentPid($0) }) { new?.pid = pid }
        // Un'attesa con la sua app davanti è già vista (markSeen): niente giri, testo né suono.
        if new?.state == .waiting, let bundle = new?.bundle, bundle == front() { new?.seen = true }
        let visible = old?.state != new?.state || old?.bundle != new?.bundle || old?.seen != new?.seen
        state.sessions[m.id] = new   // nil (end) rimuove; l'anello e i testi sull'app cambiano col tick del Poller (changed)
        if visible { changed() }
        // Un fatto, un suono, negli stessi momenti dei testi sull'app (spec dock-degli-agenti §4): un'attesa non vista o un
        // turno finito (sound: di fabbrica eventSound).
        if visible, let s = new, s.state == .waiting && !s.seen || s.state == .done { sound(s) }
        // Sei ripartito con un agente: il "Sessione rinnovata!" del suo account ha fatto il suo (apply gira sul main: le
        // connessioni usano la coda main).
        if let s = m.session, s.state == .working {
            MainActor.assumeIsolated { QuotaCache.shared.clearRenewed([s.agent]) }
        }
    }
}
