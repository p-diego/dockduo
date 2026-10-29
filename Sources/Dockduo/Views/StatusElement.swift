import SwiftUI

// Lo Stato (spec dock-contenitori §4): ora, batteria e Wi‑Fi nel loro Dock (di partenza in cima alla barra), libero sullo
// sfondo e senza capsula, uguale a quello dell'iPhone Duo (autore, 25/10; spec impostazioni-nel-dock, decisione 5).
// L'anello è la batteria, il simbolo al centro il Wi‑Fi (collegato, senza rete o spento), i pallini, che sull'iPhone sono
// il segnale del telefono, la forza del Wi‑Fi. Click sull'ora = quello che faceva l'Orologio; tasto destro su tutto
// l'elemento = un menu solo con batteria e reti (StatusMenuView); click sull'anello: niente. Sta nel pannello della barra:
// si nasconde con lei.
//
// Le misure dell'iPhone Duo, lette il 25/10 su riferimenti/iphone-duo-home.jpeg, dove le icone del suo Dock sono larghe
// 131,25 px (le 31 del nostro Dock a barra 52), e sul ritaglio iphone-duo-stato.png (la home × 2,536), a metà fra fondo e
// bianco. In punti a barra 52, in scala con la barra come il Dock (dockUnit × barScale):
//   - l'ora: SF Pro Rounded grassetto, cifre a larghezza fissa, alte 7,33 (31,1 px: la cima piatta del 5 a 310,8, la base
//     del 2 a 341,9), quindi corpo 10,4; larga 21,9. Spaziatura -0,5: a corpo così piccolo SF allarga da sé le lettere
//     (sull'iPhone l'ora è più grande e non lo fa); con -0,5 i quattro glifi cadono sulle colonne della home entro 0,12.
//     Sta 0,4 a sinistra del centro dell'anello (1,6 px nella home, 3,5 nel ritaglio), che è quello del suo Dock;
//   - 7,3 dalla base dell'ora alla cima dell'anello (30,9 px);
//   - l'anello: largo 26,45 fuori (112 px, da 1167,9 a 1279,9), tratto 2,13 (9 px), aperto in basso fra ±60° dal fondo
//     (240° di arco, estremità tonde); la parte piena bianca, dritta dove finisce, il resto bianco al 25 % (190,198,206 su
//     169,179,188);
//   - il Wi‑Fi: il simbolo di sistema grassetto, grande come l'ora (largo 11,6, alto 8,7, archi da 1,7), al centro dell'anello;
//   - quattro pallini da 2,6 (28 px nel ritaglio) a 12,3 dal centro dell'anello, a ±10,4° e ±31,2° dal fondo; quelli spenti
//     bianchi al 25 %, come l'anello;
//   - l'ombra: sul fondo della home si vede appena, 2-5 livelli più scuro accanto ai tratti, sparita in 2 punti: nera al
//     10 %, raggio 1,5.
private let timeSize: CGFloat = 10.4, timeTracking: CGFloat = -0.5, timeShift: CGFloat = -0.4, timeToRing: CGFloat = 7.3
private let ringSize: CGFloat = 26.45, ringLine: CGFloat = 2.13, ringOpen = 60.0   // gradi dal fondo, per lato
private let dotSize: CGFloat = 2.6, dotDistance: CGFloat = 12.3, dotStep = 20.8   // gradi fra un pallino e l'altro

// Il colore della parte piena dell'anello.
enum RingColor {
    case white, green, red, yellow
    var color: Color { switch self { case .white: .white; case .green: .green; case .red: .red; case .yellow: .yellow } }
}

// L'anello come la batteria di iOS: pieno quanto la carica; giallo col Risparmio energetico, anche in carica (un Mac lo
// tiene anche alla corrente), verde in carica, rosso sotto il 20 % senza carica. Un Mac senza batteria: vuoto.
func batteryRing(_ b: Battery?) -> (fill: Double, color: RingColor) {
    guard let b else { return (0, .white) }
    return (Double(b.percent) / 100, b.lowPower ? .yellow : b.charging ? .green : b.percent < 20 ? .red : .white)
}

// I pallini pieni, su quattro: le tre tacche del Wi‑Fi più uno. Acceso ma non collegato, spento o senza Wi‑Fi: nessuno.
func wifiDots(_ w: WiFi?) -> Int {
    guard let w, w.on else { return 0 }
    return [0, 2, 3, 4][min(max(w.bars, 0), 3)]
}

struct StatusElement: View {
    let state: BarState
    var side = Side.left   // dove sta il bordo dello schermo (il mezzo punto verso di lui)
    var fixedTime: Date? = nil   // la prova a occhio accanto al riferimento: le 2:59
    @Environment(\.barScale) private var scale

