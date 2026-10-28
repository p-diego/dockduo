import Foundation

// Quota Claude (nel menu al tasto destro delle app che ospitano una sessione di Claude): le credenziali OAuth di Claude
// Code dal Keychain e l'endpoint usage che usano ClaudeMeter e simili. Solo lettura: se il token è scaduto lo rinnova
// Claude Code al prossimo uso.
// ponytail: endpoint non documentato; se cambia, il menu dice "Non disponibile" e basta

struct UsageWindow: Equatable {
    let utilization: Double   // percentuale 0…100
    let resetsAt: Date?
}

// Una riga della quota, con l'etichetta già pronta; `session` = la finestra del "Sessione rinnovata!" (windowRenewed).
struct UsageRow: Equatable {
    let label: String
    let window: UsageWindow
    var session = false
}

struct Usage: Equatable {
    var rows: [UsageRow]   // nell'ordine del server
    var fiveHour: UsageWindow? { rows.first { $0.session }?.window }
}

struct Credentials {
    let accessToken: String
    let expiresAt: Date
    let plan: String   // subscriptionType: pro, max… — quello del login: resta vecchio se cambi piano (vedi parsePlan)
}

// Voce Keychain `Claude Code-credentials`: JSON con `claudeAiOauth.{accessToken, expiresAt (ms), subscriptionType}`.
// Letta con `/usr/bin/security`, che è già autorizzato sulla voce: con SecItemCopyMatching macOS chiederebbe la password
// a ogni build (bundle firmato ad-hoc = app "nuova" per il Keychain). Chiamata bloccante (~50 ms): non sul main.
func readCredentials() -> Credentials? {
    shell("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]).flatMap { parseCredentials(Data($0.utf8)) }
}

func parseCredentials(_ data: Data) -> Credentials? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let o = json["claudeAiOauth"] as? [String: Any],
          let token = o["accessToken"] as? String, let expires = o["expiresAt"] as? Double else { return nil }
    return Credentials(accessToken: token, expiresAt: Date(timeIntervalSince1970: expires / 1000), plan: o["subscriptionType"] as? String ?? "")
}

// GET https://api.anthropic.com/api/oauth/<path> col token di Claude Code: "usage" (quota) e "profile" (piano).
func fetchOAuth(_ path: String, token: String) async throws -> Data {
    try await get("https://api.anthropic.com/api/oauth/\(path)", ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"])
}

enum UsageError: Error { case http(Int), parse }

// Le percentuali arrivano dalla rete: un valore assurdo (negativo, enorme, NaN) non deve far crashare `Int(rounded())`.
private func clamped(_ u: Double) -> Double { u.isFinite ? min(max(u, 0), 1000) : 0 }

// Effimera: URLSession.shared salva richieste e intestazioni (il token compreso) in Caches/com.dockduo.app/Cache.db.
private let quotaSession = URLSession(configuration: .ephemeral)

// GET con le intestazioni date (e Accept json). 200 → i dati; altrimenti UsageError.http, che il menu traduce in "Non
// disponibile" o "Troppe richieste".
private func get(_ url: String, _ headers: [String: String]) async throws -> Data {
    var req = URLRequest(url: URL(string: url)!)
    req.allHTTPHeaderFields = ["Accept": "application/json"].merging(headers) { $1 }
    req.timeoutInterval = 10
    let (data, response) = try await quotaSession.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw UsageError.http(status) }
    return data
}

