import AppKit
import SwiftUI

// "In riproduzione" (autore, 4/10): cosa suona in Spotify o Music. I due lettori annunciano da soli il brano con una
// notifica distribuita (gratis, nessun permesso): Name, Artist, Player State. L'Automazione — il primo permesso di
// controllo-altre-app che accettiamo, confinato a questo widget spento di default — serve solo per la prima lettura
// all'accensione, i comandi (pausa, avanti, indietro) e la copertina. Niente browser: cosa suona nel web lo sa solo
// MediaRemote, privato e chiuso alle app esterne dalle versioni recenti.

enum Player: String, CaseIterable {
    case spotify = "Spotify", music = "Music"
    var bundle: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var note: String { self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo" }
}

struct Track: Equatable {
    let player: Player
    let title: String
    let artist: String
    let playing: Bool
}

// L'annuncio di un lettore → la traccia. "Stopped" o senza titolo = niente in riproduzione.
func parseTrack(_ info: [AnyHashable: Any], player: Player) -> Track? {
    guard let state = info["Player State"] as? String, state != "Stopped",
          let title = info["Name"] as? String, !title.isEmpty else { return nil }
    return Track(player: player, title: title, artist: info["Artist"] as? String ?? "", playing: state == "Playing")
}

// Un annuncio conta se porta una traccia o viene dal lettore di quella corrente: un lettore che si ferma non spegne
// quello che suona un altro (Music dice Stopped mentre suona Spotify).
func announcementApplies(_ track: Track?, from player: Player, current: Track?) -> Bool {
    track != nil || current?.player == player
}

// Osserva gli annunci e tiene BarState.track aggiornato; la prima lettura (e la copertina) via AppleScript quando il
// widget è acceso. Gli osservatori restano registrati sempre: a widget spento scartano e basta (costano zero).
@MainActor
enum NowPlaying {
    static func start() {
        for player in Player.allCases {
            DistributedNotificationCenter.default().addObserver(forName: .init(player.note), object: nil, queue: .main) { n in
                MainActor.assumeIsolated {
                    let track = parseTrack(n.userInfo ?? [:], player: player)
                    guard Settings.shared.isOn(.nowPlaying), announcementApplies(track, from: player, current: state.track) else { return }
                    apply(track)
                }
            }
        }
        if Settings.shared.isOn(.nowPlaying) { readNow() }
    }

    static func apply(_ track: Track?) {
        // La copertina resta durante play/pausa (cambia solo `playing`): azzerarla faceva lampeggiare la nota (autore, 4/10).
        let songChanged = track?.title != state.track?.title || track?.artist != state.track?.artist
            || track?.player != state.track?.player
        if track != state.track { withAnimation(.smooth(duration: 0.3)) { state.track = track } }
        if songChanged { state.artwork = nil }
        // Finché la copertina manca si richiede a ogni annuncio: la prima richiesta cade nell'istante del cambio brano
        // e può fallire — una sola occasione lasciava la nota per sempre (misurato il 4/10). Le tracce di radio e
        // riproduzione automatica non ce l'hanno mai: lì resta la nota, giusto così.
        if let track, songChanged || state.artwork == nil { fetchArtwork(track) }
    }

    // La prima lettura: chiede al lettore in esecuzione cosa sta suonando (qui scatta la richiesta di Automazione,
    // solo col widget acceso). Fuori dal main: AppleScript è bloccante.
    static func readNow() {
        for player in Player.allCases where !runningApps(bundle: player.bundle).isEmpty {
            let script = """
            tell application "\(player.rawValue)"
                if player state is playing or player state is paused then
                    {name of current track, artist of current track, (player state is playing) as string}
                end if
            end tell
            """
            runAppleScript(script) { d in
                guard let d, d.numberOfItems == 3 else { return }
                apply(Track(player: player, title: d.atIndex(1)?.stringValue ?? "", artist: d.atIndex(2)?.stringValue ?? "",
                            playing: d.atIndex(3)?.stringValue == "true"))
            }
        }
    }

    // Pausa/riprendi, avanti, indietro: il lettore della traccia corrente.
    static func command(_ verb: String) {
        guard let player = state.track?.player else { return }
        runAppleScript("tell application \"\(player.rawValue)\" to \(verb)") { _ in readNow() }
    }

    // La copertina: Spotify dà l'indirizzo (poi la rete), Music i dati dell'immagine. In BarState come immagine.
    static func fetchArtwork(_ track: Track) {
        switch track.player {
        case .spotify:
            runAppleScript("tell application \"Spotify\" to artwork url of current track") { d in
                guard let urlString = d?.stringValue, let url = URL(string: urlString) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    let image = data.flatMap(NSImage.init(data:))
                    DispatchQueue.main.async { if state.track?.title == track.title { state.artwork = image } }
                }.resume()
            }
        case .music:
            runAppleScript("tell application \"Music\" to data of artwork 1 of current track") { d in
                if let data = d?.data, let image = NSImage(data: data), state.track?.title == track.title { state.artwork = image }
            }
        }
    }
}

// AppleScript su una coda di fondo (bloccante, e col permesso può aprire la richiesta di macOS); il risultato torna
// sul main. Errore = nil: il widget resta com'è. La coda è SERIALE: NSAppleScript non regge esecuzioni sovrapposte
// (prima lettura + copertina partivano insieme sulla coda globale e potevano fallire in silenzio).
private let scriptQueue = DispatchQueue(label: "dockduo.applescript", qos: .userInitiated)
func runAppleScript(_ source: String, done: @MainActor @escaping (NSAppleEventDescriptor?) -> Void) {
    scriptQueue.async {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        DispatchQueue.main.async { done(error == nil ? result : nil) }
    }
}
