import AppKit
import SwiftUI
import Testing
@testable import Dockduo

// L'anello della batteria come la batteria di iOS (spec dock-contenitori §4): pieno quanto la carica; giallo col Risparmio
// energetico (anche in carica), verde in carica, rosso sotto il 20 % senza carica; senza batteria (un Mac fisso) vuoto.
@Test func theRingIsTheBattery() {
    #expect(batteryRing(Battery(percent: 75, charging: true)) == (0.75, .green))
    #expect(batteryRing(Battery(percent: 15, charging: false)) == (0.15, .red))
    #expect(batteryRing(Battery(percent: 19, charging: false)) == (0.19, .red) && batteryRing(Battery(percent: 20, charging: false)) == (0.2, .white))
    #expect(batteryRing(Battery(percent: 50, charging: false, lowPower: true)) == (0.5, .yellow))
    #expect(batteryRing(Battery(percent: 50, charging: true, lowPower: true)) == (0.5, .yellow))   // il Risparmio vince sulla carica
    #expect(batteryRing(Battery(percent: 100, charging: false)) == (1, .white))
    #expect(batteryRing(nil) == (0, .white))
}

// I quattro pallini sono la forza del Wi‑Fi: acceso ma non collegato, spento o senza Wi‑Fi nessuno.
@Test func theDotsAreTheWiFiSignal() {
    #expect([0, 1, 2, 3].map { wifiDots(WiFi(on: true, bars: $0, vpn: false)) } == [0, 2, 3, 4])
    #expect(wifiDots(WiFi(on: false, bars: 3, vpn: false)) == 0 && wifiDots(nil) == 0)
}

// Ora, batteria e Wi‑Fi non sono più sezioni (spec §2): i loro token si perdono, il resto resta com'è.
@Test func clockBatteryAndWiFiAreNoLongerSections() {
    #expect(["clock", "battery", "wifi"].flatMap(upgradeToken).compactMap(BarItem.init).isEmpty)
    #expect(upgradeToken("nowPlaying") == ["nowPlaying"])
}

// Spec dock-contenitori §7 e impostazioni-nel-dock §7: se ora, batteria o Wi‑Fi erano accese nelle zone di prima, lo Stato
// parte acceso, come Dock suo; senza, spento. Una scelta salvata (la vecchia chiave) vince. Poi decidono solo i Dock: spento,
// le zone di prima non lo riaccendono.
@Test func theStatusStartsOnWhereThosePillsWere() {
    func start(zones: [String: [String]]? = nil, saved: Bool? = nil) -> Bool {
        let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
        if let zones { d.set(zones, forKey: "dockduo.side.zones") }
        if let saved { d.set(saved, forKey: "dockduo.statusElement") }
        let on = Settings(defaults: d).isOn(.status)
        #expect(Settings(defaults: d).isOn(.status) == on)
        Settings(defaults: d).removeSection(.widget(.status))
        #expect(!Settings(defaults: d).isOn(.status))
        return on
    }
    #expect(start(zones: ["top": ["nowPlaying", "battery"]]))
    #expect(!start(zones: ["top": ["dock"]]) && !start())
    #expect(!start(zones: ["top": ["clock"]], saved: false) && start(saved: true))
}