// Piano dal profilo: `{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}`
// → "Max 5x"; senza moltiplicatore nel tier (pro: "default_claude_ai") solo il nome. nil se manca il tipo.
func parsePlan(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let org = json["organization"] as? [String: Any],
          let type = org["organization_type"] as? String, !type.isEmpty else { return nil }
    let name = type.replacingOccurrences(of: "claude_", with: "").capitalized
    let tier = (org["rate_limit_tier"] as? String)?.split(separator: "_").last.map(String.init) ?? ""
    return tier.range(of: #"^\d+x$"#, options: .regularExpression) != nil ? "\(name) \(tier)" : name
}

// Risposta: le righe `limits` del server (vedi limitRow), che contengono tutte le finestre, anche quelle per modello come
// Fable, e che un client deve mostrare così come arrivano (lo dice lo schema di Claude Code 2.1.283, 2026-09-26). Senza
// righe (server vecchio, o `limits` vuoto) le chiavi fisse di prima: `{"five_hour":{"utilization":71.0,"resets_at":"…"},
// "seven_day":{…},"seven_day_opus":null,…}`; le finestre assenti o null non hanno riga.
func parseUsage(_ data: Data) -> Usage? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty { return Usage(rows: limits.compactMap(limitRow)) }
    let keys: [(key: String, label: String)] = [("five_hour", "Last 5 hours"), ("seven_day", "Week"),
                                                ("seven_day_opus", "Opus, week"), ("seven_day_sonnet", "Sonnet, week")]
    return Usage(rows: keys.compactMap { k in
        guard let w = json[k.key] as? [String: Any], let u = w["utilization"] as? Double else { return nil }
        return UsageRow(label: String(localized: String.LocalizationValue(k.label)),
                        window: UsageWindow(utilization: clamped(u), resetsAt: (w["resets_at"] as? String).flatMap(parseISO)),
                        session: k.key == "five_hour")
    })
}

