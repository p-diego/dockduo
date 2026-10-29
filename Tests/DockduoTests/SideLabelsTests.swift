import AppKit
import SwiftUI
import Testing
@testable import Dockduo

struct SideLabelsTests {
    @Test func newsIsANewNonEmptyText() {
        #expect(labelNews(old: nil, new: "Code") && labelNews(old: "Code", new: "Safari"))
        #expect(!labelNews(old: "Code", new: "Code") && !labelNews(old: "Code", new: nil))
    }
    @Test func showReplacesAndHideRemoves() {
        let l = SideLabels()
        l.show("front", SideLabel(text: "Code", style: .glass, anchor: .zero)); l.show("front", SideLabel(text: "Safari", style: .glass, anchor: .zero))
        #expect(l.items.count == 1 && l.items["front"]?.text == "Safari")
        l.hide("front", ifText: "Safari"); #expect(l.items.isEmpty)
    }
    @Test func staleHideKeepsTheNewLabel() {
        let l = SideLabels()
        l.show("front", SideLabel(text: "B", style: .glass, anchor: .zero))
        l.hide("front", ifText: "A"); #expect(l.items["front"]?.text == "B")
        l.hide("front", ifText: "B"); #expect(l.items.isEmpty)
    }
    @Test func aViewThatShowedNothingHidesNothing() {
        let l = SideLabels()
        l.show("front", SideLabel(text: "B", style: .glass, anchor: .zero))
        l.release("front", shown: nil); #expect(l.items["front"]?.text == "B")
        l.release("front", shown: "B"); #expect(l.items.isEmpty)
    }
    // Due voci del Dock con lo stesso nome (due Chrome, una cartella e un file Download): passando dalla prima alla seconda,
    // l'uscita della prima, che arriva dopo, non toglie il nome della seconda; la cornice dice di chi è.
    @Test func twoDockItemsWithTheSameNameOwnTheirLabel() {
        let l = SideLabels(), above = CGRect(x: 3, y: 10, width: 45, height: 31), below = above.offsetBy(dx: 0, dy: 33)
        l.show("dock", SideLabel(text: "Downloads", style: .dockName, anchor: above))
        l.show("dock", SideLabel(text: "Downloads", style: .dockName, anchor: below))
        l.release("dock", shown: "Downloads", at: above); #expect(l.items["dock"]?.anchor == below)
        l.release("dock", shown: "Downloads", at: below); #expect(l.items.isEmpty)
    }
    // A → B → A dentro l'attesa dell'uscita: il testo di A non è mai cambiato, la sua entrata (claim) rimette il suo nome
    // perché quello in vista è di B (stesso nome, altra cornice); poi l'uscita di B, in ritardo, non lo toglie.
    @Test func reenteringATileTakesItsNameBack() {
        let l = SideLabels(), a = CGRect(x: 3, y: 10, width: 45, height: 31), b = a.offsetBy(dx: 0, dy: 33)
        l.show("dock", SideLabel(text: "Mail", style: .dockName, anchor: a))
        l.show("dock", SideLabel(text: "Mail", style: .dockName, anchor: b))
        #expect(!l.isShowing("dock", "Mail", at: a) && l.isShowing("dock", "Mail", at: b))
        l.claim("dock", SideLabel(text: "Mail", style: .dockName, anchor: a))   // l'entrata di A
        l.release("dock", shown: "Mail", at: b)
        #expect(l.isShowing("dock", "Mail", at: a))
    }
    // Accanto a un'icona un testo solo: il nome del Dock al passaggio del mouse copre "Ti aspetta" della stessa app, che copre il
    // nome dell'app davanti; su un'altra riga restano tutti. Coperti, restano nella raccolta.
    @Test func oneLabelEachRow() {
        let row = CGRect(x: 3, y: 10, width: 45, height: 31), icon = CGRect(x: 10, y: 10, width: 31, height: 31), below = row.offsetBy(dx: 0, dy: 33)
        var items: [String: SideLabel] = ["front": SideLabel(text: "Code", style: .glass, anchor: icon),
                                          "agent-7": SideLabel(text: "Waiting for you", style: .agent(color: nil), anchor: icon),
                                          "agent-8": SideLabel(text: "Finished", style: .agent(color: nil), anchor: below)]
        #expect(coveredLabels(items, axis: .vertical) == ["front"])
        items["dock"] = SideLabel(text: "Code", style: .dockName, anchor: row)
        #expect(coveredLabels(items, axis: .vertical) == ["front", "agent-7"])
    }
    // Una regola per i due assi: un testo che lungo la barra si sovrappone di più di un punto a uno in vista che conta di
    // più resta coperto. In basso i testi sono larghi e le icone a 33: due vicini più larghi del passo, si vede solo quello
    // che conta di più (il nome del Dock, poi gli agenti, a parità l'id); lontani, tutti e due. Il tratto è quello del testo
    // appoggiato al bordo vicino al capo della barra (labelCentre). Di lato due testi alti 26 su icone a 25,85 (gli spazi
    // nel Dock a barra 52) si toccano appena: restano tutti e due.
    @Test func bottomLabelsCoverTheirNeighbours() {
        func at(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 4, width: 31, height: 45) }
        func agent(_ x: CGFloat) -> SideLabel { SideLabel(text: "Waiting for you", style: .agent(color: nil), anchor: at(x)) }
        let lengths: [String: CGFloat] = ["agent-7": 120, "agent-8": 120, "dock": 60, "front": 30]
        func covered(_ items: [String: SideLabel]) -> Set<String> { coveredLabels(items, axis: .horizontal, lengths: lengths, panel: 1000) }
        #expect(covered(["agent-7": agent(200), "agent-8": agent(233)]) == ["agent-8"])
        #expect(covered(["agent-7": agent(200), "agent-8": agent(400)]).isEmpty)
        #expect(covered(["agent-7": agent(200), "dock": SideLabel(text: "Mail", style: .dockName, anchor: at(233))]) == ["agent-7"])
        #expect(covered(["agent-7": agent(0), "front": SideLabel(text: "Code", style: .glass, anchor: at(95))]) == ["front"])
        let icon = CGRect(x: 10, y: 100, width: 24, height: 24), next = icon.offsetBy(dx: 0, dy: 25.85)
        #expect(coveredLabels(["agent-7": SideLabel(text: "Waiting for you", style: .agent(color: nil), anchor: icon),
                               "agent-8": SideLabel(text: "Finished", style: .agent(color: nil), anchor: next)],
                              axis: .vertical, lengths: ["agent-7": 26, "agent-8": 26], panel: 1000).isEmpty)
    }
    // In basso un testo vicino a un capo della barra resta tutto nel pannello, appoggiato al bordo, come i nomi del Dock di
    // macOS: il testo comincia 13 dentro la capsula, quindi l'inchiostro sta a 13 dai bordi.
    @MainActor @Test func bottomLabelsStayInsideThePanel() throws {
        let labels = SideLabels()
        labels.show(SideLabels.dock, SideLabel(text: "System Settings", style: .dockName, anchor: CGRect(x: 0, y: 4, width: 31, height: 45)))
        labels.show("agent-1", SideLabel(text: "Waiting for you", style: .agent(color: nil), anchor: CGRect(x: 369, y: 4, width: 31, height: 45)))
        let ink = try inkBounds(SideLabelsView(labels: labels, side: .bottom), size: CGSize(width: 400, height: 360))
        #expect(ink.minX >= 12 && ink.maxX <= 388, "\(ink)")
    }
    // In basso i nomi stanno sopra le icone (spec app conclusa §3.2), come nel Dock di macOS in basso: il nome di una voce
    // centrato sulla sua x, il fondo a dockNameGap dal lato del pannello che tocca la barra, quindi sopra la barra.
    @MainActor @Test func namesSitAboveTheIcons() throws {
        let labels = SideLabels(), anchor = CGRect(x: 200, y: 4, width: 31, height: 45)   // una voce del Dock in basso, a barra 52
        labels.show(SideLabels.dock, SideLabel(text: "App Store", style: .dockName, anchor: anchor))
        let ink = try inkBounds(SideLabelsView(labels: labels, side: .bottom), size: CGSize(width: 400, height: 360))
        let bottom = 360 - dockNameGap(anchor: anchor, barWidth: 52, side: .bottom)
        #expect(abs(ink.midX - anchor.midX) < 2, "\(ink)")
        #expect(ink.maxY <= bottom + 0.5 && ink.minY >= bottom - 26 - 0.5, "\(ink)")
    }
}

// Dove si disegna qualcosa (i pixel non trasparenti), in punti dalla cima a sinistra, in una finestra mai mostrata (per la
// scala dello schermo). Fuori dallo schermo il vetro non si disegna: di un'etichetta resta il testo.
@MainActor func inkBounds(_ view: some View, size: CGSize) throws -> CGRect {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let bytes = try #require(rep.bitmapData), step = rep.bitsPerPixel / 8, k = CGFloat(rep.pixelsWide) / size.width
    var (x0, y0, x1, y1) = (Int.max, Int.max, -1, -1)
    for y in 0..<rep.pixelsHigh {
        let row = bytes + y * rep.bytesPerRow
        for x in 0..<rep.pixelsWide where (0..<step).contains(where: { row[x * step + $0] != 0 }) {
            (x0, y0, x1, y1) = (min(x0, x), min(y0, y), max(x1, x), max(y1, y))
        }
    }
    withExtendedLifetime(window) {}
    return x1 < 0 ? .null : CGRect(x: CGFloat(x0) / k, y: CGFloat(y0) / k, width: CGFloat(x1 - x0 + 1) / k, height: CGFloat(y1 - y0 + 1) / k)
}
