import Testing
@testable import Dockduo

@Test func wifiBarsByRSSI() {
    #expect([-40, -60, -61, -70, -71, -100].map { wifiBars(rssi: $0) } == [3, 3, 2, 2, 1, 1])
}

// VPN: un tunnel (utun, ipsec, ppp) con un indirizzo IPv4. I tunnel di sistema di macOS hanno solo IPv6.
@Test func vpnIsATunnelWithAnIPv4Address() {
    #expect(vpnActive([("en0", true), ("utun3", false), ("utun9", true)]))
    #expect(vpnActive([("ipsec0", true)]))
    #expect(!vpnActive([("en0", true), ("lo0", true), ("utun0", false), ("utun1", false)]))
    #expect(!vpnActive([]))
}

// Byte al secondo tra due letture dei contatori a 32 bit, anche quando il contatore riparte da zero nel mezzo.
@Test func byteRateHandlesCounterWraparound() {
    #expect(byteRate(from: 1_000, to: 3_000, seconds: 2) == 1_000)
    #expect(byteRate(from: UInt32.max - 99, to: 100, seconds: 1) == 200)
    #expect(byteRate(from: 5, to: 5, seconds: 1) == 0)
    #expect(byteRate(from: 1, to: 100, seconds: 0) == 0)
}

@Test func rateStringIsNumericWithPerSecond() {
    #expect(rateString(0).hasSuffix("KB/s") && !rateString(0).contains("Zero"))
    #expect(rateString(207).hasSuffix("KB/s"))
    #expect(rateString(2_400_000).contains("MB/s"))
    #expect(rateString(120_000).contains("KB/s"))
}
