import Foundation
import Testing
@testable import Dockduo

// Numeri, non testo: 0.10 viene dopo 0.9. La "v" dei tag non conta.
@Test func newerComparesNumbersNotText() {
    #expect(isNewer("0.10", than: "0.9"))
    #expect(isNewer("0.12.1", than: "0.12"))
    #expect(isNewer("v0.13", than: "0.12"))
    #expect(isNewer("0.13", than: "v0.12"))
}

@Test func sameOrOlderIsNotNewer() {
    #expect(!isNewer("0.12", than: "0.12"))
    #expect(!isNewer("v0.12", than: "0.12"))
    #expect(!isNewer("0.9", than: "0.10"))
    #expect(!isNewer("0.11", than: "0.12"))
}

// Il JSON di releases/latest ridotto ai campi che servono.
private func releaseJSON(tag: String, assets: [String]) -> Data {
    let list = assets.map { #"{"name": "\#($0)", "browser_download_url": "https://github.com/p-diego/dockduo/releases/download/\#(tag)/\#($0)"}"# }
    return Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/p-diego/dockduo/releases/tag/\#(tag)", "assets": [\#(list.joined(separator: ","))]}"#.utf8)
}

@Test func parsesTheZipAmongTheAssets() {
    let r = parseRelease(releaseJSON(tag: "v0.13", assets: ["dockduo-0.13.dmg", "dockduo-0.13.zip"]))
    #expect(r == Release(version: "0.13",
                         page: URL(string: "https://github.com/p-diego/dockduo/releases/tag/v0.13")!,
                         zip: URL(string: "https://github.com/p-diego/dockduo/releases/download/v0.13/dockduo-0.13.zip")!))
}

// Senza lo zip della sua versione (solo il DMG, o lo zip di un'altra) la release non serve.
@Test func releaseWithoutItsZipIsNil() {
    #expect(parseRelease(releaseJSON(tag: "v0.13", assets: ["dockduo-0.13.dmg"])) == nil)
    #expect(parseRelease(releaseJSON(tag: "v0.13", assets: ["dockduo-0.12.zip"])) == nil)
}

// Rotto, o la risposta di GitHub quando il repo non ha ancora release (404).
@Test func brokenJSONOrGitHubErrorIsNil() {
    #expect(parseRelease(Data("{".utf8)) == nil)
    #expect(parseRelease(Data(#"{"message": "Not Found", "documentation_url": "https://docs.github.com/rest"}"#.utf8)) == nil)
}

// Ruling #9 (27/10): un 404 (repo privato o senza release) è "niente di nuovo", non un errore: si riprova fra 24 ore senza
// riga d'errore. Gli altri codici e una release senza zip restano errori.
@Test func notFoundMeansNoReleaseNotAnError() throws {
    #expect(try latestRelease(code: 404, data: Data(#"{"message": "Not Found"}"#.utf8)) == nil)
    #expect(try latestRelease(code: 200, data: releaseJSON(tag: "v0.13", assets: ["dockduo-0.13.zip"]))?.version == "0.13")
    #expect(throws: UpdateError.self) { try latestRelease(code: 403, data: Data()) }
    #expect(throws: UpdateError.self) { try latestRelease(code: 200, data: Data("{".utf8)) }
}

@Test func dueImmediatelyThenAfterADayOrAnHour() {
    let now = Date()
    #expect(isDue(last: nil, succeeded: false, now: now))
    #expect(!isDue(last: now.addingTimeInterval(-23 * 3600), succeeded: true, now: now))
    #expect(isDue(last: now.addingTimeInterval(-24 * 3600), succeeded: true, now: now))
    #expect(!isDue(last: now.addingTimeInterval(-59 * 60), succeeded: false, now: now))
    #expect(isDue(last: now.addingTimeInterval(-3600), succeeded: false, now: now))
}

// La verifica di un download: un dockduo.app finto (identificativo giusto, versione 999, senza firma) zippato come make dist.
// Più nuovo ma non firmato come questa copia: rifiutato; non più nuovo: rifiutato prima della firma. La cartella
// temporanea dockduo-update-* non resta in nessuno dei due casi.
@Test func aDownloadMustBeANewerDockduoSignedLikeThisCopy() throws {
    let fm = FileManager.default, temp = fm.temporaryDirectory
    let work = temp.appendingPathComponent("dockduo-fake-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: work) }
    let contents = work.appendingPathComponent("dockduo.app/Contents")
    try fm.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "com.dockduo.app", "CFBundleShortVersionString": "999", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let zip = work.appendingPathComponent("dockduo.zip")
    try #require(shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", work.appendingPathComponent("dockduo.app").path, zip.path]) != nil)
    let data = try Data(contentsOf: zip)

    func leftovers() throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("dockduo-update-") }) }
    let before = try leftovers()
    #expect(throws: UpdateError.signature) { try unpackAndVerify(data, newerThan: "0.1") }
    #expect(throws: UpdateError.notNewerApp) { try unpackAndVerify(data, newerThan: "9999") }
    #expect(try leftovers().isSubset(of: before))
}

@Test func relaunchWaitsForThisProcessAndSurvivesSpaces() {
    #expect(relaunchArguments(pid: 42, app: "/Users/x/My Apps/dockduo.app") ==
            ["-c", "while kill -0 42 2>/dev/null; do sleep 0.1; done; open \"$0\"", "/Users/x/My Apps/dockduo.app"])
}
