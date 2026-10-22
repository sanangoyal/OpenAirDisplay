import Foundation
import CryptoKit

// Message types (inside the encrypted channel)
enum MT {
    static let config: UInt8 = 0, frame: UInt8 = 1, ping: UInt8 = 2, pong: UInt8 = 3, info: UInt8 = 4, audio: UInt8 = 5, input: UInt8 = 6
    // plaintext handshake
    static let cHello: UInt8 = 0x10, sHello: UInt8 = 0x11, cAuth: UInt8 = 0x12, sAuth: UInt8 = 0x13, reject: UInt8 = 0x1F
}
let WIRE_VERSION: UInt8 = 1
let MAX_BODY = 16 * 1024 * 1024

struct WireError: Error { let msg: String; init(_ m: String) { msg = m } }

struct Peer: Codable { var id: String; var name: String; var pub: Data; var macs: [String]? = nil }

// MARK: identity + pinned peers
final class Keys {
    let dir: URL
    let signing: Curve25519.Signing.PrivateKey
    var peers: [Peer]
    init(appDir: String, baseDir: URL? = nil) {
        let base = (baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).appendingPathComponent(appDir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let kf = base.appendingPathComponent("identity.key")
        if let d = try? Data(contentsOf: kf), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) {
            signing = k
        } else {
            let k = Curve25519.Signing.PrivateKey()
            try? k.rawRepresentation.write(to: kf, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kf.path)
            signing = k
        }
        dir = base
        peers = (try? JSONDecoder().decode([Peer].self, from: Data(contentsOf: base.appendingPathComponent("peers.json")))) ?? []
    }
    var pub: Data { signing.publicKey.rawRepresentation }
    var myID: String { Keys.fp(pub) }
    static func fp(_ pub: Data) -> String { SHA256.hash(data: pub).prefix(6).map { String(format: "%02x", $0) }.joined() }
    func save() {
        if let d = try? JSONEncoder().encode(peers) { try? d.write(to: dir.appendingPathComponent("peers.json"), options: .atomic) }
    }
    func peer(pub: Data) -> Peer? { peers.first { $0.pub == pub } }
    func peer(id: String) -> Peer? { peers.first { $0.id == id } }
    func pin(pub: Data, name: String) {
        peers.removeAll { $0.pub == pub }
        peers.append(Peer(id: Keys.fp(pub), name: name, pub: pub)); save()
    }
    func setMacs(id: String, macs: [String]) {
        if let i = peers.firstIndex(where: { $0.id == id }) { peers[i].macs = macs; save() }
    }
    func forget(id: String) { peers.removeAll { $0.id == id }; save() }
    func forgetAll() { peers = []; save() }
}

// MARK: pairing code
enum Code {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static func generate() -> String {
        var g = SystemRandomNumberGenerator()
        let s = (0..<10).map { _ in String(alphabet[Int(g.next(upperBound: UInt32(alphabet.count)))]) }.joined()
        return String(s.prefix(5)) + "-" + String(s.suffix(5))
    }
    static func normalize(_ s: String) -> String { String(s.uppercased().filter { alphabet.contains($0) }) }
    static func key(_ code: String) -> SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data(("ODSP-pair:" + normalize(code)).utf8))) }
}

// MARK: framing
func wireFrame(_ body: Data) -> Data {
    var d = Data(); var l = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &l) { d.append(contentsOf: $0) }
    d.append(body); return d
}
struct Deframer {
    var buf = Data()
    mutating func push(_ d: Data) { buf.append(d) }
    /// returns nil if incomplete; throws if oversize
    mutating func next() throws -> Data? {
        guard buf.count >= 4 else { return nil }
        let s0 = buf.startIndex
        let len = Int(buf[s0]) << 24 | Int(buf[s0 + 1]) << 16 | Int(buf[s0 + 2]) << 8 | Int(buf[s0 + 3])
        if len > MAX_BODY { throw WireError("oversize frame") }
        guard buf.count >= 4 + len else { return nil }
        let body = buf.subdata(in: (s0 + 4)..<(s0 + 4 + len))
        buf = buf.subdata(in: (s0 + 4 + len)..<buf.endIndex)
        return body
    }
}

struct Reader {
    let d: Data; var o = 0
    init(_ d: Data) { self.d = Data(d) }
    mutating func u8() throws -> UInt8 { guard o < d.count else { throw WireError("short") }; defer { o += 1 }; return d[o] }
    mutating func bytes(_ n: Int) throws -> Data { guard n >= 0, o + n <= d.count else { throw WireError("short") }; defer { o += n }; return d.subdata(in: o..<(o + n)) }
    mutating func str() throws -> String { let n = Int(try u8()); return String(decoding: try bytes(n), as: UTF8.self) }
    mutating func rest() -> Data { let r = d.subdata(in: o..<d.count); o = d.count; return r }
}

// MARK: encrypted channel
final class Channel {
    let sk: SymmetricKey, rk: SymmetricKey
    var sc: UInt64 = 0, rc: UInt64 = 0
    init(send: SymmetricKey, recv: SymmetricKey) { sk = send; rk = recv }
    private func nonce(_ c: UInt64) -> AES.GCM.Nonce {
        var d = Data(count: 4); var be = c.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: d)
    }
    func seal(_ type: UInt8, _ payload: Data) -> Data {
        var pt = Data([type]); pt.append(payload)
        let box = try! AES.GCM.seal(pt, using: sk, nonce: nonce(sc)); sc += 1
        var out = Data(box.ciphertext); out.append(box.tag); return out
    }
    func open(_ body: Data) -> (UInt8, Data)? {
        guard body.count >= 17 else { return nil }
        let ct = body.prefix(body.count - 16), tag = body.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce(rc), ciphertext: ct, tag: tag),
              let pt = try? AES.GCM.open(box, using: rk), pt.count >= 1 else { return nil }
        rc += 1
        return (pt[pt.startIndex], Data(pt.dropFirst()))
    }
}

