import SwiftUI
import CryptoKit
import Security
import AVFoundation
import UIKit

struct Profile: Codable, Equatable { var name = "Я"; var bio = "На связи, в своём ритме"; var avatar: Data?; var banner: Data? }
struct Invite: Codable { let id: String; let key: Data; let name: String; var server: String? = nil }
struct Message: Codable, Identifiable { var id = UUID().uuidString; var text = ""; var kind = "text"; var data: Data?; var date = Date(); var mine = true; var profile: Profile?; var delivery: String?; var target: String?; var edited: Date?; var deleted: Bool?
    var visible: Bool { kind != "profile" && deleted != true }
}
struct Account: Codable { let id: String; let token: String }
struct Envelope: Codable { let id: String; let body: String; var parts: Int? }
struct PendingEnvelope: Codable, Identifiable { var id: String {envelope.id}; let recipient: String; let envelope: Envelope; var nextPiece: Int = 0; var silent: Bool? }
struct CipherPiece: Codable { let id: String; let index: Int; let total: Int; let body: String }
struct ChunkReply: Decodable { let ok: Bool; let complete: Bool }
struct DownloadPiece: Decodable { let body: String }
struct Inbox: Codable { let messages: [Envelope]; var peerOnline: Bool? }
struct State: Codable { var account: Account?; var peer: Invite?; var messages: [Message] = []; var profile = Profile(); var remoteProfile = Profile(name: "Собеседник"); var server = Deployment.serverURL; var relayAccessKey: String?; var archived: Bool?; var lastReadAt: Date?; var automaticEndpoint: Bool?; var lastEndpointIssuedAt: TimeInterval?; var outbox: [PendingEnvelope]?; var lastProfileHash: String?; var remoteProfileDate: Date?; var pendingChanges: [String:Message]?; var profilePublishedAt: Date? }

