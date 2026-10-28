import SwiftUI
import AppKit

// Il tasto destro su tutto l'elemento di stato (spec dock-contenitori §4, dalla regola unica dei menu: autore, 4/10): un menu
// solo, la parte della batteria e quella delle reti, i menu di prima uno sotto l'altro (l'anello e il Wi‑Fi sono troppo
// piccoli per due bersagli). Un Mac senza batteria: solo le reti; senza Wi‑Fi: solo la batteria (un interruttore che non
// accende niente no). In fondo Modifica Dock… e Impostazioni…, come ogni menu della barra.
final class StatusMenuView: RightClickMenuView {
    override func pop() {
        let menu = NSMenu()
        if state.battery != nil { addBatteryItems(to: menu) }
        var refresh: (() -> Void)?
        if state.wifi != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            refresh = addNetworkItems(to: menu)
        }
        addEditItems(to: menu, from: self)   // lo Stato è una sezione: in fondo Modifica Dock… come negli altri menu della barra
        popUpFromBar(menu, in: self, refresh: refresh)
    }

    // La batteria: la fonte (coi watt alla corrente), "Battery Settings…". Il Risparmio energetico non si alterna più da qui
    // (autore, 26/10: serviva una scorciatoia da installare); lo dice l'anello giallo, come su iPhone.
    private func addBatteryItems(to menu: NSMenu) {
        let watts = adapterWatts()
        // Come il pannello originale (screenshot dell'autore, 4/10): titolo, la fonte in grigio (da noi anche carica e
        // tempo: scelta dell'autore). Le "app energivore" dell'originale no: le conosce solo un servizio interno di macOS,
        // e l'autore le ha escluse.
        menu.addItem(menuTitle(String(localized: "Battery")))
        // Una riga sola, come l'originale: la fonte, coi watt quando è alla corrente (autore, 4/10; niente carica e
        // tempo: la carica la dice già l'anello).
        let source = watts.map { String(localized: "Power Source: Power Adapter (\($0) W)") } ?? String(localized: "Power Source: Battery")
        menu.addItem(menuLabel(source))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(String(localized: "Battery Settings…"), #selector(openBatterySettings), target: self))
    }

    @objc private func openBatterySettings() { open("x-apple.systempreferences:com.apple.Battery-Settings.extension") }
}

// La barra dei simboli spenti, come quella di macOS (il Wi-Fi spento): un solco
// trasparente largo 2,5 che stacca il simbolo e sopra il tratto da 1,1. `progress` 0...1 è quanto è disegnata,
// dall'alto; Path non interpola, si anima il numero. Punti nel box del simbolo (per il Wi-Fi misurati su wifi.slash di
// sistema il 4/10). Punti e tratti in scala (barScale), come il simbolo.
struct Slashed: ViewModifier, Animatable {
    var progress: Double
    let from: CGPoint, to: CGPoint
    var animatableData: Double { get { progress } set { progress = newValue } }
    @Environment(\.palette) private var palette
    @Environment(\.barScale) private var scale

    func body(content: Content) -> some View {
        let (from, to) = (CGPoint(x: from.x * scale, y: from.y * scale), CGPoint(x: to.x * scale, y: to.y * scale))
        let line = Path { $0.move(to: from); $0.addLine(to: to) }
        let y = from.y + (to.y - from.y) * progress + 1.75 * scale
        let clip = Rectangle().path(in: CGRect(x: -10 * scale, y: -10 * scale, width: 50 * scale, height: 10 * scale + y))
        content
            .overlay {
                if progress > 0 {
                    line.stroke(style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round)).fill(.black).blendMode(.destinationOut).clipShape(clip)
                    line.stroke(style: StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round)).fill(palette.ink).clipShape(clip)
                }
            }
            .compositingGroup()
    }
}

// Scambio d'icona (Wi-Fi spento ↔ acceso): quella che esce si rimpicciolisce e sfuma, quella che entra
// fa il contrario, dopo.
private let iconZoom = AnyTransition.scale(scale: 0.5).combined(with: .opacity)
private let iconSwap = AnyTransition.asymmetric(insertion: iconZoom.animation(.smooth(duration: 0.2).delay(0.2)),
                                                removal: iconZoom.animation(.smooth(duration: 0.2)))

