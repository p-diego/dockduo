import Foundation

// Il numero rosso che un'app mette sulla sua icona nel Dock (NSDockTile.badgeLabel), per il widget Dock. LaunchServices lo
// tiene per ogni app come "StatusLabel": lo stesso che i plugin di SketchyBar leggono con `lsappinfo info -only
// StatusLabel`. Funzioni private, caricate a runtime come quelle di SkyLight (WindowEvents.swift): se un simbolo manca
// (macOS cambiato) niente numeri, detto una volta nel log. Nessun permesso; una lettura costa 0,03 ms per app (24/10).
private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
private let launchServices: (asn: CreateASN, item: CopyItem)? = {
    let ls = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
    guard let asn = dlsym(ls, "_LSASNCreateWithPid"), let item = dlsym(ls, "_LSCopyApplicationInformationItem") else {
        logger.error("LaunchServices: simboli mancanti, niente numeri nel Dock")
        return nil
    }
    return (unsafeBitCast(asn, to: CreateASN.self), unsafeBitCast(item, to: CopyItem.self))
}()

// I numeri delle app, per pid: solo quelle che ne hanno uno ("" = il solo pallino).
func readBadges(_ pids: [pid_t]) -> [pid_t: String] {
    guard let ls = launchServices else { return [:] }
    var out: [pid_t: String] = [:]
    for pid in pids {
        guard let asn = ls.asn(nil, pid)?.takeRetainedValue() else { continue }
        out[pid] = badgeLabel(ls.item(-2, asn, "StatusLabel" as CFString)?.takeRetainedValue())   // -2: la sessione di default
    }
    return out
}

// Il valore di "StatusLabel": un dizionario col testo in "label"; NSNull dopo che l'app l'ha tolto, niente se non l'ha mai
// messo (misurato il 24/10 con un'app di prova).
func badgeLabel(_ info: Any?) -> String? { (info as? [String: Any])?["label"] as? String }
