import AppKit
import Foundation
import Security

// Aggiornamento da dentro l'app (spec 2026-09-26-siigil-aggiornamento-design). Le release stanno nel repo pubblico del
// codice, dove le pubblica `make release`. dockduo legge l'ultima, la offre in Impostazioni e in cima al menu della linea
// del Dock e al click scarica, verifica, si sostituisce e si riapre. Sostituzione e riavvio sono stati provati il 26/9 su macOS 26
// con un prototipo usa e getta, anche da una copia passata da "Apri comunque".

let releasesRepo = "p-diego/dockduo"
let latestReleasePage = URL(string: "https://github.com/\(releasesRepo)/releases/latest")!

struct Release: Equatable {
    let version: String   // senza "v"
    let page: URL         // la pagina della release, per "What's New"
    let zip: URL          // dockduo-<version>.zip
}

// Confronto numerico, parte per parte: 0.10 è più nuova di 0.9, 0.12.1 di 0.12. La "v" dei tag non conta.
func isNewer(_ remote: String, than local: String) -> Bool {
    remote.trimmingPrefix("v").compare(local.trimmingPrefix("v"), options: .numeric) == .orderedDescending
}

// Il JSON di GitHub (releases/latest): numero senza "v", pagina e zip dockduo-<numero>.zip. Nil se manca uno dei tre, se
// il JSON è rotto o se è la risposta di un errore ({"message": "Not Found"} quando il repo non ha ancora release).
func parseRelease(_ data: Data) -> Release? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let tag = json["tag_name"] as? String,
          let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
          let assets = json["assets"] as? [[String: Any]] else { return nil }
    let version = String(tag.trimmingPrefix("v"))
    guard let asset = assets.first(where: { $0["name"] as? String == "dockduo-\(version).zip" }),
          let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
    return Release(version: version, page: page, zip: zip)
}

// La risposta di releases/latest: la release, o nil per un 404 (repo privato o ancora senza release), che vale come un
// controllo riuscito senza niente di nuovo (ruling #9, 27/10: prima si riprovava ogni ora per sempre). Altri codici, o una
// release senza lo zip, sono errori.
func latestRelease(code: Int, data: Data) throws -> Release? {
    if code == 404 { return nil }
    guard code == 200 else { throw UpdateError.http(code) }
    guard let release = parseRelease(data) else { throw UpdateError.noRelease }
    return release
}

// Quando ricontrollare: subito se non si è mai provato; 24 ore dopo un controllo riuscito; 1 ora dopo uno fallito
// (niente rete al login, un rifiuto di GitHub, che senza credenziali concede 60 richieste l'ora).
func isDue(last: Date?, succeeded: Bool, now: Date) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= (succeeded ? 24 * 3600 : 3600)
}

// Il riavvio dopo la sostituzione: uno sh aspetta che questo processo esca e poi apre la copia nuova (con la vecchia
// ancora viva, `open` attiverebbe quella). Il percorso passa come $0, così gli spazi non rompono niente.
func relaunchArguments(pid: Int32, app: String) -> [String] {
    ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"", app]
}

enum UpdateError: LocalizedError, Equatable {
    case http(Int), noRelease, notWritable(String), unpack, notNewerApp, signature
    var errorDescription: String? {
        switch self {
        case .http(let code): String(localized: "GitHub answered \(code)")
        case .noRelease: String(localized: "No release with dockduo's zip")
        case .notWritable(let folder): String(localized: "Can't write to \(folder)")
        case .unpack: String(localized: "Can't unpack the download")
        case .notNewerApp: String(localized: "The download isn't a newer dockduo")
        case .signature: String(localized: "The download isn't signed like this copy")
        }
    }
}

