import Foundation
import Testing
@testable import Dockduo

private let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 11:33:20 UTC

@Test func parsesCredentialsFromTheKeychainJSON() {
    let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1789913843243,"subscriptionType":"pro"},"organizationUuid":"x"}"#
    let c = parseCredentials(Data(json.utf8))
    #expect(c?.accessToken == "tok")
    #expect(c?.plan == "pro")
    #expect(c?.expiresAt == Date(timeIntervalSince1970: 1_789_913_843.243))
    #expect(parseCredentials(Data(#"{"mcpOAuth":{}}"#.utf8)) == nil)
}

@Test func parsesUsageWindowsAndIgnoresNulls() {
    let json = #"{"five_hour":{"utilization":71.0,"resets_at":"2026-09-20T15:59:59.828443+00:00","limit_dollars":null},"seven_day":{"utilization":52.0,"resets_at":"2026-09-26T13:59:59+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"tangelo":null}"#
    let u = parseUsage(Data(json.utf8))
    #expect(u?.fiveHour?.utilization == 71)
    #expect(abs((u?.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0) - 1_789_919_999.828443) < 0.001)   // con le frazioni di secondo
    #expect(u?.rows.map(\.label) == ["Last 5 hours", "Week"])   // opus e sonnet null: niente riga
    #expect(u?.rows.last?.window.resetsAt == Date(timeIntervalSince1970: 1_790_431_199))
    #expect(parseUsage(Data("no".utf8)) == nil)
}

@Test func formatsQuotaLinesWithResetWithinADayOrOnAWeekday() {
    let soon = UsageWindow(utilization: 71.4, resetsAt: now.addingTimeInterval(87 * 60))
    #expect(quotaLine("Last 5 hours", soon, now: now) == "Last 5 hours  71 % · Resets in 1 h 27 min")
    let minutes = UsageWindow(utilization: 0, resetsAt: now.addingTimeInterval(5 * 60))
    #expect(quotaLine("Last 5 hours", minutes, now: now) == "Last 5 hours  0 % · Resets in 5 min")
    let later = UsageWindow(utilization: 52, resetsAt: now.addingTimeInterval(5 * 86_400))
    let line = quotaLine("Week", later, now: now, locale: Locale(identifier: "it"))
    #expect(line.hasPrefix("Week  52 % · Resets ") && line.count > "Week  52 % · Resets ".count)
    #expect(quotaLine("Opus", UsageWindow(utilization: 10, resetsAt: nil), now: now) == "Opus  10 %")
}

// La soglia: esaurita da 95 in su, rinnovata sotto 95. Per Claude la finestra è quella di 5 ore (Usage.fiveHour).
@Test func windowRenewedWorksForAnyWindow() {
    func w(_ pct: Double) -> UsageWindow { UsageWindow(utilization: pct, resetsAt: nil) }
    #expect(windowRenewed(from: w(96), to: w(0)))
    #expect(!windowRenewed(from: w(50), to: w(0)))
    #expect(!windowRenewed(from: nil, to: w(0)))
    #expect(!windowRenewed(from: w(96), to: nil))
    #expect(windowRenewed(from: w(95), to: w(94)))
    #expect(!windowRenewed(from: w(97), to: w(96)))     // ancora esaurita
    #expect(Usage(rows: [UsageRow(label: "x", window: w(97), session: true)]).fiveHour == w(97))
}

