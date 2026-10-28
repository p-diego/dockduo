import Foundation
import Testing
@testable import Dockduo

// I test su QuotaCache.shared uno alla volta: il primo aspetta (Task.yield) e un altro non deve cambiare i rinnovi in mezzo.
@MainActor @Suite(.serialized) struct RenewedAccounts {
    // Claude e ChatGPT possono rinnovarsi nello stesso aggiornamento: ognuno ha il suo orologio di 30 s, e un secondo rinnovo
    // dello stesso account lo fa ripartire senza spegnere niente. Un agente che riparte spegne solo l'account del suo agente.
    @Test func renewedIsPerAccount() async {
        let q = QuotaCache.shared
        q.renew(.claude); q.renew(.codex); q.renew(.claude)
        await Task.yield(); await Task.yield()
        #expect(q.renewed == [.claude, .codex])
        q.clearRenewed([.claude])
        #expect(q.renewed == [.codex])
        q.clearRenewed(Set(Agent.allCases))
        #expect(q.renewed.isEmpty)
    }

    // Ogni tool call di una sessione al lavoro chiede di spegnere il rinnovo del suo account: se non c'è niente da spegnere
    // nessuno se ne accorge (prima ridisegnava tutta la barra).
    @Test func anEmptyClearDoesNotNotify() {
        let q = QuotaCache.shared
        defer { q.clearRenewed(Set(Agent.allCases)) }
        q.renew(.codex)
        nonisolated(unsafe) var notified = false
        withObservationTracking { _ = q.renewed } onChange: { notified = true }
        q.clearRenewed([.claude])
        #expect(!notified)
        q.clearRenewed([.codex])
        #expect(notified)
    }

    // Una sessione Codex che riparte (AgentServer.apply) spegne "Sessione rinnovata!" solo per l'account ChatGPT.
    @Test func aCodexSessionAtWorkClearsOnlyItsAccount() {
        let q = QuotaCache.shared
        defer { q.clearRenewed(Set(Agent.allCases)); forgetSharedSettings() }   // apply legge i suoni degli agenti da Settings.shared
        q.renew(.claude); q.renew(.codex)
        let server = AgentServer(state: BarState(), path: "/tmp/dockduo-test-apply-\(getpid()).sock") {}   // niente socket: start() non parte
        server.apply(Data(#"{"agent":"codex","state":"working","bundle":"","payload":{"session_id":"q1"}}"#.utf8))
        #expect(q.renewed == [.claude])
    }
}