// Spegnere un simbolo come l'altoparlante muto di macOS (autore, 4/10; oggi il Wi-Fi). Spegnendo: l'icona esce e rientra
// quella spenta, poi la barra si disegna dall'alto. Riaccendendo l'inverso: la barra si ritira, poi torna l'icona. `icon` riceve quale icona
// disegnare e quanta barra. Si parte già dallo stato giusto (27/9: all'avvio da muto si vedeva lo scambio animato).
// Un cambio nel frattempo annulla i passi ritardati del precedente.
struct SwitchOffIcon<Icon: View>: View {
    let off: Bool
    let icon: (_ off: Bool, _ slash: Double) -> Icon
    @State private var shownOff: Bool   // quale icona è disegnata: segue `off` attraverso l'animazione
    @State private var slash: Double
    @State private var step: DispatchWorkItem?   // il passo ritardato: un cambio nel frattempo annulla quello del precedente

    init(off: Bool, @ViewBuilder icon: @escaping (_ off: Bool, _ slash: Double) -> Icon) {
        self.off = off
        self.icon = icon
        _shownOff = State(initialValue: off)
        _slash = State(initialValue: off ? 1 : 0)
    }

    var body: some View {
        ZStack { icon(shownOff, slash).id(shownOff).transition(iconSwap) }
            .onChange(of: off) { _, now in animate(toOff: now) }
    }

    private func animate(toOff: Bool) {
        if toOff {
            slash = 0
            withAnimation { shownOff = true }
            debounce(&step, after: 0.35) { withAnimation(.easeOut(duration: 0.2)) { slash = 1 } }
        } else {
            withAnimation(.easeIn(duration: 0.15)) { slash = 0 }
            debounce(&step, after: 0.15) { withAnimation { shownOff = false } }
        }
    }
}

// L'evidenziazione al passaggio del mouse delle righe cliccabili nostre, come nel pannello del Suono di macOS
// (screenshot dell'autore, 4/10): rettangolo arrotondato chiaro, un filo dentro i bordi del menu.
struct MenuHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hovering ? 0.1 : 0)).padding(.horizontal, 5)   // raggio come l'originale (autore, 4/10)
            }
            .onHover { hovering = $0 }
    }
}

// "In riproduzione" (NowPlaying.swift): copertina arrotondata (o la nota, finché non arriva); il titolo non sta nella
// pillola ed esce di lato (spec barra-di-lato §4). Click = pausa/riprendi; tasto destro = menu con copertina grande,
// brano, artista, comandi e "Apri <lettore>".
struct NowPlayingView: View {
    let track: Track
    let artwork: NSImage?
    @Environment(\.palette) private var palette
    @Environment(\.barScale) private var scale

    var body: some View {
        HStack(spacing: 5 * scale) {
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high)
                    .frame(width: 16 * scale, height: 16 * scale).clipShape(RoundedRectangle(cornerRadius: 3 * scale))
            } else {
                Image(systemName: "music.note").font(.system(size: 12 * scale, weight: .medium)).foregroundStyle(palette.ink)
            }
        }
        .padding(.vertical, 2 * scale)
        .pill()
        .overlay(MenuAnchor { NowPlayingMenuView() })   // tasto destro, regola unica dei menu
        .onTapGesture { NowPlaying.command("playpause") }
        .sideLabel(id: "nowPlaying", text: track.playing ? track.title : nil, style: .glass)
    }

}

