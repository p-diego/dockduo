import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// Un aspetto solo (spec dock-degli-agenti §5): in scuro nessuna tavolozza (i bianchi di sempre), in chiaro clearLight.
@Test func theBarHasAPaletteOnlyWhenTheMacIsLight() {
    #expect(palette(dark: true) == nil && palette(dark: false) == clearLight)
}

@Test func hexColorsSplitIntoChannels() {
    #expect(cgColor(hex: 0xFF8000) == CGColor(srgbRed: 1, green: 128.0 / 255, blue: 0, alpha: 1))
}

// In scuro valgono i bianchi di oggi, in chiaro i colori di clearLight; i colori degli stati lo stesso.
@Test func darkKeepsTodaysWhitesLightUsesItsColors() {
    let none: Palette? = nil, light: Palette? = clearLight
    #expect(none.ink == .white.opacity(0.9) && none.dim == .white.opacity(0.45))
    #expect(light.ink == Color(hex: 0x1C1C1C))
    #expect(AgentState.working.color(in: clearLight) == clearLight.blue)
    for state in [AgentState.working, .waiting, .done] {
        #expect(state.color(in: nil) != state.color(in: clearLight))
    }
}

// Il contrasto WCAG (il testo di un agente sull'app, DockNameLabel): da 1 a 21.
@Test func contrastGoesFromOneToTwentyOne() {
    #expect(contrast(.white, .black) > 20.9 && contrast(.white, .black) < 21.1)
    #expect(abs(contrast(.white, .white) - 1) < 0.01)
}

// La pillola sta in piedi: larga 26 in scala, lunga quanto il contenuto (spec barra-di-lato §3).
@MainActor @Test func sidePillsStandUpAndScale() {
    func size(_ scale: CGFloat) -> CGSize {
        NSHostingView(rootView: NowPlayingView(track: Track(player: .music, title: "Song", artist: "Artist", playing: false), artwork: nil)
            .environment(\.barScale, scale)).fittingSize
    }
    #expect(size(1).width == 26 && size(2).width == 52)
    #expect(size(2).height > size(1).height)
}
