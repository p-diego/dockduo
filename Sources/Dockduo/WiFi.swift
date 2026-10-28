import AppKit
import CoreLocation
import CoreWLAN
import Foundation

// Wi-Fi da CoreWLAN, API pubblica: acceso, collegato e segnale senza permessi; il nome della rete (ssid) solo con la
// Posizione (vedi il menu in Views/Widgets.swift). VPN e traffico dalle interfacce di rete (getifaddrs), senza permessi.

// ponytail: soglie stimate (barik usa -50/-70); tarare guardando l'icona Wi-Fi di macOS accanto alla nostra.
func wifiBars(rssi: Int) -> Int { rssi >= -60 ? 3 : rssi >= -70 ? 2 : 1 }

func readWiFi() -> WiFi? {
    guard let i = CWWiFiClient.shared().interface() else { return nil }
    let connected = i.interfaceMode() == .station
    return WiFi(on: i.powerOn(), bars: connected ? wifiBars(rssi: i.rssiValue()) : 0, vpn: vpnActive(interfaces()))
}

// Stato della rete per il menu aperto (Views/Widgets.swift), riletto ogni secondo: nome, lucchetto e traffico si
// aggiornano senza riaprirlo. Il nome della rete c'è solo con la Posizione concessa (altrimenti CoreWLAN dà nil); la
// scheda (en0) dà l'IP interno e i contatori del traffico.
// ponytail: che SwiftUI ridisegni le righe mentre il menu è in tracking non è documentato (verificato su macOS 27 il
// 2026-09-23: il traffico cambia a menu aperto); se un macOS futuro smette, le righe restano ferme fino alla riapertura.
@Observable final class WiFiMenuModel {
    var on = false
    var connected = false
    var name: String?
    var secure = false
    var traffic: String?   // "↓ 2,4 MB/s   ↑ 120 KB/s", dalla seconda lettura in poi
    var localIP: String?
    var publicIP: String?   // arriva dalla rete dopo l'apertura: la riga si aggiorna come il traffico
    private var last: (bytes: (received: UInt32, sent: UInt32), time: Date)?

    func refresh() {
        let i = CWWiFiClient.shared().interface(), security = i?.security() ?? .unknown
        on = i?.powerOn() ?? false
        connected = i?.interfaceMode() == .station
        name = i?.ssid()
        secure = security != .none && security != .unknown
        localIP = i?.interfaceName.flatMap(localIPv4(interface:))
        guard connected, let interface = i?.interfaceName, let now = interfaceBytes(interface) else {
            last = nil
            traffic = nil
            return
        }
        let time = Date()
        if let last {
            let seconds = time.timeIntervalSince(last.time)
            let down = rateString(byteRate(from: last.bytes.received, to: now.received, seconds: seconds))
            let up = rateString(byteRate(from: last.bytes.sent, to: now.sent, seconds: seconds))
            traffic = "↓ \(down)   ↑ \(up)"
        }
        last = (now, time)
    }
}

// Accende o spegne la scheda: CoreWLAN, nessun permesso, salvo che Impostazioni di Rete chieda la password
// dell'amministratore per il Wi-Fi. Fuori dal main; un errore è un beep. L'icona la aggiornano gli eventi CoreWLAN.
func setWiFiPower(_ on: Bool) {
    DispatchQueue.global().async {
        do { try CWWiFiClient.shared().interface()?.setPower(on) } catch { DispatchQueue.main.async { NSSound.beep() } }
    }
}

// VPN attiva: un tunnel (utun, ipsec, ppp) con un indirizzo IPv4. I tunnel di sistema di macOS 27 (utun0…8:
// Continuity, iCloud) hanno solo IPv6; NordVPN (utun9, 10.5.0.2) e Tailscale collegato (100.x) ne hanno uno.
// ponytail: euristica, una VPN solo IPv6 non si vede; il nome della VPN non si ricava.
func vpnActive(_ interfaces: [(name: String, ipv4: Bool)]) -> Bool {
    interfaces.contains { i in i.ipv4 && ["utun", "ipsec", "ppp"].contains { i.name.hasPrefix($0) } }
}

// Percorre gli indirizzi delle interfacce (getifaddrs): `each` legge ciò che serve prima che la lista sia liberata.
private func eachInterface<T>(_ each: (ifaddrs) -> T?) -> [T] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    return sequence(first: first) { $0.pointee.ifa_next }.compactMap { each($0.pointee) }
}