    var body: some View {
        let u = dockUnit * scale
        // L'ora sopra l'anello, con la base delle cifre timeToRing sopra la sua cima.
        ZStack(alignment: Alignment(horizontal: .center, vertical: .firstTextBaseline)) {
            TimelineView(.everyMinute) { context in
                // H:MM come l'impostazione 12/24 ore del Mac, senza AM/PM.
                Text((fixedTime ?? context.date).formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.system(size: timeSize * u, weight: .bold, design: .rounded).monospacedDigit())
                    .tracking(timeTracking * u)
                    .offset(x: timeShift * u)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: context.date)
            }
            .contentShape(Rectangle())
            // Come l'Orologio: l'app scelta nelle impostazioni (ClockApp.swift).
            .onTapGesture { toggleApp(bundle: Settings.shared.clockApp) }
            ring(u).alignmentGuide(.firstTextBaseline) { $0[.top] - timeToRing * u }
                .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
        }
        .accessibilityElement(children: .combine)   // VoiceOver: l'ora, poi batteria e Wi‑Fi
        .foregroundStyle(.white)
        .environment(\.palette, nil)   // bianco anche col Mac in chiaro: sta sullo sfondo, non su una pillola
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 1.5 * u)
        .overlay(MenuAnchor { StatusMenuView() })
        // Sulla colonna del Dock, come sull'iPhone: mezzo punto verso il bordo dello schermo, come la sua capsula (DockBoxView).
        .offset(side.towardEdge(0.5 * u))
        .animation(.smooth(duration: 0.3), value: state.battery)
        .animation(.smooth(duration: 0.3), value: state.wifi)
    }

    // Quello che l'anello, il simbolo e i pallini dicono a vista.
    private var spoken: String {
        let battery = state.battery.map { b in
            b.charging ? String(localized: "Battery \(b.percent)%, charging") : String(localized: "Battery \(b.percent)%")
        }
        let wifi = state.wifi?.on != true ? String(localized: "Wi-Fi off")
            : state.wifi?.bars == 0 ? String(localized: "Wi-Fi not connected") : String(localized: "Wi-Fi connected")
        return [battery, wifi].compactMap { $0 }.joined(separator: ", ")
    }

    // L'anello nel suo quadrato, col Wi‑Fi al centro e i pallini nell'apertura, che scendono sotto il quadrato.
    private func ring(_ u: CGFloat) -> some View {
        let battery = batteryRing(state.battery), dots = wifiDots(state.wifi)
        let line = StrokeStyle(lineWidth: ringLine * u, lineCap: .round), radius = (ringSize - ringLine) / 2 * u
        return ZStack {
            OpenRing(radius: radius).stroke(.white.opacity(0.25), style: line)
            OpenRing(radius: radius).stroke(battery.color.color, style: line)
                .mask(RingFill(fill: battery.fill, radius: radius, line: ringLine * u))
            WiFiGlyph(wifi: state.wifi).environment(\.barScale, timeSize * u / 14)
            ForEach(0..<4, id: \.self) { i in
                Dot(angle: (Double(i) - 1.5) * dotStep, distance: dotDistance * u, size: dotSize * u).fill(.white.opacity(i < dots ? 1 : 0.25))
            }
        }
        .frame(width: ringSize * u, height: ringSize * u)
        .frame(height: (ringSize / 2 + dotDistance * cos(dotStep / 2 * .pi / 180) + dotSize / 2) * u, alignment: .top)
    }
}

// L'arco dell'anello a metà del tratto, dal fondo a sinistra al fondo a destra passando per la cima. Il raggio è dato, non
// preso dalla cornice: SwiftUI la porta ai pixel interi e l'anello si stringeva di mezzo punto (26 invece di 26,45).
private struct OpenRing: Shape {
    let radius: CGFloat
    func path(in r: CGRect) -> Path {
        Path { $0.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: radius,
                         startAngle: .degrees(90 + ringOpen), endAngle: .degrees(450 - ringOpen), clockwise: false) }
    }
}

// La parte piena: la frazione `fill` dell'anello come si vede, estremità tonde comprese (a 0 niente, a 1 tutto), dritta dove
// finisce, come sull'iPhone. Uno spicchio dal centro, che fa da maschera; si anima.
private struct RingFill: Shape {
    var fill: Double
    let radius: CGFloat, line: CGFloat
    var animatableData: Double { get { fill } set { fill = newValue } }
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), cap = asin(line / 2 / radius) * 180 / .pi   // l'estremità tonda, in gradi
        let start = 90 + ringOpen - cap, span = (360 - 2 * ringOpen + 2 * cap) * min(max(fill, 0), 1)
        return Path { p in
            p.move(to: c)
            p.addArc(center: c, radius: 2 * radius, startAngle: .degrees(start), endAngle: .degrees(start + span), clockwise: false)
            p.closeSubpath()
        }
    }
}

// Un pallino nell'apertura, `angle` gradi dal fondo (a sinistra i negativi). Una forma e non un cerchio con la sua cornice,
// per la stessa ragione dell'anello: al punto esatto.
private struct Dot: Shape {
    let angle: Double, distance: CGFloat, size: CGFloat
    func path(in r: CGRect) -> Path {
        let a = angle * .pi / 180
        return Path(ellipseIn: CGRect(x: r.midX + distance * sin(a) - size / 2, y: r.midY + distance * cos(a) - size / 2, width: size, height: size))
    }
}

// Il Wi‑Fi al centro dell'anello: collegato; acceso ma senza rete, con le tacche spente come nella menu bar di macOS; spento
// (o senza Wi‑Fi), con la barra e l'animazione del muto (SwitchOffIcon, autore 4/10). Il lucchetto della VPN nell'angolo
// del ventaglio, come nella pillola di prima. Le misure sono quelle della pillola, di un simbolo da 14: chi lo usa dà a
// barScale la grandezza del simbolo diviso 14.
private struct WiFiGlyph: View {
    let wifi: WiFi?
    @Environment(\.barScale) private var scale

    var body: some View {
        SwitchOffIcon(off: wifi?.on != true) { off, slash in
            Image(systemName: "wifi", variableValue: off || (wifi?.bars ?? 0) > 0 ? 1 : 0)
                .font(.system(size: 14 * scale, weight: .bold))
                .modifier(Slashed(progress: slash, from: CGPoint(x: 3.4, y: 0.8), to: CGPoint(x: 15.3, y: 12.7)))
        }
        .overlay(alignment: .bottomTrailing) {
            if wifi?.vpn == true {
                Image(systemName: "lock.fill").font(.system(size: 7 * scale, weight: .bold))
                    .offset(x: 2.5 * scale, y: 1 * scale)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
    }
}