// Le righe `limits` dell'endpoint (come le legge Claude Code 2.1.283): nell'ordine del server, etichetta dal tipo e dal
// nome del modello; una riga malformata si salta, un tipo sconosciuto si mostra lo stesso. Hanno la precedenza sulle chiavi.
@Test func parsesTheServerLimitsRowsIncludingModelScopedWindows() {
    let json = #"""
    {"five_hour":{"utilization":10.0,"resets_at":null},"seven_day":{"utilization":40.0,"resets_at":null},"limits":[
     {"kind":"session","group":"session","percent":12,"resets_at":"2026-09-26T20:00:00+00:00","scope":null,"severity":"normal","is_active":true},
     {"kind":"weekly_all","group":"weekly","percent":41.5,"resets_at":"2026-09-30T08:00:00Z","scope":null,"severity":"normal","is_active":false},
     {"kind":"weekly_scoped","group":"weekly","percent":7,"resets_at":null,"scope":{"model":{"display_name":"Fable"}},"severity":"normal","is_active":false},
     {"kind":"monthly_credits","group":"monthly","percent":3,"resets_at":null,"scope":null,"severity":"normal","is_active":false},
     {"kind":"weekly_scoped","group":"weekly","resets_at":null}]}
    """#
    let u = parseUsage(Data(json.utf8))
    #expect(u?.rows.map(\.label) == ["Last 5 hours", "Week", "Fable, week", "Monthly Credits"])
    #expect(u?.rows.map(\.window.utilization) == [12, 41.5, 7, 3])
    #expect(u?.fiveHour?.utilization == 12)   // la riga session, non la chiave five_hour
    #expect(u?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_452_800))
}

// `limits` vuoto o assente: si torna alle chiavi fisse, così un server vecchio (o una risposta senza righe) mostra lo stesso le finestre.
@Test func emptyLimitsFallBackToTheKeys() {
    let u = parseUsage(Data(#"{"five_hour":{"utilization":5.0},"limits":[]}"#.utf8))
    #expect(u?.rows.map(\.label) == ["Last 5 hours"] && u?.fiveHour?.utilization == 5)
}

// Il piano vero viene dal profilo OAuth: il subscriptionType nel Keychain resta quello del login (pro dopo il passaggio a Max).
@Test func parsesThePlanFromTheOAuthProfile() {
    func plan(_ type: String, _ tier: String) -> String? {
        parsePlan(Data(#"{"organization":{"organization_type":"\#(type)","rate_limit_tier":"\#(tier)"}}"#.utf8))
    }
    #expect(plan("claude_max", "default_claude_max_5x") == "Max 5x")
    #expect(plan("claude_max", "default_claude_max_20x") == "Max 20x")
    #expect(plan("claude_pro", "default_claude_ai") == "Pro")
    #expect(parsePlan(Data(#"{"account":{}}"#.utf8)) == nil)
}

// Risposta di chatgpt.com/backend-api/wham/usage, piano Free (verificata il 2026-09-23).
private let codexJSON = #"{"user_id":"user-x","account_id":"acc","email":"me@example.com","plan_type":"free","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12.5,"limit_window_seconds":2592000,"reset_after_seconds":2591065,"reset_at":1792787252},"secondary_window":null},"credits":{"has_credits":false},"model_usage":{}}"#

@Test func parsesCodexUsageWithOneWindow() {
    let u = parseCodexUsage(Data(codexJSON.utf8))
    #expect(u?.plan == "Free")
    #expect(u?.email == "me@example.com")
    #expect(u?.usage.rows == [UsageRow(label: "Month", window: UsageWindow(utilization: 12.5, resetsAt: Date(timeIntervalSince1970: 1_792_787_252)),
                                       session: true)])   // 30 giorni: il mese; secondary_window null, niente riga
    #expect(parseCodexUsage(Data("no".utf8)) == nil)
}

@Test func parsesCodexSecondaryWindowAndMissingReset() {
    let json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000},"secondary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_at":1792787252}}}"#
    let u = parseCodexUsage(Data(json.utf8))
    #expect(u?.plan == "Plus" && u?.email == nil)
    #expect(u?.usage.fiveHour == UsageWindow(utilization: 40, resetsAt: nil))   // la primary_window, senza reset_at
    #expect(u?.usage.rows.map(\.label) == ["Last 5 hours", "Week"])
}

@Test func codexWindowLabelsFromSeconds() {
    #expect(codexWindowLabel(18_000) == "Last 5 hours")
    #expect(codexWindowLabel(604_800) == "Week")
    #expect(codexWindowLabel(2_592_000) == "Month")
}

@Test func parsesCodexCredentialsWhereverTheyAreNested() {
    let nested = #"{"OPENAI_API_KEY":null,"tokens":{"id_token":"i","access_token":"tok","refresh_token":"r","account_id":"acc"},"last_refresh":"2026-09-23T20:00:00Z"}"#
    #expect(parseCodexCredentials(Data(nested.utf8)) == CodexCredentials(accessToken: "tok", accountID: "acc"))
    #expect(parseCodexCredentials(Data(#"{"access_token":"t"}"#.utf8)) == CodexCredentials(accessToken: "t", accountID: ""))
    #expect(parseCodexCredentials(Data(#"{"tokens":{"refresh_token":"r"}}"#.utf8)) == nil)
    #expect(parseCodexCredentials(Data("x".utf8)) == nil)
}

@Test func parsesTheEmailFromTheOAuthProfile() {
    #expect(parseEmail(Data(#"{"account":{"email":"me@example.com","uuid":"u"},"organization":{}}"#.utf8)) == "me@example.com")
    #expect(parseEmail(Data(#"{"account":{}}"#.utf8)) == nil)
    #expect(parseEmail(Data("x".utf8)) == nil)
}

@Test func percentagesFromTheNetworkAreClamped() {
    let u = parseUsage(Data(#"{"five_hour":{"utilization":1e300},"seven_day":{"utilization":-5}}"#.utf8))
    #expect(u?.fiveHour?.utilization == 1000 && u?.rows.last?.window.utilization == 0)
    #expect(quotaLine("x", UsageWindow(utilization: 1000, resetsAt: nil)) == "x  1000 %")   // niente trap su Int(rounded())
    let c = parseCodexUsage(Data(#"{"rate_limit":{"primary_window":{"used_percent":-1,"limit_window_seconds":1}}}"#.utf8))
    #expect(c?.usage.fiveHour?.utilization == 0)
}