// Menu del brano: copertina grande con titolo e artista, i tre comandi, "Apri …".
final class NowPlayingMenuView: RightClickMenuView {
    override func menu() -> NSMenu {
        let menu = NSMenu()
        guard let track = state.track else { return menu }
        // Copertina grande con titolo e artista sotto (default); compatta dalle impostazioni del widget (autore, 4/10).
        // Menu più stretto dei nostri (240 contro 280), con la copertina che lo riempie (autore, 4/10).
        // Le righe leggono lo stato da sole: il menu resta aperto sui comandi (autore, 4/10) e brano, copertina e
        // pausa/riprendi si aggiornano mentre è aperto — cambiano le viste dentro le righe, mai il menu stesso.
        if Settings.shared.bigArtwork {
            menu.addItem(menuViewItem(NSHostingView(rootView: BigTrackRow()), height: 258, width: 240))
        } else {
            menu.addItem(menuViewItem(NSHostingView(rootView: TrackRow()), height: 56, width: 240))
        }
        menu.addItem(.separator())
        menu.addItem(menuViewItem(NSHostingView(rootView: PlayerControlsRow()), height: 36, width: 240))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(String(localized: "Open \(track.player.rawValue)"), #selector(openPlayerItem), target: self))
        addEditItems(to: menu, from: self)   // il tasto destro in un Dock ha sempre in fondo Modifica Dock… e le impostazioni
        return menu
    }

    @objc private func openPlayerItem() {
        if let bundle = state.track?.player.bundle { open("-b", bundle) }
    }
}

// Copertina grande con titolo e artista sotto, come il mini-player di Music: la testata di default del menu.
// Legge lo stato da sola (niente istantanee): col menu aperto brano e copertina restano aggiornati.
struct BigTrackRow: View {
    var body: some View {
        // Copertina a tutta larghezza del menu, testi a sinistra, menu un filo più stretto (autore, 4/10).
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let artwork = state.artwork { Image(nsImage: artwork).resizable().interpolation(.high) }
                else {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                        .overlay { Image(systemName: "music.note").font(.system(size: 42)).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 212, height: 212).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.track?.title ?? "").font(.system(size: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold)).lineLimit(1)
                Text(state.track?.artist ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 212, alignment: .leading)
        .padding(.horizontal, menuInset)   // gli stessi margini degli altri nostri menu (autore, 4/10)
        .padding(.top, 6)
    }
}

// Copertina 48 pt, titolo e artista: la testata compatta del menu del brano. Anche lei legge lo stato da sola.
struct TrackRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork = state.artwork { Image(nsImage: artwork).resizable().interpolation(.high) }
                else { Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(.secondary) }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.track?.title ?? "").font(.system(size: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold)).lineLimit(1)
                Text(state.track?.artist ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, menuInset)
    }
}

// Indietro, pausa/riprendi, avanti: come il mini-player di macOS — pausa/riprendi più grande al centro, salti più
// piccoli, cerchio chiaro al passaggio (autore, 4/10: "i comandi non sembrano molto Apple"). Il menu NON si chiude
// sui comandi, come negli altri nostri menu (autore, 4/10): l'icona pausa/riprendi si aggiorna leggendo lo stato.
struct PlayerControlsRow: View {
    var body: some View {
        HStack(spacing: 22) {
            CircleHoverControl(symbol: "backward.fill", size: 13) { NowPlaying.command("previous track") }
            CircleHoverControl(symbol: state.track?.playing == true ? "pause.fill" : "play.fill", size: 19) { NowPlaying.command("playpause") }
            CircleHoverControl(symbol: "forward.fill", size: 13) { NowPlaying.command("next track") }
        }
        .frame(maxWidth: .infinity)
    }
}

// Un simbolo con il cerchio chiaro al passaggio, come i controlli nativi.
struct CircleHoverControl: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol).font(.system(size: size, weight: .medium))
            .frame(width: 34, height: 34)
            .background { Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)) }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