// Decisione 5: lo Stato nel suo Dock è l'elemento di prima, libero sullo sfondo come l'iPhone Duo: niente capsula, vetro o
// linee. Il Dock dello Stato e l'elemento da solo, uno accanto all'altro nella stessa finestra mai mostrata (così con la
// stessa ora): gli stessi pixel, e non vuoti.
@MainActor @Test func theStatusDockIsTheFreeStatusElement() throws {
    _ = NSApplication.shared
    let (d, name) = fresh(); defer { d.removePersistentDomain(forName: name) }
    let state = BarState()
    (state.battery, state.wifi) = (Battery(percent: 74, charging: false), WiFi(on: true, bars: 2, vpn: false))
    let icons = IconDragHooks(target: nil, dragging: nil, onDrag: { _, _, _, _ in }, onDrop: { _ in }, pillFrame: { _, _ in })
    let box = DockBox(zone: .top, sections: [.widget(.status)])
    let view = HStack(spacing: 0) {
        DockBoxView(box: box, state: state, side: .left, icons: icons, settings: Settings(defaults: d)).frame(width: 52, height: 60)
        StatusElement(state: state, side: .left).frame(width: 52, height: 60)
    }
    .environment(\.barScale, 52 / 38).modifier(SideLook())
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let bytes = try #require(rep.bitmapData), half = rep.pixelsWide / 2 * rep.bitsPerPixel / 8
    let rows = (0..<rep.pixelsHigh).map { bytes + $0 * rep.bytesPerRow }
    let left = rows.flatMap { Array(UnsafeBufferPointer(start: $0, count: half)) }
    let right = rows.flatMap { Array(UnsafeBufferPointer(start: $0 + half, count: half)) }
    #expect(left == right && left.contains { $0 != 0 })
    withExtendedLifetime(window) {}
}

// La prova a occhio (STATUS_SHOT=cartella): a 2×, a barra 52, l'elemento sul fondo del riferimento, il ritaglio
// dell'iPhone Duo alla stessa grandezza d'icona (le 131,25 px del suo Dock = le nostre 31: il ritaglio è la home × 2,536),
// poi su uno sfondo chiaro e su uno scuro; batteria al 74 % e tre pallini, come nel riferimento. Da confrontare pixel per
// pixel. Sotto, sullo scuro, gli altri stati: in carica, sotto il 20 %, Risparmio energetico, Wi‑Fi spento, senza rete, VPN,
// senza batteria. Disegna AppKit in una finestra mai mostrata, per la scala dello schermo.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["STATUS_SHOT"] != nil)) func statusShot() throws {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STATUS_SHOT"]!)
    let reference = try #require(NSImage(contentsOfFile: NSHomeDirectory() + "/Git/siigil-docs/dockduo/riferimenti/iphone-duo-stato.png"))
    func bar(_ battery: Battery?, _ wifi: WiFi?) -> BarState {
        let state = BarState()
        (state.battery, state.wifi) = (battery, wifi)
        return state
    }
    let like = bar(Battery(percent: 74, charging: false), WiFi(on: true, bars: 2, vpn: false))
    let twoFiftyNine = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 2, minute: 59))!
    let k: CGFloat = 31 / (131.25 * 2.536)   // da pixel del ritaglio a punti
    func panel(_ state: BarState, _ r: Double, _ g: Double, _ b: Double) -> some View {
        StatusElement(state: state, fixedTime: twoFiftyNine).padding(.top, 12)
            .frame(width: 52, height: 70, alignment: .top).background(Color(red: r / 255, green: g / 255, blue: b / 255))
    }
    let wifi = WiFi(on: true, bars: 3, vpn: false)
    let states = [bar(Battery(percent: 100, charging: true), wifi), bar(Battery(percent: 15, charging: false), wifi),
                  bar(Battery(percent: 50, charging: false, lowPower: true), wifi), bar(Battery(percent: 74, charging: false), WiFi(on: false, bars: 0, vpn: false)),
                  bar(Battery(percent: 74, charging: false), WiFi(on: true, bars: 0, vpn: false)), bar(Battery(percent: 74, charging: false), WiFi(on: true, bars: 1, vpn: true)),
                  bar(nil, wifi)]
    let view = VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 0) {
            panel(like, 159, 177, 189)
            Image(nsImage: reference).resizable().interpolation(.high).frame(width: 558 * k, height: 660 * k).frame(width: 52, height: 70)
                .background(Color(red: 159 / 255, green: 177 / 255, blue: 189 / 255))
            panel(like, 226, 220, 208)
            panel(like, 20, 22, 30)
        }
        HStack(spacing: 0) { ForEach(states.indices, id: \.self) { panel(states[$0], 20, 22, 30) } }
    }
    .environment(\.barScale, 52 / 38)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    try #require(rep.pixelsWide == Int(host.bounds.width) * 2, "serve uno schermo a 2×")
    host.cacheDisplay(in: host.bounds, to: rep)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("status.png"))
}
