import CoreGraphics
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
        #expect(coveredLabels(items) == ["front"])
        items["dock"] = SideLabel(text: "Code", style: .dockName, anchor: row)
        #expect(coveredLabels(items) == ["front", "agent-7"])
    }
}
