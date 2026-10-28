import Foundation
import Testing
@testable import Dockduo

// Gli annunci di Spotify e Music (notifiche distribuite, gratis): Name, Artist, Player State. Stopped = niente
// traccia. La pillola "In riproduzione" vive di questi; l'Automazione serve solo a comandi, copertina e prima lettura.
@Test func readsATrackFromThePlayersAnnouncements() {
    let spotify = parseTrack(["Name": "Weird Fishes", "Artist": "Radiohead", "Player State": "Playing"], player: .spotify)
    #expect(spotify == Track(player: .spotify, title: "Weird Fishes", artist: "Radiohead", playing: true))
    let paused = parseTrack(["Name": "Km", "Artist": "Lucio", "Player State": "Paused"], player: .music)
    #expect(paused == Track(player: .music, title: "Km", artist: "Lucio", playing: false))
    #expect(parseTrack(["Player State": "Stopped"], player: .spotify) == nil)   // fermo: pillola vuota
    #expect(parseTrack(["Player State": "Playing"], player: .spotify) == nil)   // senza titolo non c'è traccia
}

// Music che si ferma mentre suona Spotify non spegne la pillola: un annuncio senza traccia conta solo dal lettore di
// quella corrente. Uno con la traccia conta sempre (il lettore nuovo prende il posto).
@Test func aStoppedPlayerDoesNotClearAnotherOne() {
    let spotify = Track(player: .spotify, title: "Weird Fishes", artist: "Radiohead", playing: true)
    #expect(!announcementApplies(nil, from: .music, current: spotify))
    #expect(announcementApplies(nil, from: .spotify, current: spotify))
    #expect(!announcementApplies(nil, from: .music, current: nil))
    #expect(announcementApplies(Track(player: .music, title: "Km", artist: "Lucio", playing: true), from: .music, current: spotify))
}
