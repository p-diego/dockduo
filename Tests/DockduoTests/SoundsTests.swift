import AppKit
import Testing
@testable import Dockduo

// I suoni li crea l'app (Sounds.swift): qui si misurano i campioni e il WAV, senza mai suonare.

private func seconds(_ x: [Double]) -> Double { Double(x.count) / sampleRate }
private func energy(_ x: [Double]) -> Double { x.reduce(0) { $0 + $1 * $1 } }
private func rmsDB(_ x: [Double], first t: Double = 0.6) -> Double {
    let n = min(x.count, Int(t * sampleRate))
    return 20 * log10(sqrt(energy(Array(x.prefix(n))) / Double(n)))
}

// Uguali a ogni creazione.
@Test func soundsAreIdenticalEveryTime() {
    for e in Effect.allCases { #expect(render(e) == render(e), "\(e)") }
}

// Le durate della prova scelta dall'autore (1,29 s, 1,34 s).
@Test func soundsLastAsLongAsThePrototype() {
    #expect(abs(seconds(render(.waits)) - 1.29) < 0.25)
    #expect(abs(seconds(render(.done)) - 1.34) < 0.25)
}

// Volume medio -18 dB (RMS dei primi 0,6 s), mai sopra 0,95.
@Test func soundsAreAtMinus18dBAndNeverClip() {
    for e in Effect.allCases {
        let x = render(e)
        #expect(abs(rmsDB(x) + 18) < 0.5, "\(e)")
        #expect((x.map(abs).max() ?? 1) <= 0.95, "\(e)")
    }
}

// Il WAV in memoria è un WAV vero: NSSound lo accetta (senza suonarlo) e ne conosce la durata, che il tasto Prova usa
// per far partire "ha finito" dopo "ti aspetta".
@Test func wavIsAcceptedByNSSound() throws {
    for e in Effect.allCases {
        let x = render(e), data = wav(x)
        #expect(data.count == 44 + x.count * 2, "\(e)")
        let sound = try #require(NSSound(data: data), "\(e)")
        #expect(abs(sound.duration - seconds(x)) < 0.01, "\(e)")
    }
}

// Un suono per "ti aspetta" e uno diverso per "ha finito"; lavorando niente.
@Test func agentStatesHaveOneSoundEach() {
    #expect(Effect(.waiting) == .waits && Effect(.done) == .done && Effect(.working) == nil)
    #expect(render(.waits) != render(.done))
}

// Dopo "ti aspetta", "ha finito" entro 5 s non suona se non è forzato (il tasto Prova); il forzato fa ripartire l'attesa.
@Test func limitLetsOneSoundThroughEveryFewSeconds() {
    let limit = Limit(every: 5), t = Date(timeIntervalSince1970: 1_000_000)
    #expect(limit.allow(at: t))                                     // "ti aspetta"
    #expect(!limit.allow(at: t + 2))                                // "ha finito" due secondi dopo: no
    #expect(!limit.allow(at: t + 5))                                // esattamente 5 s: ancora no
    #expect(limit.allow(force: true, at: t + 5))                    // forzato: sì
    #expect(!limit.allow(at: t + 9))                                // 4 s dal forzato
    #expect(limit.allow(at: t + 11))                                // 6 s dal forzato
}
