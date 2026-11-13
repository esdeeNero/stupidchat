import XCTest
import CryptoKit
@testable import StupidChat

@MainActor final class DeliveryTests: XCTestCase {
    func testChangesRespectAuthorAndDeletionWins() {
        let chat=Chat(preview:true)
        let original=Message(text:"before",mine:false)
        chat.state.messages=[original]
        var edit=Message(text:"after",kind:"edit",mine:true,target:original.id)
        chat.applyChange(edit)
        XCTAssertEqual(chat.state.messages[0].text,"before")
        edit.mine=false
        chat.applyChange(edit)
        XCTAssertEqual(chat.state.messages[0].text,"after")
        chat.applyChange(Message(kind:"delete",mine:false,target:original.id))
        chat.applyChange(edit)
        XCTAssertFalse(chat.state.messages[0].visible)
        XCTAssertEqual(chat.state.messages[0].text,"")
        let future=UUID().uuidString
        chat.applyChange(Message(kind:"delete",mine:false,target:future))
        chat.applyChange(Message(text:"late",kind:"edit",mine:false,target:future))
        XCTAssertEqual(chat.state.pendingChanges?[future]?.kind,"delete")
    }
    func testOutboxPersistsAndResumesAfterNetworkFailure() async throws {
        let chat=Chat(),original=Chat().state
        defer {chat.state=original;chat.persist()}
        chat.state=State();chat.error=""
        await chat.register()
        XCTAssertTrue(chat.error.isEmpty,chat.error)
        let remote: Account=try await chat.request("register",body:Data("{}".utf8))
        chat.state.peer=Invite(id:remote.id,key:Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,name:"Test peer")
        let workingServer=chat.state.server
        chat.state.server="http://127.0.0.1:1";chat.state.automaticEndpoint=false
        let accepted=await chat.send(text:"Сохранить и повторить");XCTAssertTrue(accepted)
        await chat.flushOutbox()
        XCTAssertEqual(chat.state.outbox?.count,1)
        let pendingID=try XCTUnwrap(chat.state.outbox?.first?.id)
        XCTAssertEqual(chat.state.messages.first?.delivery,"pending")
        let resumed=Chat()
        XCTAssertEqual(resumed.state.outbox?.first?.id,pendingID)
        resumed.state.server=workingServer;resumed.state.automaticEndpoint=true
        await resumed.flushOutbox()
        XCTAssertTrue(resumed.state.outbox?.isEmpty ?? true)
        XCTAssertEqual(resumed.state.messages.first?.id,pendingID)
        XCTAssertNil(resumed.state.messages.first?.delivery)
        XCTAssertTrue(Chat().state.outbox?.isEmpty ?? true)
    }
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
        chat.state.lastProfileHash="test-profile-managed-explicitly"
        chat.state.profile.avatar=Data(repeating:7,count:40000)
        chat.state.profile.banner=Data(repeating:9,count:35000)
        let binary=Data((0..<4096).map { UInt8($0 % 256) })
        await chat.send(text:"Секретный текст",kind:"photo",data:binary)
        await chat.flushOutbox()
        XCTAssertTrue(chat.state.outbox?.isEmpty ?? true)
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
        XCTAssertNil(decoded.profile,"Ordinary messages must not upload avatar/banner")
        XCTAssertLessThan(envelope.body.utf8.count,12000)
        await chat.publishProfileIfNeeded()
        // A public tunnel can time out mid-upload. Exercise the foreground retry path.
        let deadline=Date().addingTimeInterval(120)
        repeat {
            await chat.flushOutbox()
            if chat.state.outbox?.isEmpty != false {break}
            try await Task.sleep(for:.seconds(3))
        } while Date()<deadline
        XCTAssertTrue(chat.state.outbox?.isEmpty ?? true)
        let (profileBytes,_)=try await URLSession.shared.data(for:req)
        let profiles=try JSONDecoder().decode(Inbox.self,from:profileBytes)
        let profileEnvelope=try XCTUnwrap(profiles.messages.last)
        let profileCipher=try XCTUnwrap(Data(base64Encoded:profileEnvelope.body))
        let profilePlain=try ChaChaPoly.open(ChaChaPoly.SealedBox(combined:profileCipher),using:key,authenticating:Data(profileEnvelope.id.utf8))
        let profileMessage=try JSONDecoder().decode(Message.self,from:profilePlain)
        XCTAssertEqual(profileMessage.kind,"profile")
        XCTAssertEqual(profileMessage.profile?.avatar,chat.state.profile.avatar)
        XCTAssertEqual(profileMessage.profile?.banner,chat.state.profile.banner)
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
        let receivedProfile=Profile(name:"Друг с аватаркой",bio:"Профиль синхронизирован",avatar:Data(repeating:4,count:40000),banner:Data(repeating:8,count:35000))
        var profileUpdate=Message(kind:"profile");profileUpdate.profile=receivedProfile
        let profileBody=try ChaChaPoly.seal(JSONEncoder().encode(profileUpdate),using:key,authenticating:Data(profileUpdate.id.utf8)).combined.base64EncodedString()
        let bytes=Array(profileBody.utf8),parts=(bytes.count+32767)/32768
        for index in 0..<parts {
            let body=String(decoding:bytes[index*32768..<min((index+1)*32768,bytes.count)],as:UTF8.self)
            let _: ChunkReply=try await chat.request("chunk/\(local.id)",body:JSONEncoder().encode(CipherPiece(id:profileUpdate.id,index:index,total:parts,body:body)))
        }
        for _ in 0..<5 {await chat.poll();if chat.state.remoteProfile.name==receivedProfile.name {break}}
        XCTAssertEqual(chat.state.remoteProfile.name,receivedProfile.name)
        XCTAssertEqual(chat.state.remoteProfile.bio,receivedProfile.bio)
        XCTAssertEqual(chat.state.remoteProfile.avatar,receivedProfile.avatar)
        XCTAssertEqual(chat.state.remoteProfile.banner,receivedProfile.banner)
        let oldAddress=chat.state.server
        await chat.changeServer("http://example.com")
        XCTAssertEqual(chat.state.server,oldAddress,"Reject insecure remote addresses without changing configuration")
        XCTAssertFalse(chat.error.isEmpty); chat.error=""
        let inbox: Inbox=try await chat.request("inbox/\(local.id)")
        XCTAssertTrue(inbox.messages.isEmpty,"Must acknowledge after durable local save")
        let reloaded=Chat()
        XCTAssertEqual(reloaded.state.messages.count,7)
        XCTAssertEqual(reloaded.state.messages.last(where:{$0.kind != "profile"})?.data,binary)
        if Deployment.discoveryURL != nil {
            chat.state.server="https://retired-endpoint.invalid"
            try chat.save()
            let recovered=Chat()
            try await recovered.refreshEndpoint(force:true)
            XCTAssertNotEqual(recovered.state.server,"https://retired-endpoint.invalid")
            XCTAssertEqual(recovered.state.account?.id,local.id)
            XCTAssertEqual(recovered.state.messages.count,7)
            await recovered.poll() // Also verify connectivity when no new messages exist.
            XCTAssertEqual(recovered.connection,"Сервер доступен")
        }
        if let legacy=Deployment.legacyURLs.first {
            chat.state.server=legacy
            try chat.save()
            let migrated=Chat()
            XCTAssertEqual(migrated.state.server,Deployment.serverURL)
            XCTAssertEqual(migrated.state.account?.id,local.id)
            XCTAssertEqual(migrated.state.messages.count,7)
        }
    }
}