enum Vault {
    static func key(_ name: String, create: () -> Data) throws -> Data {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"app.tiho.keys",kSecAttrAccount as String:name]
        var read=q; read[kSecReturnData as String]=true
        var result: CFTypeRef?
        let status=SecItemCopyMatching(read as CFDictionary,&result)
        if status==errSecSuccess, let data=result as? Data { return data }
        guard status==errSecItemNotFound else { throw NSError(domain:"Keychain",code:Int(status)) }
        let data=create(); var add=q; add[kSecValueData as String]=data; add[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added=SecItemAdd(add as CFDictionary,nil)
        guard added==errSecSuccess else { throw NSError(domain:"Keychain",code:Int(added)) }; return data
    }
}
@MainActor final class Chat: ObservableObject {
    @Published var state = State()
    @Published var error = ""
    @Published var busy = false
    @Published var recording = false
    @Published var attachmentProgress: Double?
    @Published var peerOnline: Bool?
    @Published var connection = "Подключение…"
    private var previewMode=false
    private var resolvingEndpoint=false
    private var endpointResolution: Task<Bool,Error>?
    private var lastEndpointAttempt=Date.distantPast
    private var lastForcedEndpointAttempt=Date.distantPast
    private var lastDiscoveredURL: String?
    private var outboxTask: Task<Void,Never>?
    private var nextSendAttempt=Date.distantPast
    private var retryCount=0
    private var publishingProfile=false
    private var checkedProfile: Profile?
    private var downloads: [String:[Int:String]] = [:]
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var identity: Curve25519.KeyAgreement.PrivateKey?
    private var storageKey: SymmetricKey?
    private let file = URL.documentsDirectory.appendingPathComponent("history.sealed")
    init(preview: Bool = false) {
        #if DEBUG
        if preview {
            previewMode=true
            state.profile=Profile(name:"Вы",bio:"stay a little stupid ✦")
            state.remoteProfile=Profile(name:"Алекс",bio:"музыка, ночной город и хорошие люди")
            state.peer=Invite(id:"preview-peer",key:Data(),name:"Алекс")
            state.account=Account(id:"preview-local",token:"")
            let now=Date()
            state.messages=[
                Message(text:"Привет! Как тебе stupidchat?",date:now.addingTimeInterval(-900),mine:false),
                Message(text:"Этот хромовый логотип — любовь ✦",date:now.addingTimeInterval(-840)),
                Message(text:"И наконец-то можно болтать из разных сетей",date:now.addingTimeInterval(-780),mine:false),
                Message(text:"Да. Тот же разговор, где бы мы ни были.",date:now.addingTimeInterval(-720)),
                Message(text:"Встретимся вечером?",date:now.addingTimeInterval(-120),mine:false)
            ]
            connection="Демонстрационный режим"
            return
        }
        #endif
        do {
            identity = try .init(rawRepresentation: Vault.key("identity") { Curve25519.KeyAgreement.PrivateKey().rawRepresentation })
            storageKey = SymmetricKey(data: try Vault.key("storage") { SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) } })
            if FileManager.default.fileExists(atPath:file.path), let key=storageKey {
                let plain=try AES.GCM.open(AES.GCM.SealedBox(combined:Data(contentsOf:file)),using:key)
                state=try JSONDecoder().decode(State.self,from:plain)
            }
            if Deployment.legacyURLs.contains(state.server) { state.server=Deployment.serverURL; try save() }
            var values=URLResourceValues(); values.isExcludedFromBackup=true; var directory=URL.documentsDirectory; try directory.setResourceValues(values)
        } catch { self.error="Не удалось открыть защищённое хранилище: \(error.localizedDescription)" }
    }
    func save() throws {
        guard !previewMode else { return }
        guard let key=storageKey else { throw URLError(.cannotDecodeContentData) }
        let data=try AES.GCM.seal(JSONEncoder().encode(state),using:key).combined!
        try data.write(to:file,options:[.atomic,.completeFileProtection])
    }
    func persist() { do { try save() } catch { self.error=error.localizedDescription } }
    private static let network: URLSession = {
        let config=URLSessionConfiguration.ephemeral
        config.waitsForConnectivity=false
        config.timeoutIntervalForRequest=30
        config.timeoutIntervalForResource=150
        return URLSession(configuration:config)
    }()
    func request<T: Decodable>(_ path: String, body: Data? = nil, server: String? = nil, query: [URLQueryItem] = []) async throws -> T {
        guard !previewMode else { throw URLError(.notConnectedToInternet) }
        if server == nil { _ = try? await refreshEndpoint(force:path == "register") }
        guard let base=URL(string:server ?? state.server), ["https","http"].contains(base.scheme ?? ""), let host=base.host, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw URLError(.badURL) }
        let octets=host.split(separator:".").compactMap { Int($0) }
        let ipv4=octets.count==4 && octets.allSatisfy { (0...255).contains($0) }
        let privateIPv4=ipv4 && (octets[0]==127 || octets[0]==10 || (octets[0]==192 && octets[1]==168) || (octets[0]==172 && (16...31).contains(octets[1])))
        let local=host=="localhost" || host=="[::1]" || host=="::1" || host.hasSuffix(".local") || privateIPv4
        guard base.scheme=="https" || local else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        var components=URLComponents(url:base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty {components.queryItems=query}
        var req=URLRequest(url:components.url!,cachePolicy:.reloadIgnoringLocalCacheData)
        if path.hasPrefix("inbox/") {
            req.setValue(UserDefaults.standard.bool(forKey:"pushEnabled") ? PushRegistration.token : "off",forHTTPHeaderField:"X-Push-Device")
        }
        req.timeoutInterval=path.hasPrefix("chunk/") || path.hasPrefix("piece/") ? 25:12
        req.httpMethod=body == nil ? "GET":"POST"; req.httpBody=body
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.setValue(relayAccessKey,forHTTPHeaderField:"X-Tiho-Access")
        if let account=state.account { req.setValue("Bearer \(account.token)",forHTTPHeaderField:"Authorization") }
        do {
            let (data,response)=try await Self.network.data(for:req)
            guard let response=response as? HTTPURLResponse else {throw URLError(.badServerResponse)}
            guard (200...299).contains(response.statusCode) else {
                let message=response.statusCode == 401 ? "Не подходит ключ доступа к серверу или токен аккаунта":"Сервер вернул HTTP \(response.statusCode)"
                throw NSError(domain:"stupidchat.relay",code:response.statusCode,userInfo:[NSLocalizedDescriptionKey:message])
            }
            let decoded=try JSONDecoder().decode(T.self,from:data)
            connection="Сервер доступен"; return decoded
        } catch {
            if server == nil && path != "register" {
                let previous=state.server
                if (try? await refreshEndpoint(force:true)) == true && state.server != previous {
                    return try await request(path,body:body,server:state.server,query:query)
                }
            }
            connection="Нет связи · повторим автоматически"; throw error
        }
    }
    @discardableResult func refreshEndpoint(force: Bool = false) async throws -> Bool {
        if let pending=endpointResolution {return try await pending.value}
        let task=Task { @MainActor in try await self.resolveEndpoint(force:force) }
        endpointResolution=task;defer {endpointResolution=nil}
        return try await task.value
    }
    private func resolveEndpoint(force: Bool) async throws -> Bool {
        guard !previewMode,!resolvingEndpoint,state.automaticEndpoint != false,
              let discovery=Deployment.discoveryURL,let key=Deployment.discoveryPublicKey,
              Date().timeIntervalSince(force ? lastForcedEndpointAttempt:lastEndpointAttempt) >= (force ? 15:60) else {return false}
        resolvingEndpoint=true
        if force {lastForcedEndpointAttempt=Date()} else {lastEndpointAttempt=Date()}
        defer {resolvingEndpoint=false}
        do {return try await fetchAndApplyEndpoint(discovery,key:key,probe:force)}
        catch {
            guard (force || state.lastEndpointIssuedAt == nil),let fallback=Deployment.discoveryFallbackURL else {throw error}
            return try await fetchAndApplyEndpoint(fallback,key:key,probe:true)
        }
    }
    private func fetchAndApplyEndpoint(_ discovery: URL,key: Data,probe: Bool) async throws -> Bool {
        var components=URLComponents(url:discovery,resolvingAgainstBaseURL:false)!
        components.queryItems=(components.queryItems ?? [])+[URLQueryItem(name:"v",value:String(Int(Date().timeIntervalSince1970/15)))]
        var req=URLRequest(url:components.url!,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:8)
        req.setValue("no-cache",forHTTPHeaderField:"Cache-Control")
        req.setValue("application/vnd.github.raw+json",forHTTPHeaderField:"Accept")
        req.setValue("stupidchat",forHTTPHeaderField:"User-Agent")
        // No relay credential or account token is ever sent to either discovery host.
        let (data,response)=try await Self.network.data(for:req)
        guard let http=response as? HTTPURLResponse,http.statusCode == 200 else {
            throw NSError(domain:"stupidchat.discovery",code:(response as? HTTPURLResponse)?.statusCode ?? -1,userInfo:[NSLocalizedDescriptionKey:"Сервис адресов вернул HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        let signed=try EndpointDiscovery.verify(data,publicKey:key,lastIssuedAt:state.lastEndpointIssuedAt)
        lastDiscoveredURL=signed.url
        if probe || signed.url != state.server {
            if let account=state.account {let _: OK=try await request("session/\(account.id)",server:signed.url)}
            else {let _: OK=try await request("health",server:signed.url)}
        }
        if signed.url != state.server || signed.issuedAt != state.lastEndpointIssuedAt {
            let oldServer=state.server,oldTime=state.lastEndpointIssuedAt
            state.server=signed.url;state.lastEndpointIssuedAt=signed.issuedAt
            do {try save()} catch {state.server=oldServer;state.lastEndpointIssuedAt=oldTime;throw error}
        }
        return true
    }
    func changeServer(_ address: String) async {
        guard !busy else { return }; busy=true; defer {busy=false}
        let candidate=address.trimmingCharacters(in:.whitespacesAndNewlines)
        do {
            if let account=state.account {
                let _: OK=try await request("session/\(account.id)",server:candidate)
            } else { let _: OK=try await request("health",server:candidate) }
            let previous=state.server,previousAutomatic=state.automaticEndpoint
            state.server=candidate
            state.automaticEndpoint = candidate == Deployment.serverURL || Deployment.legacyURLs.contains(candidate) || candidate == lastDiscoveredURL
            do { try save() } catch { state.server=previous;state.automaticEndpoint=previousAutomatic;throw error }
        } catch { self.error="Не удалось подключиться к этому адресу. Используйте адрес того же сервера: \(error.localizedDescription)" }
    }
    struct OK: Decodable { let ok: Bool }
    func register() async {
        guard !busy else { return }; busy=true; defer {busy=false}
        do { if state.account == nil { state.account=try await request("register",body:Data("{}".utf8)); try save() } } catch { self.error="Сервер недоступен: \(error.localizedDescription)" }
    }
    var relayAccessKey: String {
        let custom=state.relayAccessKey?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? Deployment.accessKey:custom
    }
    var unreadCount: Int { state.messages.filter { !$0.mine && $0.visible && $0.date > (state.lastReadAt ?? .distantPast) }.count }
    func markRead() { state.lastReadAt=Date(); persist() }
    func archive(_ value: Bool) { state.archived=value; persist() }
    var invitation: String {
        guard let account=state.account, let identity else { return "" }
        return (try? JSONEncoder().encode(Invite(id:account.id,key:identity.publicKey.rawRepresentation,name:state.profile.name,server:state.server)).base64EncodedString()) ?? ""
    }
    func addPeer(_ code: String) {
        do {
            guard state.peer == nil, let data=Data(base64Encoded:code.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw URLError(.cannotDecodeContentData) }
            let peer=try JSONDecoder().decode(Invite.self,from:data)
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation:peer.key)
            guard peer.id != state.account?.id else { throw URLError(.badURL) }
            state.peer=peer; state.remoteProfile.name=peer.name; try save(); Task {await publishProfileIfNeeded()}
        } catch { self.error="Неверное приглашение или контакт уже добавлен" }
    }
    func sharedKey() throws -> SymmetricKey {
        guard let identity, let peer=state.peer, let account=state.account else { throw URLError(.userAuthenticationRequired) }
        let secret=try identity.sharedSecretFromKeyAgreement(with:Curve25519.KeyAgreement.PublicKey(rawRepresentation:peer.key))
        let context=[account.id,peer.id].sorted().joined(separator:":")
        return secret.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data("Tiho-v1".utf8),sharedInfo:Data(context.utf8),outputByteCount:32)
    }
    var fingerprint: String {
        guard let identity, let peer=state.peer else { return "" }
        let keys=[identity.publicKey.rawRepresentation.base64EncodedString(),peer.key.base64EncodedString()].sorted().joined()
        return SHA256.hash(data:Data(keys.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    @discardableResult func send(text: String = "", kind: String = "text", data: Data? = nil, target: String? = nil) async -> Bool {
        guard !busy,!previewMode,let peer=state.peer else {return false}
        do {
            guard (state.outbox?.count ?? 0)<50 else {throw NSError(domain:"stupidchat",code:1,userInfo:[NSLocalizedDescriptionKey:"Сначала дождитесь отправки сообщений из очереди"])}
            if let data,data.count>18*1024*1024 {throw NSError(domain:"Вложение больше 18 МБ",code:1)}
            var message=Message(text:text,kind:kind,data:data,target:target)
            if let target {
                guard let original=state.messages.first(where:{$0.id==target}),original.mine,original.visible,
                      kind=="delete" || (kind=="edit" && original.kind=="text" && !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) else {return false}
            }
            // Ordinary text must never carry profile images or a banner.
            if kind == "profile" {message.profile=state.profile}
            let plain=try JSONEncoder().encode(message)
            guard plain.count<=20*1024*1024 else {throw NSError(domain:"Сообщение больше 20 МБ",code:1)}
            let body=try ChaChaPoly.seal(plain,using:sharedKey(),authenticating:Data(message.id.utf8)).combined.base64EncodedString()
            let original=state
            message.profile=nil;message.delivery="pending"
            if target != nil { applyChange(message) } else {state.messages.append(message)}
            if state.outbox == nil {state.outbox=[]}
            state.outbox?.append(PendingEnvelope(recipient:peer.id,envelope:Envelope(id:message.id,body:body),silent:target != nil || kind=="profile"))
            do {try save()} catch {state=original;throw error}
            Task {await flushOutbox()}
            return true
        } catch {self.error="Не удалось подготовить сообщение. \(error.localizedDescription)";return false}
    }
    func applyChange(_ event: Message) {
        guard let target=event.target, event.kind=="edit" || event.kind=="delete" else {return}
        guard let index=state.messages.firstIndex(where:{$0.id==target}) else {
            if let previous=state.pendingChanges?[target],previous.kind=="delete" || (event.kind=="edit" && previous.date>=event.date) {return}
            if state.pendingChanges == nil {state.pendingChanges=[:]}
            state.pendingChanges?[target]=event
            return
        }
        let original=state.messages[index]
        guard original.mine==event.mine,original.visible else {return}
        if event.kind=="delete" {
            state.messages[index].deleted=true
            state.messages[index].text=""
            state.messages[index].data=nil
        } else if original.kind=="text",event.date >= (original.edited ?? .distantPast) {
            state.messages[index].text=event.text
            state.messages[index].edited=event.date
        }
    }
    func flushOutbox() async {
        if let running=outboxTask {await running.value;return}
        let task=Task { @MainActor in await self.deliverPending() }
        outboxTask=task;defer {outboxTask=nil}
        await task.value
    }
    private func deliverPending() async {
        guard !previewMode,!busy,Date()>=nextSendAttempt else {return}
        // Re-evaluate priority after every piece, so text can pass a large profile upload.
        while let pending=state.outbox?.min(by:{$0.envelope.body.count<$1.envelope.body.count}) {
            do {
                let quiet = pending.silent == true || state.messages.contains {$0.id == pending.id && $0.kind == "profile"}
                let options = quiet ? [URLQueryItem(name:"silent",value:"1")] : []
                let complete: Bool
                if pending.envelope.body.utf8.count<=32768 {
                    let _: OK=try await request("send/\(pending.recipient)",body:JSONEncoder().encode(pending.envelope),query:options);complete=true
                } else {
                    let bytes=Array(pending.envelope.body.utf8),total=(bytes.count+32767)/32768
                    let index=min(pending.nextPiece,total-1)
                    let start=index*32768,end=min(start+32768,bytes.count)
                    let piece=CipherPiece(id:pending.id,index:index,total:total,body:String(decoding:bytes[start..<end],as:UTF8.self))
                    let result: ChunkReply=try await request("chunk/\(pending.recipient)",body:JSONEncoder().encode(piece),query:options);complete=result.complete
                    if !complete,let index=state.outbox?.firstIndex(where:{$0.id==pending.id}) {state.outbox?[index].nextPiece = pending.nextPiece+1 < total ? pending.nextPiece+1:0}
                }
                if complete {
                    state.outbox?.removeAll {$0.id==pending.id}
                    if let index=state.messages.firstIndex(where:{$0.id==pending.id}) {state.messages[index].delivery=nil}
                }
                try save();retryCount=0;nextSendAttempt = .distantPast
            } catch {
                retryCount+=1;nextSendAttempt=Date().addingTimeInterval(min(30,pow(2,Double(min(retryCount,4)))))
                connection="Сообщение в очереди · повторим автоматически"
                try? save();return
            }
        }
    }
    var profileUploadProgress: Double? {
        let profileIDs=Set(state.messages.filter {$0.kind == "profile"}.map(\.id))
        guard let pending=state.outbox?.last(where:{profileIDs.contains($0.id)}) else {return nil}
        let count=max(1,(pending.envelope.body.utf8.count+32767)/32768)
        return Double(pending.nextPiece)/Double(count)
    }
    func publishProfileIfNeeded(force: Bool = false) async {
        guard !previewMode,!publishingProfile,state.peer != nil else {return}
        let refresh = Date().timeIntervalSince(state.profilePublishedAt ?? .distantPast) > 86400
        if !force && !refresh && checkedProfile == state.profile {return}
        publishingProfile=true;defer {publishingProfile=false}
        state.profile.avatar=Self.optimizedImage(state.profile.avatar,maxDimension:320,targetBytes:128*1024,preserveGIF:true)
        state.profile.banner=Self.optimizedImage(state.profile.banner,maxDimension:960,targetBytes:192*1024,preserveGIF:false)
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        guard let data=try? encoder.encode(state.profile) else {return}
        let hash=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
        guard refresh || force || hash != state.lastProfileHash else {checkedProfile=state.profile;return}
        let snapshot=state.profile
        if await send(kind:"profile") {state.lastProfileHash=hash;checkedProfile=snapshot;state.profilePublishedAt=Date();persist()}
    }
    static func optimizedImage(_ data: Data?,maxDimension: CGFloat,targetBytes: Int,preserveGIF: Bool) -> Data? {
        guard let data else {return nil}
        if preserveGIF && String(data:data.prefix(3),encoding:.ascii)=="GIF" {return data}
        guard let image=UIImage(data:data) else {return data}
        let longest=max(image.size.width,image.size.height)
        if longest<=maxDimension && data.count<=targetBytes {return data}
        let ratio=min(1,maxDimension/longest),size=CGSize(width:image.size.width*ratio,height:image.size.height*ratio)
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        return UIGraphicsImageRenderer(size:size,format:format).image {_ in image.draw(in:CGRect(origin:.zero,size:size))}.jpegData(compressionQuality:0.72) ?? data
    }
    func poll() async {
        guard !previewMode,!busy else {return}
        await publishProfileIfNeeded()
        Task {await flushOutbox()}
        guard let account=state.account,let peer=state.peer else {
            do {
                if let account=state.account {let _: OK=try await request("session/\(account.id)")}
                else {let _: OK=try await request("health")}
            } catch {connection="Нет связи · повторим автоматически"}
            return
        }
        do {
            let inbox: Inbox=try await request("inbox/\(account.id)",query:[URLQueryItem(name:"chunked",value:"1"),URLQueryItem(name:"peer",value:peer.id)])
            peerOnline=inbox.peerOnline
            if inbox.messages.isEmpty {return}
            var ids=[String](),changed=false
            for envelope in inbox.messages {
                if state.messages.contains(where:{$0.id==envelope.id}) {ids.append(envelope.id);continue}
                var body=envelope.body
                if let count=envelope.parts {
                    guard (1...2048).contains(count) else {continue}
                    var pieces=downloads[envelope.id] ?? [:]
                    let missing=(0..<count).filter {pieces[$0]==nil}.prefix(4)
                    let fetched=await withTaskGroup(of:(Int,String?).self) {group in
                        for index in missing {
                            group.addTask { @MainActor in
                                let part: DownloadPiece?=try? await self.request("piece/\(account.id)",query:[URLQueryItem(name:"message",value:envelope.id),URLQueryItem(name:"index",value:String(index))])
                                return (index,part?.body)
                            }
                        }
                        var result=[Int:String]();for await (index,text) in group {if let text {result[index]=text}};return result
                    }
                    pieces.merge(fetched) {_,new in new};downloads[envelope.id]=pieces;attachmentProgress=Double(pieces.count)/Double(count)
                    if pieces.count != count {continue}
                    body=(0..<count).compactMap {pieces[$0]}.joined()
                }
                guard let data=Data(base64Encoded:body) else {continue}
                guard let plain=try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined:data),using:sharedKey(),authenticating:Data(envelope.id.utf8)), var message=try? JSONDecoder().decode(Message.self,from:plain) else {continue}
                guard message.id==envelope.id else {continue}
                message.mine=false;message.delivery=nil
                if let profile=message.profile,message.date >= (state.remoteProfileDate ?? .distantPast) {state.remoteProfile=profile;state.remoteProfileDate=message.date}
                message.profile=nil
                if message.kind=="edit" || message.kind=="delete" {applyChange(message)}
                else {
                    state.messages.append(message)
                    if let change=state.pendingChanges?.removeValue(forKey:message.id) {applyChange(change)}
                }
                ids.append(envelope.id);downloads.removeValue(forKey:envelope.id);attachmentProgress=downloads.isEmpty ? nil:attachmentProgress;changed=true
            }
            if changed {state.messages.sort {$0.date<$1.date}}
            if !ids.isEmpty {try save();let _: OK=try await request("ack/\(account.id)",body:JSONEncoder().encode(["ids":ids]))}
        } catch {peerOnline=nil;connection="Нет связи · повторим автоматически"}
    }
    func toggleRecording() async {
        if recording {
            recorder?.stop(); recording=false
            if let url=recorder?.url, let data=try? Data(contentsOf:url) { try? FileManager.default.removeItem(at:url); await send(kind:"voice",data:data) }
            return
        }
        let allowed=await AVAudioApplication.requestRecordPermission()
        guard allowed else { error="Разрешите доступ к микрофону в Настройках"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,mode:.default,options:[.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            recorder=try AVAudioRecorder(url:URL.temporaryDirectory.appendingPathComponent("voice.m4a"),settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:44100,AVNumberOfChannelsKey:1,AVEncoderAudioQualityKey:AVAudioQuality.high.rawValue])
            recorder?.record(forDuration:120); recording=true
        } catch { self.error=error.localizedDescription }
    }
    func play(_ data: Data) { do { player=try AVAudioPlayer(data:data); player?.play() } catch { self.error=error.localizedDescription } }
}
