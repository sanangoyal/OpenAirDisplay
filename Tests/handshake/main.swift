import Foundation

func tmpKeys(_ n: String) -> Keys { Keys(appDir: "hstest-" + n + "-\(getpid())", baseDir: URL(fileURLWithPath: NSTemporaryDirectory())) }
func pump(_ c: Handshake, _ s: Handshake, _ first: (UInt8, Data), serverOpen: Bool = true) throws -> (String, String) {
    var toS: [(UInt8, Data)] = [first], toC: [(UInt8, Data)] = []
    var cNum = "", sNum = ""
    c.onNumber = { cNum = $0 }; s.onNumber = { sNum = $0 }
    s.serverPairOpen = { serverOpen }
    var n = 0, decided = false
    while n < 20 {
        n += 1
        for m in toS { toC += try s.receive(m.0, m.1) }; toS = []
        for m in toC { toS += try c.receive(m.0, m.1) }; toC = []
        if !decided && !cNum.isEmpty && !sNum.isEmpty {
            decided = true                                  // user clicks Pair on both Macs
            toS += try c.clientDecision(true)
            toC += try s.serverDecision(true)
        }
        if c.completed && s.completed { break }
    }
    return (cNum, sNum)
}

let kc = tmpKeys("c"), ks = tmpKeys("s")
// 1. pairing
let c = Handshake(role: .client, keys: kc, name: "MacBook"); c.clientCode = "pair"
let s = Handshake(role: .server, keys: ks, name: "Neo")
let (a, b) = try pump(c, s, c.clientHello())
print("1 numbers:", a, b, a == b, "completed:", c.completed, s.completed, "pairedNow:", c.pairedNow, s.pairedNow, "pinned:", kc.peers.count, ks.peers.count)
// 2. normal reconnect (already paired)
let c2 = Handshake(role: .client, keys: kc, name: "MacBook")
let s2 = Handshake(role: .server, keys: ks, name: "Neo")
_ = try pump(c2, s2, c2.clientHello())
print("2 reconnect completed:", c2.completed, s2.completed)
// 3. unpaired normal connect is refused
let k3 = tmpKeys("x")
let c3 = Handshake(role: .client, keys: k3, name: "Stranger")
let s3 = Handshake(role: .server, keys: ks, name: "Neo")
do { _ = try pump(c3, s3, c3.clientHello()); print("3 stranger: UNEXPECTEDLY ACCEPTED") } catch { print("3 stranger refused:", error) }
// 4. pairing while closed is refused
let c4 = Handshake(role: .client, keys: k3, name: "Stranger"); c4.clientCode = "pair"
let s4 = Handshake(role: .server, keys: ks, name: "Neo")
do { _ = try pump(c4, s4, c4.clientHello(), serverOpen: false); print("4 closed: UNEXPECTEDLY ACCEPTED") } catch { print("4 closed refused:", error) }
// 5. man in the middle: the two sessions must show different numbers
let victimC = Handshake(role: .client, keys: tmpKeys("v"), name: "MacBook"); victimC.clientCode = "pair"
let mitmS = Handshake(role: .server, keys: tmpKeys("m1"), name: "Neo")
let mitmC = Handshake(role: .client, keys: tmpKeys("m2"), name: "MacBook"); mitmC.clientCode = "pair"
let realS = Handshake(role: .server, keys: tmpKeys("r"), name: "Neo")
var n1 = "", n2 = ""
victimC.onNumber = { n1 = $0 }; realS.onNumber = { n2 = $0 }; realS.serverPairOpen = { true }; mitmS.serverPairOpen = { true }
let v1 = victimC.clientHello()
let r1 = try mitmS.receive(v1.0, v1.1)
let r2 = try victimC.receive(r1[0].0, r1[0].1)
_ = try mitmS.receive(r2[0].0, r2[0].1)
let h2 = mitmC.clientHello(); let rs = try realS.receive(h2.0, h2.1)
let rr = try mitmC.receive(rs[0].0, rs[0].1); _ = try realS.receive(rr[0].0, rr[0].1)
print("5 MITM numbers (victim vs receiver):", n1, n2, n1 == n2 ? "SAME (attack works!)" : "differ (attack visible)")
// 6. tampered reveal is rejected
let c6 = Handshake(role: .client, keys: tmpKeys("t"), name: "MacBook"); c6.clientCode = "pair"
let s6 = Handshake(role: .server, keys: tmpKeys("u"), name: "Neo"); s6.serverPairOpen = { true }
let f6 = c6.clientHello(); let sh = try s6.receive(f6.0, f6.1); let rv = try c6.receive(sh[0].0, sh[0].1)
var bad = rv[0].1; bad[bad.startIndex + 40] ^= 1
do { _ = try s6.receive(rv[0].0, bad); print("6 tampered reveal: UNEXPECTEDLY ACCEPTED") } catch { print("6 tampered reveal refused:", error) }
