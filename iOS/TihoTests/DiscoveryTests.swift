import XCTest
import CryptoKit
@testable import StupidChat

final class DiscoveryTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:2_000_000_000)
    private func envelope(_ key: Curve25519.Signing.PrivateKey,url: String = "https://relay.example.com",time: Double = 2_000_000_000) throws -> Data {
        let payload=try JSONSerialization.data(withJSONObject:["url":url,"issuedAt":time])
        return try JSONSerialization.data(withJSONObject:["payload":payload.base64EncodedString(),"signature":key.signature(for:payload).base64EncodedString()])
    }
    func testAcceptSignedHTTPSAndRejectWrongSignerOrModifiedPayload() throws {
        let key=Curve25519.Signing.PrivateKey()
        let data=try envelope(key)
        let address=try EndpointDiscovery.verify(data,publicKey:key.publicKey.rawRepresentation,now:now)
        XCTAssertEqual(address.url,"https://relay.example.com")
        XCTAssertThrowsError(try EndpointDiscovery.verify(data,publicKey:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,now:now))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:String])
        object["payload"]=try JSONSerialization.data(withJSONObject:["url":"https://attacker.example","issuedAt":2_000_000_000]).base64EncodedString()
        XCTAssertThrowsError(try EndpointDiscovery.verify(JSONSerialization.data(withJSONObject:object),publicKey:key.publicKey.rawRepresentation,now:now))
    }
    func testRejectExpiredFutureRollbackAndInsecureAddresses() throws {
        let key=Curve25519.Signing.PrivateKey(),pub=key.publicKey.rawRepresentation
        XCTAssertThrowsError(try EndpointDiscovery.verify(envelope(key,time:now.timeIntervalSince1970-86401),publicKey:pub,now:now))
        XCTAssertThrowsError(try EndpointDiscovery.verify(envelope(key,time:now.timeIntervalSince1970+301),publicKey:pub,now:now))
        XCTAssertThrowsError(try EndpointDiscovery.verify(envelope(key),publicKey:pub,lastIssuedAt:now.timeIntervalSince1970+1,now:now))
        for url in ["http://relay.example.com","https://user:secret@relay.example.com","https://relay.example.com/path","https://relay.example.com?token=test"] {
            XCTAssertThrowsError(try EndpointDiscovery.verify(envelope(key,url:url),publicKey:pub,now:now))
        }
    }
}