// Lo zip in una cartella temporanea, estratto con ditto (come lo crea make dist), poi la verifica: identificativo
// com.dockduo.app, versione più nuova di `current`, e firma che soddisfa il requisito designato della copia che gira
// (stesso certificato Apple Development: un'app ad-hoc o firmata da altri non passa). Bloccante: fuori dal main.
func unpackAndVerify(_ zip: Data, newerThan current: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockduo-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var verified = false
    defer { if !verified { try? FileManager.default.removeItem(at: dir) } }   // un download scartato non resta nel disco
    let file = dir.appendingPathComponent("dockduo.zip")
    try zip.write(to: file)
    guard shell("/usr/bin/ditto", ["-x", "-k", file.path, dir.path], timeout: 60) != nil else { throw UpdateError.unpack }
    let app = dir.appendingPathComponent("dockduo.app")
    guard let info = Bundle(url: app)?.infoDictionary,   // cartella nuova a ogni download: niente cache di Bundle
          info["CFBundleIdentifier"] as? String == "com.dockduo.app",
          let version = info["CFBundleShortVersionString"] as? String, isNewer(version, than: current)
    else { throw UpdateError.notNewerApp }
    var me: SecCode?, meStatic: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
          SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
          SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
          SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new,
          SecStaticCodeCheckValidity(new, [], requirement) == errSecSuccess
    else { throw UpdateError.signature }
    verified = true
    return app
}

// Lo stato dell'aggiornamento, per il menu della linea del Dock e per Impostazioni. `failed` viene solo dall'installazione: un
// controllo fallito lascia lo stato com'è e scrive `checkError` (spec §1).
@Observable @MainActor final class Updater {
    static let shared = Updater()
    enum State: Equatable { case idle, upToDate, available(Release), downloading(Release), failed(String) }
    private(set) var state = State.idle
    private(set) var checkError: String?
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var last: Date?
    private var succeeded = false

    // Solo la copia installata si aggiorna: le build di sviluppo e la copia nel DMG mai.
    var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return inApplications(path) && !launchedFromDiskImage(path)
    }

    // Dal timer al minuto del Poller, come le quote: la rete solo quando è dovuto.
    func checkIfDue() async {
        guard isInstalledCopy, isDue(last: last, succeeded: succeeded, now: Date()) else { return }
        await check()
    }

    // Anche da "Check for Updates…" in Impostazioni.
    func check() async {
        guard isInstalledCopy else { checkError = String(localized: "Only the copy in Applications updates itself"); return }
        last = Date()
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(releasesRepo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let release = try latestRelease(code: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
            succeeded = true
            checkError = nil
            if case .downloading = state { return }   // uno scaricamento in corso non si tocca
            if let release, isNewer(release.version, than: current) { state = .available(release) } else { state = .upToDate }
        } catch {
            succeeded = false
            checkError = error.localizedDescription
            logger.error("aggiornamento, controllo: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Scarica, estrae, verifica, sostituisce, riavvia (come la prova del 26/9). La sostituzione è l'ultimo passo:
    // ogni errore prima lascia la copia installata com'era, e porta al DMG.
    func install() async {
        guard case .available(let release) = state else { return }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else { return fail(UpdateError.notWritable(folder)) }
        state = .downloading(release)
        do {
            let (data, response) = try await URLSession.shared.data(from: release.zip)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.http(code) }
            let version = current
            let new = try await Task.detached { try unpackAndVerify(data, newerThan: version) }.value
            defer { try? FileManager.default.removeItem(at: new.deletingLastPathComponent()) }   // lo zip e la cartella temporanea
            _ = try FileManager.default.replaceItemAt(app, withItemAt: new)
        } catch {
            return fail(error)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = relaunchArguments(pid: getpid(), app: app.path)
        do { try p.run() } catch { return fail(error) }
        NSApp.terminate(nil)
    }

    // Segna anche il controllo come fallito: il prossimo è dovuto dopo un'ora (isDue) invece che fino a 24, e riporta
    // "Update to …" appena c'è di nuovo rete, invece di restare su "Update failed" fino al controllo del giorno dopo.
    private func fail(_ error: Error) {
        logger.error("aggiornamento: \(error.localizedDescription, privacy: .public)")
        last = Date()
        succeeded = false
        state = .failed(error.localizedDescription)
    }
}
