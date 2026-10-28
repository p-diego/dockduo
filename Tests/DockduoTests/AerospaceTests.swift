import Foundation
import Testing
@testable import Dockduo

// Protocollo della socket di AeroSpace (guida, § "Socket protocol"): lunghezza UInt32 little-endian + JSON.
@Test func frameIsLittleEndianLengthThenPayload() {
    let payload = Data("{\"a\":1}".utf8)
    #expect(frame(payload) == Data([7, 0, 0, 0]) + payload)
    #expect(frame(Data(count: 300)).prefix(4) == Data([44, 1, 0, 0]))
}

@Test func requestPayloadHasArgsEmptyStdinAndNullEnv() throws {
    let json = try #require(JSONSerialization.jsonObject(with: requestPayload(["list-windows", "--all"])) as? [String: Any])
    #expect(json["args"] as? [String] == ["list-windows", "--all"])
    #expect(json["stdin"] as? String == "")
    #expect(json["windowId"] is NSNull && json["workspace"] is NSNull)
}

@Test func answerStdoutOnlyOnSuccess() {
    #expect(answerStdout(Data(#"{"exitCode":0,"stdout":"1\n2","stderr":"","serverVersionAndHash":"x"}"#.utf8)) == "1\n2")
    #expect(answerStdout(Data(#"{"exitCode":2,"stdout":"","stderr":"no","serverVersionAndHash":"x"}"#.utf8)) == nil)
    #expect(answerStdout(Data("not json".utf8)) == nil)
}

// Righe vere di `aerospace subscribe --all` (0.21.3, 2026-09-23).
@Test func parseEventReadsTypeAndWindowId() {
    #expect(parseEvent(Data(#"{"_event":"focus-changed","windowId":3054,"workspace":"3"}"#.utf8))
            == AerospaceEvent(type: "focus-changed", windowId: 3054))
    #expect(parseEvent(Data(#"{"_event":"focused-workspace-changed","prevWorkspace":"3","workspace":"4"}"#.utf8))
            == AerospaceEvent(type: "focused-workspace-changed", windowId: nil))
}

// Review Focus 3: JSON rotto o senza `_event` → nil, il flusso va avanti.
@Test func parseEventRejectsBrokenJSON() {
    #expect(parseEvent(Data("{".utf8)) == nil)
    #expect(parseEvent(Data(#"{"windowId":1}"#.utf8)) == nil)
}

// Finding 1 della revisione finale: subscribe rifiutato (exitCode ≠ 0) va riconosciuto per chiudere la connessione.
@Test func isRejectionOnlyOnNonZeroExitCode() {
    #expect(isRejection(Data(#"{"exitCode":1,"stdout":"","stderr":"no such subscription","serverVersionAndHash":"x"}"#.utf8)))
    #expect(!isRejection(Data(#"{"_event":"focus-changed","windowId":3054,"workspace":"3"}"#.utf8)))
    #expect(!isRejection(Data(#"{"exitCode":0,"stdout":"","stderr":"","serverVersionAndHash":"x"}"#.utf8)))
    #expect(!isRejection(Data("{".utf8)))
}

// Chi chiama la cerca mentre l'app si sta mostrando: per 0,2 s AeroSpace dice ancora "di un'app nascosta" (misurato il
// 27/9), quindi quelle contano; le minimizzate no.
@Test func firstShowableWindowSkipsOnlyMinimized() {
    #expect(firstShowableWindow("7|macos_native_minimized\n8|macos_native_window_of_hidden_app\n9|floating\n") == 8)
    #expect(firstShowableWindow("7|macos_native_minimized\n") == nil)
    #expect(firstShowableWindow("") == nil)
}

// Il clic sul Dock da seguire: nei 120 pt in basso dello schermo del clic (anche quello in alto a sinistra, non lo schermo
// principale), sull'app già davanti e ancora davanti 0,4 s dopo. Un clic sul desktop (passa al Finder), più su, fuori dagli
// schermi o su dockduo: niente.
@Test func aDockClickFollowsOnlyTheAppAlreadyInFront() {
    let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 982, width: 1920, height: 1080)]
    func follows(_ x: CGFloat, _ y: CGFloat, front: String? = "com.apple.Safari", later: String? = "com.apple.Safari") -> String? {
        dockClickFollows(at: CGPoint(x: x, y: y), screens: screens, front: front, frontLater: later, me: "com.dockduo")
    }
    #expect(follows(700, 0) == "com.apple.Safari" && follows(700, 119.5) == "com.apple.Safari")
    #expect(follows(700, 120) == nil && follows(700, 500) == nil)
    #expect(follows(-900, 1000) == "com.apple.Safari" && follows(-900, 982 + 120) == nil)   // il Dock sull'altro schermo
    #expect(follows(-900, 50) == nil)   // sotto l'altro schermo: nessuno schermo lo contiene
    #expect(follows(700, 10, later: "com.apple.finder") == nil)   // clic sul desktop: davanti passa il Finder
    #expect(follows(700, 10, front: nil, later: nil) == nil)
    #expect(follows(700, 10, front: "com.dockduo", later: "com.dockduo") == nil)
}