// MARK: handshake (Ed25519 identity, X25519 ephemeral, optional pairing-code proof)
final class Handshake {
    enum Role { case client, server }
    let role: Role
    let keys: Keys
    let myName: String
    let eph = Curve25519.KeyAgreement.PrivateKey()
    /// client: code the user typed (pair mode when non-nil)
    var clientCode: String?
    /// server: returns the currently valid pairing code, or nil if pairing is closed
    var serverCode: (() -> String?)?
    var serverAttemptFailed: (() -> Void)?
    var helloA = Data(), helloB = Data(), t2 = Data()
    var peerPub = Data(), peerName = "", peerEph = Data()
    var pairMode = false
    var channel: Channel?
    var pairedNow = false
    var completed = false

    init(role: Role, keys: Keys, name: String) { self.role = role; self.keys = keys; myName = name }

    private func sha(_ parts: Data...) -> Data { var h = SHA256(); parts.forEach { h.update(data: $0) }; return Data(h.finalize()) }
    private func hmac(_ key: SymmetricKey, _ label: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + t2, using: key)) }
    private func nameBytes() -> Data { let n = Data(myName.utf8.prefix(60)); return Data([UInt8(n.count)]) + n }
    private func rnd() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    /// client: first message
    func clientHello() -> (UInt8, Data) {
        pairMode = clientCode != nil
        var h = Data([WIRE_VERSION, pairMode ? 1 : 0])
        h.append(keys.pub); h.append(eph.publicKey.rawRepresentation); h.append(rnd()); h.append(nameBytes())
        helloA = h
        return (MT.cHello, h)
    }

    /// Feed one plaintext handshake message; returns messages to send back.
    func receive(_ type: UInt8, _ p: Data) throws -> [(UInt8, Data)] {
        if type == MT.reject { throw WireError("rejected: " + String(decoding: p, as: UTF8.self)) }
        switch (role, type) {
        case (.server, MT.cHello):
            var r = Reader(p)
            guard try r.u8() == WIRE_VERSION else { throw WireError("version") }
            pairMode = try r.u8() == 1
            peerPub = try r.bytes(32); peerEph = try r.bytes(32); _ = try r.bytes(16); peerName = try r.str()
            helloA = p
            var h = Data([WIRE_VERSION]); h.append(keys.pub); h.append(eph.publicKey.rawRepresentation); h.append(rnd()); h.append(nameBytes())
            let sig = try keys.signing.signature(for: sha(Data("S1".utf8), helloA, h))
            helloB = h + sig
            t2 = sha(Data("S2".utf8), helloA, helloB)
            return [(MT.sHello, helloB)]

        case (.client, MT.sHello):
            var r = Reader(p)
            guard try r.u8() == WIRE_VERSION else { throw WireError("version") }
            peerPub = try r.bytes(32); peerEph = try r.bytes(32); _ = try r.bytes(16); peerName = try r.str()
            let sig = try r.bytes(64)
            let noSig = p.prefix(p.count - 64)
            guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: peerPub),
                  pk.isValidSignature(sig, for: sha(Data("S1".utf8), helloA, Data(noSig))) else { throw WireError("bad server signature") }
            if !pairMode, keys.peer(pub: peerPub) == nil { throw WireError("receiver not paired") }
            helloB = p
            t2 = sha(Data("S2".utf8), helloA, helloB)
            let mySig = try keys.signing.signature(for: sha(Data("C2".utf8), t2))
            var out = mySig
            if pairMode, let c = clientCode { out.append(hmac(Code.key(c), "cli")) }
            try derive()
            return [(MT.cAuth, out)]

        case (.server, MT.cAuth):
            var r = Reader(p)
            let sig = try r.bytes(64); let proof = r.rest()
            guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: peerPub),
                  pk.isValidSignature(sig, for: sha(Data("C2".utf8), t2)) else { throw WireError("bad client signature") }
            var reply = Data()
            if pairMode {
                guard let code = serverCode?() else { throw WireError("pairing is not open on the receiver") }
                let key = Code.key(code)
                guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("cli".utf8) + t2, using: key) else {
                    serverAttemptFailed?(); throw WireError("wrong pairing code")
                }
                keys.pin(pub: peerPub, name: peerName); pairedNow = true
                reply = hmac(key, "srv")
            } else {
                guard keys.peer(pub: peerPub) != nil else { throw WireError("not paired") }
            }
            try derive()
            completed = true
            return [(MT.sAuth, reply)]

        case (.client, MT.sAuth):
            if pairMode, let c = clientCode {
                guard HMAC<SHA256>.isValidAuthenticationCode(p, authenticating: Data("srv".utf8) + t2, using: Code.key(c)) else { throw WireError("receiver failed pairing proof") }
                keys.pin(pub: peerPub, name: peerName); pairedNow = true
            }
            completed = true
            return []
        default:
            throw WireError("unexpected handshake message \(type)")
        }
    }

    private func derive() throws {
        let pe = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEph)
        let ss = try eph.sharedSecretFromKeyAgreement(with: pe)
        func k(_ l: String) -> SymmetricKey { ss.hkdfDerivedSymmetricKey(using: SHA256.self, salt: t2, sharedInfo: Data(l.utf8), outputByteCount: 32) }
        channel = role == .client ? Channel(send: k("c2s"), recv: k("s2c")) : Channel(send: k("s2c"), recv: k("c2s"))
    }
}