// Le reti nel menu dell'elemento di stato, sul modello del menu del Wi-Fi di macOS: "Wi-Fi" con l'interruttore, la rete
// (cerchio blu, nome, lucchetto se protetta, traffico sotto il nome), gli IP, la VPN, "Wi-Fi Settings…". Dà al menu aperto
// la rilettura di ogni secondo.
extension StatusMenuView {
    private func addNetworkItems(to menu: NSMenu) -> () -> Void {
        // Prima locationManager: crea il CLLocationManager nel processo, altrimenti ssid() dà nil anche con
        // Posizione autorizzata (nessun CLLocationManager esisteva ancora per dare il nome alla rete).
        let status = locationManager.authorizationStatus
        let model = WiFiMenuModel()
        model.refresh()
        let vpn = vpnActive(interfaces())

        var wifiOnly: [NSMenuItem] = []   // spariscono a Wi-Fi spento, come nel menu di macOS
        let separator = NSMenuItem.separator()
        let toggle = MenuSwitchRow(title: String(localized: "Wi-Fi"), on: model.on) { on in
            setWiFiPower(on)
            wifiOnly.forEach { $0.isHidden = !on }
            separator.isHidden = !on && !vpn
        }
        menu.addItem(menuViewItem(toggle, height: 32))
        menu.addItem(.separator())
        // Niente intestazione "Known Network": mostriamo una rete sola, il titolo di sezione era rumore (autore, 4/10).
        wifiOnly.append(menuViewItem(NSHostingView(rootView: NetworkRow(model: model)), height: 40))
        // Gli IP, un click li copia (autore, 4/10). Quello pubblico arriva dalla rete: la riga si riempie da sola.
        // Solo a Wi-Fi acceso (le righe altrimenti sono nascoste), con l'IP locale a far da chiave di rete del memo.
        if model.on { Dockduo.publicIP(key: model.localIP) { model.publicIP = $0 ?? "—" } }
        wifiOnly.append(.separator())
        wifiOnly.append(menuViewItem(NSHostingView(rootView: IPRow(label: String(localized: "Internal IP"), value: { model.localIP })), height: 28))
        wifiOnly.append(menuViewItem(NSHostingView(rootView: IPRow(label: String(localized: "Public IP"), value: { model.publicIP })), height: 28))
        // Senza Posizione il nome della rete non c'è: la voce che la chiede, sotto la riga della rete.
        if model.connected, model.name == nil {
            let title = status == .notDetermined ? String(localized: "Show network name…") : String(localized: "Allow Location in System Settings…")
            wifiOnly.append(NSMenuItem(title, #selector(askLocation), target: self))
        }
        wifiOnly.forEach { menu.addItem($0); $0.isHidden = !model.on }
        // Anche a Wi-Fi spento (VPN su Ethernet): il lucchetto sull'icona deve trovare la sua spiegazione qui.
        if vpn { menu.addItem(menuViewItem(NSHostingView(rootView: VPNRow()), height: 40)) }
        separator.isHidden = !model.on && !vpn
        menu.addItem(separator)
        menu.addItem(NSMenuItem(String(localized: "Wi-Fi Settings…"), #selector(openWiFiSettings), target: self))
        return model.refresh
    }

    @objc private func askLocation() { requestLocation() }
    @objc private func openWiFiSettings() { open("x-apple.systempreferences:com.apple.wifi-settings-extension") }
}

// Righe del menu Wi-Fi fatte a mano (NSMenuItem.view): testo allineato alle voci normali (14 pt dal bordo), larghezza
// del menu di macOS. Le righe hanno altezza fissa e cambiano solo dentro: un menu che cambia misura mentre è aperto si
// impagina male (nascondere o mostrare voci intere invece lo rifà bene, provato il 2026-09-23).
let menuInset: CGFloat = 14
let menuRowWidth: CGFloat = 280

// Una riga di menu fatta con una vista (SwiftUI via NSHostingView): stessa larghezza per tutti i menu di dockduo.
// Voce di menu con l'azione e il suo bersaglio in un colpo solo: senza target la voce resta grigia, e i cinque menu
// lo impostavano a mano (audit 3/10).
extension NSMenuItem {
    convenience init(_ title: String, _ action: Selector, target: AnyObject) {
        self.init(title: title, action: action, keyEquivalent: "")
        self.target = target
    }
}

func menuViewItem(_ view: NSView, height: CGFloat, width: CGFloat = menuRowWidth) -> NSMenuItem {
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    view.autoresizingMask = .width
    let i = NSMenuItem()
    i.view = view
    return i
}

// Una riga di solo testo nei nostri menu (titoli, intestazioni, righe grigie): la stessa forma, cambiano corpo, peso,
// colore e altezza (review 4/10: era scritta tre volte); di serie la riga grigia. Colori espliciti: il "secondario" di
// SwiftUI nei menu viene spento dalla vibrancy.
func menuLabel(_ text: String, size: CGFloat = NSFont.menuFont(ofSize: 0).pointSize, weight: Font.Weight = .regular,
               opacity: Double = 0.55, height: CGFloat = 22) -> NSMenuItem {
    menuViewItem(NSHostingView(rootView:
        HStack {
            Text(text).font(.system(size: size, weight: weight)).foregroundStyle(Color.primary.opacity(opacity))
            Spacer()
        }.padding(.horizontal, menuInset)
    ), height: height)
}

// Il titolo in grassetto dei pannelli (Batteria): misure dagli screenshot a confronto con l'originale (4/10), 14 semibold.
func menuTitle(_ text: String) -> NSMenuItem { menuLabel(text, size: 14, weight: .semibold, opacity: 1, height: 28) }

// Un IP col suo nome; un click lo copia negli appunti e la riga risponde "Copiato" per un momento. `value` è una
// chiusura: letta a ogni ridisegno, si riempie quando l'IP pubblico arriva (il menu non si tocca da aperto).
struct IPRow: View {
    let label: String
    let value: () -> String?   // nil = in arrivo ("…"); "—" = lettura fallita, non copiabile (review 4/10)
    @State private var copied = false

    var body: some View {
        let ip = value()
        HStack {
            Text(label).font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
            Spacer()
            Text(copied ? String(localized: "Copied") : (ip ?? "…"))
                .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize, design: copied ? .default : .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, menuInset)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(MenuHover())
        .onTapGesture {
            guard let ip, ip != "—", !copied else { return }   // il tratto del fallimento non si copia
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        }
    }
}

// "Wi-Fi" in grassetto e l'interruttore a grandezza normale, allineato al margine destro come nel menu di macOS. Resta
// grigio: diventa blu solo se dockduo è l'app attiva, e prendersi il primo piano toglierebbe il focus all'app in cui si sta
// lavorando (provato e scartato il 2026-09-23). Cambiarlo non chiude il menu.
final class MenuSwitchRow: NSView {
    private let toggle = NSSwitch()
    private let changed: (Bool) -> Void

    init(title: String, on: Bool, changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: NSRect(x: 0, y: 0, width: menuRowWidth, height: 32))
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: menuInset, y: (frame.height - label.frame.height) / 2)
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: frame.width - menuInset - toggle.frame.width, y: (frame.height - toggle.frame.height) / 2)
        toggle.autoresizingMask = .minXMargin
        addSubview(label)
        addSubview(toggle)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func toggled() { changed(toggle.state == .on) }
}

// Il cerchio colorato col simbolo bianco delle righe del menu Wi-Fi di macOS.
struct MenuRowIcon: View {
    let symbol: String
    let active: Bool
    var size: CGFloat = 26   // 20 nelle voci delle sessioni del menu dell'app, grandi come le icone della barra
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 12 / 26, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? Color(nsColor: .controlAccentColor) : Color.gray.opacity(0.5)))
    }
}

// La rete: cerchio blu da collegata, nome (o "Connected" senza Posizione), traffico sotto, lucchetto se protetta.
private struct NetworkRow: View {
    let model: WiFiMenuModel
    var body: some View {
        HStack(spacing: 8) {
            MenuRowIcon(symbol: "wifi", active: model.connected)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.connected ? model.name ?? String(localized: "Connected") : String(localized: "Not connected"))
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                if let traffic = model.traffic {
                    Text(traffic).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.connected, model.secure {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, menuInset)
    }
}

private struct VPNRow: View {
    var body: some View {
        HStack(spacing: 8) {
            MenuRowIcon(symbol: "lock.fill", active: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("VPN").font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                Text("Connected").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, menuInset)
    }
}

// L'àncora di un menu in overlay: `make` la crea una volta sola, e SwiftUI la tiene viva quanto la vista (come AppMenu).
struct MenuAnchor: NSViewRepresentable {
    let make: () -> NSView
    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ view: NSView, context: Context) {}
}
