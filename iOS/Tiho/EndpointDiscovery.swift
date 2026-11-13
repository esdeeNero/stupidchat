import Foundation
import CryptoKit

struct SignedRelayAddress: Decodable {
    let url: String
    let issuedAt: TimeInterval
}
enum EndpointDiscovery {
    private struct Envelope: Decodable { let payload: Data; let signature: Data }
    static func verify(_ data: Data, publicKey: Data, lastIssuedAt: TimeInterval? = nil, now: Date = Date()) throws -> SignedRelayAddress {
        let envelope=try JSONDecoder().decode(Envelope.self,from:data)
        let key=try Curve25519.Signing.PublicKey(rawRepresentation:publicKey)
        guard key.isValidSignature(envelope.signature,for:envelope.payload) else {throw URLError(.secureConnectionFailed)}
        let address=try JSONDecoder().decode(SignedRelayAddress.self,from:envelope.payload)
        guard address.issuedAt >= now.timeIntervalSince1970-86400,
              address.issuedAt <= now.timeIntervalSince1970+300,
              address.issuedAt >= (lastIssuedAt ?? 0),
              let url=URL(string:address.url),url.scheme == "https",url.host != nil,
              url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {throw URLError(.badServerResponse)}
        return address
    }
}
