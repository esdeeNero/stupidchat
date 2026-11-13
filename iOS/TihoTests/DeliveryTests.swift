import XCTest
import CryptoKit
@testable import StupidChat

@MainActor final class DeliveryTests: XCTestCase {
    func testEncryptedRoundTripThroughRelay() async throws {
        let chat=Chat()
        let original=chat.state
        defer { chat.state=original; chat.persist() }
        chat.error=""
        chat.state=State()
        chat.state.server=Deployment.discoveryURL == nil ? Deployment.serverURL:"https://retired-endpoint.invalid"
        await chat.register()
        XCTAssertTrue(chat.error.isEmpty,chat.error)
        XCTAssertNotEqual(chat.state.server,"https://retired-endpoint.invalid")
        let local=try XCTUnwrap(chat.state.account)
        await chat.changeServer(chat.state.server)
        XCTAssertEqual(chat.state.account?.id,local.id)
        XCTAssertTrue(chat.error.isEmpty,chat.error)
        let invitationData=try XCTUnwrap(Data(base64Encoded:chat.invitation))
        let invitation=try JSONDecoder().decode(Invite.self,from:invitationData)
        let remote: Account=try await chat.request("register",body:Data("{}".utf8))
        let remoteIdentity=Curve25519.KeyAgreement.PrivateKey()
        chat.state.peer=Invite(id:remote.id,key:remoteIdentity.publicKey.rawRepresentation,name:"Test peer")
        let secret=try remoteIdentity.sharedSecretFromKeyAgreement(with:Curve25519.KeyAgreement.PublicKey(rawRepresentation:invitation.key))
        let key=secret.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data("Tiho-v1".utf8),sharedInfo:Data([local.id,remote.id].sorted().joined(separator:":").utf8),outputByteCount:32)
        let binary=Data((0..<4096).map { UInt8($0 % 256) })
        await chat.send(text:"Секретный текст",kind:"photo",data:binary)
        XCTAssertTrue(chat.error.isEmpty,chat.error)
        var req=URLRequest(url:URL(string:"\(chat.state.server)/inbox/\(remote.id)")!)
        req.setValue("Bearer \(remote.token)",forHTTPHeaderField:"Authorization")
        req.setValue(Deployment.accessKey,forHTTPHeaderField:"X-Tiho-Access")
        let (data,_)=try await URLSession.shared.data(for:req)
        let outgoing=try JSONDecoder().decode(Inbox.self,from:data)
        let envelope=try XCTUnwrap(outgoing.messages.first)
        let cipher=try XCTUnwrap(Data(base64Encoded:envelope.body))
        XCTAssertFalse(String(data:cipher,encoding:.utf8)?.contains("Секретный") ?? false)
        let plain=try ChaChaPoly.open(ChaChaPoly.SealedBox(combined:cipher),using:key,authenticating:Data(envelope.id.utf8))
        let decoded=try JSONDecoder().decode(Message.self,from:plain)
        XCTAssertEqual(decoded.text,"Секретный текст"); XCTAssertEqual(decoded.data,binary)
        for kind in ["text","photo","video","voice"] {
            var incoming=Message(text:"Ответ",kind:kind,data:kind == "text" ? nil:binary)
            incoming.profile=Profile(name:"Друг")
            let body=try ChaChaPoly.seal(JSONEncoder().encode(incoming),using:key,authenticating:Data(incoming.id.utf8)).combined.base64EncodedString()
            let _: Chat.OK=try await chat.request("send/\(local.id)",body:JSONEncoder().encode(Envelope(id:incoming.id,body:body)))
            await chat.poll()
            XCTAssertTrue(chat.error.isEmpty,chat.error)
            XCTAssertEqual(chat.state.messages.last?.id,incoming.id)
            XCTAssertEqual(chat.state.messages.last?.mine,false)
            XCTAssertEqual(chat.state.messages.last?.kind,kind)
            XCTAssertEqual(chat.state.remoteProfile.name,"Друг")
        }
        let oldAddress=chat.state.server
        await chat.changeServer("http://example.com")
        XCTAssertEqual(chat.state.server,oldAddress,"Reject insecure remote addresses without changing configuration")
        XCTAssertFalse(chat.error.isEmpty); chat.error=""
        let inbox: Inbox=try await chat.request("inbox/\(local.id)")
        XCTAssertTrue(inbox.messages.isEmpty,"Must acknowledge after durable local save")
        let reloaded=Chat()
        XCTAssertEqual(reloaded.state.messages.count,5)
        XCTAssertEqual(reloaded.state.messages.last?.data,binary)
        if Deployment.discoveryURL != nil {
            chat.state.server="https://retired-endpoint.invalid"
            try chat.save()
            let recovered=Chat()
            try await recovered.refreshEndpoint(force:true)
            XCTAssertNotEqual(recovered.state.server,"https://retired-endpoint.invalid")
            XCTAssertEqual(recovered.state.account?.id,local.id)
            XCTAssertEqual(recovered.state.messages.count,5)
            await recovered.poll() // Also verify connectivity when no new messages exist.
            XCTAssertEqual(recovered.connection,"Сервер доступен")
        }
        if let legacy=Deployment.legacyURLs.first {
            chat.state.server=legacy
            try chat.save()
            let migrated=Chat()
            XCTAssertEqual(migrated.state.server,Deployment.serverURL)
            XCTAssertEqual(migrated.state.account?.id,local.id)
            XCTAssertEqual(migrated.state.messages.count,5)
        }
    }
}