// Un elemento per indirizzo di ogni interfaccia: nome e se è IPv4.
func interfaces() -> [(name: String, ipv4: Bool)] {
    eachInterface { (String(cString: $0.ifa_name), $0.ifa_addr?.pointee.sa_family == UInt8(AF_INET)) }
}

// L'indirizzo IPv4 di un'interfaccia (l'IP interno del menu Wi-Fi). getifaddrs, nessun permesso.
func localIPv4(interface: String) -> String? {
    eachInterface { i -> String? in
        guard String(cString: i.ifa_name) == interface, i.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }.first
}

// L'IP pubblico, da ipify (testo nudo, https): si chiede all'apertura del menu, con 5 minuti di memoria — una
// richiesta fuori casa a ogni apertura sarebbe sprecata. La memoria vale per una rete (`key`, l'IP locale): cambi
// rete o VPN e si rilegge subito, proprio quando serve (review 4/10). Il completamento arriva sul main.
private var publicIPMemo: (at: Date, key: String?, ip: String)?
func publicIP(key: String?, _ done: @escaping (String?) -> Void) {
    if let memo = publicIPMemo, memo.key == key, Date().timeIntervalSince(memo.at) < 300 { return done(memo.ip) }
    var req = URLRequest(url: URL(string: "https://api.ipify.org")!)
    req.timeoutInterval = 5
    URLSession.shared.dataTask(with: req) { data, _, _ in
        let ip = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { ip in
            ip.count <= 45 && !ip.isEmpty ? ip : nil   // un errore HTML non deve finire nel menu
        }
        DispatchQueue.main.async {
            if let ip { publicIPMemo = (Date(), key, ip) }
            done(ip)
        }
    }.resume()
}

// Byte ricevuti e inviati dalla scheda, dai suoi dati di collegamento (AF_LINK). I contatori sono a 32 bit.
func interfaceBytes(_ name: String) -> (received: UInt32, sent: UInt32)? {
    eachInterface { i -> (received: UInt32, sent: UInt32)? in
        guard String(cString: i.ifa_name) == name, i.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
              let data = i.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { return nil }
        return (data.ifi_ibytes, data.ifi_obytes)
    }.first
}

// Byte al secondo tra due letture. Sottrazione modulare: se il contatore a 32 bit riparte da zero nel mezzo il
// risultato resta giusto (basta che tra le due letture passino meno di 4 GB).
func byteRate(from old: UInt32, to new: UInt32, seconds: Double) -> Double {
    seconds > 0 ? Double(new &- old) / seconds : 0
}

// "2,4 MB/s" nella lingua di sistema; sotto il kilobyte "0 KB/s", come Stats (non "Zero KB" né "207 bytes").
private let rateFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    f.allowedUnits = [.useKB, .useMB, .useGB]
    return f
}()
func rateString(_ bytesPerSecond: Double) -> String { rateFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s" }

// Eventi CoreWLAN (acceso/spento, collegamento, qualità del segnale). Arrivano su un thread di CoreWLAN: `onChange`
// gira sul main. Il delegate di CWWiFiClient è weak: chi crea WiFiEvents lo tiene vivo (il Poller).
final class WiFiEvents: NSObject, CWEventDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        let client = CWWiFiClient.shared()
        client.delegate = self
        for event in [CWEventType.powerDidChange, .linkDidChange, .linkQualityDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { DispatchQueue.main.async(execute: onChange) }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { DispatchQueue.main.async(execute: onChange) }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        DispatchQueue.main.async(execute: onChange)
    }
}

// Posizione, solo per il nome della rete: si chiede dal menu, dalle opzioni dello Stato o dal Benvenuto, mai all'avvio. Globale lazy,
// creata sul main all'avvio (main.swift; CLLocationManager vuole un thread con run loop): crearla non chiede niente.
let locationManager = CLLocationManager()

// Mai chiesta → la richiesta di macOS; negata → la pagina Privacy di Impostazioni di Sistema.
func requestLocation() {
    if locationManager.authorizationStatus == .notDetermined {
        locationManager.requestWhenInUseAuthorization()
    } else {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    }
}

// La Posizione si legge sul main (CLLocationManager). Vale "manca" anche se negata: la riga resta e il pulsante porta
// alle Impostazioni (requestLocation distingue i due casi).
func locationMissing() -> Bool {
    ([.notDetermined, .denied, .restricted] as [CLAuthorizationStatus]).contains(locationManager.authorizationStatus)
}