// Una riga di `limits`: `{"kind":"session"|"weekly_all"|"weekly_scoped"|…,"group":"session"|"weekly"|…,"percent":0…100,
// "resets_at":"ISO"|null,"scope":{"model":{"display_name":"Fable"}}|{"surface":{…}}|null,"severity":…,"is_active":…}`.
// Etichetta dal tipo, o dal nome del modello (o della superficie); un tipo sconosciuto si mostra col suo nome, così una
// finestra nuova compare senza una versione nuova di dockduo. Senza tipo o percentuale la riga si salta.
private func limitRow(_ l: [String: Any]) -> UsageRow? {
    guard let kind = l["kind"] as? String, let percent = l["percent"] as? Double else { return nil }
    let scope = l["scope"] as? [String: Any]
    let name = ((scope?["model"] ?? scope?["surface"]) as? [String: Any])?["display_name"] as? String
    let label = switch (kind, name) {
    case ("session", _): String(localized: "Last 5 hours")
    case ("weekly_all", _): String(localized: "Week")
    case (_, let name?): l["group"] as? String == "weekly" ? String(localized: "\(name), week") : name
    default: kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
    let reset = (l["resets_at"] as? String).flatMap(parseISO) ?? (l["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
    return UsageRow(label: label, window: UsageWindow(utilization: clamped(percent), resetsAt: reset), session: kind == "session")
}

private func parseISO(_ s: String) -> Date? {
    (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(s, strategy: .iso8601))
}

// Riga del menu: "Ultime 5 ore  71 % · Si azzera fra 1 h 27 min" (entro un giorno) o "… dom 15:59" (oltre).
// Testi da Localizable.strings (solo it: in inglese il testo è la chiave); i test girano senza bundle e vedono le chiavi.
func quotaLine(_ label: String, _ w: UsageWindow, now: Date = Date(), locale: Locale = .current) -> String {
    var line = "\(label)  \(Int(w.utilization.rounded())) %"
    guard let reset = w.resetsAt else { return line }
    let secs = max(0, reset.timeIntervalSince(now))
    if secs < 86_400 {
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        line += " · " + (h > 0 ? String(localized: "Resets in \(h) h \(m) min") : String(localized: "Resets in \(m) min"))
    } else {
        let f = DateFormatter(); f.locale = locale; f.dateFormat = "EEE HH:mm"
        line += " · " + String(localized: "Resets \(f.string(from: reset))")
    }
    return line
}

// Sessione rinnovata: una finestra era esaurita (≥ 95 %) e alla lettura dopo non lo è più. Per Claude è quella
// di 5 ore, per ChatGPT la prima (5 ore sui piani a pagamento, il mese sul Free).
func windowRenewed(from old: UsageWindow?, to new: UsageWindow?) -> Bool {
    guard let o = old, let n = new else { return false }
    return o.utilization >= 95 && n.utilization < 95
}

// MARK: ChatGPT / Codex (spec Codex §3)

// Token di login dell'app ChatGPT / CLI Codex: `$CODEX_HOME/auth.json` o `~/.codex/auth.json`. La forma non è
// documentata (qui `tokens.access_token`, `tokens.account_id`): si cercano le chiavi a qualunque profondità.
struct CodexCredentials: Equatable {
    let accessToken: String
    let accountID: String
}

private func find(_ key: String, in any: Any) -> String? {
    guard let d = any as? [String: Any] else { return nil }
    if let v = d[key] as? String, !v.isEmpty { return v }
    for v in d.values { if let r = find(key, in: v) { return r } }
    return nil
}

func parseCodexCredentials(_ data: Data) -> CodexCredentials? {
    guard let json = try? JSONSerialization.jsonObject(with: data), let token = find("access_token", in: json) else { return nil }
    return CodexCredentials(accessToken: token, accountID: find("account_id", in: json) ?? "")
}

func readCodexCredentials() -> CodexCredentials? {
    (try? Data(contentsOf: codexDir.appendingPathComponent("auth.json"))).flatMap(parseCodexCredentials)
}

// GET https://chatgpt.com/backend-api/wham/usage: la stessa richiesta dell'app (verificata il 2026-09-23).
// ponytail: endpoint non documentato; se cambia, il menu dice "Non disponibile" e basta
func fetchCodexUsage(_ c: CodexCredentials) async throws -> Data {
    try await get("https://chatgpt.com/backend-api/wham/usage",
                  ["Authorization": "Bearer \(c.accessToken)", "ChatGPT-Account-Id": c.accountID, "User-Agent": "codex-cli"])
}

struct CodexUsage: Equatable {
    let plan: String     // plan_type con l'iniziale maiuscola: Free, Plus, Pro
    let email: String?
    let usage: Usage     // le righe come quelle di Claude: la primary_window (session) e la secondary_window
}

// `{"plan_type":"free","email":…,"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":2592000,
// "reset_at":1792787252},"secondary_window":null}}`; finestre assenti o null non hanno riga, reset_at assente = senza
// data. L'etichetta dalla durata (limit_window_seconds: 5 h, 7 giorni, 30 giorni).
func parseCodexUsage(_ data: Data) -> CodexUsage? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let limits = json["rate_limit"] as? [String: Any] ?? [:]
    let rows = ["primary_window", "secondary_window"].compactMap { key -> UsageRow? in
        guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
        let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return UsageRow(label: codexWindowLabel(w["limit_window_seconds"] as? Int ?? 0),
                        window: UsageWindow(utilization: clamped(used), resetsAt: reset), session: key == "primary_window")
    }
    return CodexUsage(plan: (json["plan_type"] as? String ?? "").capitalized, email: json["email"] as? String, usage: Usage(rows: rows))
}

// Etichetta della finestra dalla sua durata: le stesse parole della quota Claude dove coincidono.
func codexWindowLabel(_ seconds: Int) -> String {
    if seconds <= 6 * 3600 { return String(localized: "Last 5 hours") }
    if seconds <= 8 * 86_400 { return String(localized: "Week") }
    return String(localized: "Month")
}

// Mail dell'account Claude dal profilo OAuth (`{"account":{"email":…},"organization":{…}}`); nil se manca.
func parseEmail(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let email = (json["account"] as? [String: Any])?["email"] as? String, !email.isEmpty else { return nil }
    return email
}
