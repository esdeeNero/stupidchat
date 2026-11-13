import SwiftUI
import PhotosUI
import AVKit
import WebKit
import UniformTypeIdentifiers

@main struct TihoApp: App {
    @StateObject var chat = Chat()
    var body: some Scene { WindowGroup { RootView().environmentObject(chat).preferredColorScheme(.dark) } }
}
let accent = Color(red:0.50,green:0.90,blue:0.76)
struct AnimatedImage: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> WKWebView {
        let config=WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view=WKWebView(frame:.zero,configuration:config); view.isOpaque=false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled=false; view.isUserInteractionEnabled=false
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0;background:transparent}img{width:100%;height:100%;object-fit:cover;position:absolute}</style><img src='data:image/gif;base64,\(data.base64EncodedString())'>",baseURL:nil)
    }
}
struct Avatar: View {
    let profile: Profile
    var body: some View {
        ZStack { Circle().fill(accent.opacity(0.18)); Text(String(profile.name.prefix(1))).font(.title.bold()).foregroundStyle(accent)
            if let data=profile.avatar { AnimatedImage(data:data) }
        }.frame(width:48,height:48).clipShape(Circle())
    }
}
struct RootView: View {
    @EnvironmentObject var chat: Chat
    @Environment(\.scenePhase) var phase
    @State var settings=false
    @State var text=""
    @State var selection: PhotosPickerItem?
    @State var filePicker=false
    @State var preview: URL?
    @State var showVideo=false
    @State var showProfile=false
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red:0.045,green:0.065,blue:0.085).ignoresSafeArea()
                VStack(spacing:0) {
                    HStack(spacing:12) {
                        Avatar(profile:chat.state.remoteProfile).onTapGesture { if chat.state.peer != nil { showProfile=true } }
                        VStack(alignment:.leading,spacing:4) {
                            Text(chat.state.peer == nil ? "Тихо" : chat.state.remoteProfile.name).font(.headline)
                            Label(chat.connection,systemImage:"network").font(.caption2).foregroundStyle(accent)
                        }
                        Spacer()
                        Button { settings=true } label: { Image(systemName:"slider.horizontal.3").font(.title3).foregroundStyle(.white) }
                    }.padding().background(.white.opacity(0.035))
                    if chat.state.peer == nil {
                        Spacer()
                        Image(systemName:"bubble.left.and.bubble.right.fill").font(.system(size:64)).foregroundStyle(accent).padding()
                        Text("Разговор только для вас").font(.title2.bold())
                        Text("Подключите сервер и обменяйтесь\nприглашениями с близким человеком.").multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                        Button("Настроить Тихо") { settings=true }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        Spacer()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing:12) {
                                    Text("ЛИЧНОЕ ПРОСТРАНСТВО").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(3).foregroundStyle(.secondary).padding(.vertical,22)
                                    ForEach(chat.state.messages) { message in
                                        HStack {
                                            if message.mine { Spacer(minLength:40) }
                                            VStack(alignment:.leading,spacing:8) {
                                                if message.kind == "photo", let data=message.data, let image=UIImage(data:data) { Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:260).clipShape(RoundedRectangle(cornerRadius:14)) }
                                                if message.kind == "voice", let data=message.data { Button { chat.play(data) } label: { Label("Голосовое сообщение",systemImage:"play.circle.fill").padding(6) }.tint(accent) }
                                                if message.kind == "video", let data=message.data { Button { let url=URL.temporaryDirectory.appendingPathComponent("\(message.id).mov"); do { try data.write(to:url,options:.completeFileProtection); preview=url; showVideo=true } catch { chat.error=error.localizedDescription } } label: { Label("Смотреть видео",systemImage:"play.rectangle.fill").padding() }.tint(accent) }
                                                if !message.text.isEmpty { Text(message.text).font(.body) }
                                                Text(message.date,style:.time).font(.system(size:10)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.trailing)
                                            }.padding(12).frame(maxWidth:280,alignment:.leading).background(message.mine ? accent.opacity(0.16):Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:20))
                                            if !message.mine { Spacer(minLength:40) }
                                        }.id(message.id)
                                    }
                                }.padding(.horizontal)
                            }.onChange(of:chat.state.messages.count) { _,_ in if let id=chat.state.messages.last?.id { withAnimation { proxy.scrollTo(id,anchor:.bottom) } } }
                        }
                        HStack(spacing:12) {
                            Menu {
                                PhotosPicker(selection:$selection,matching:.any(of:[.images,.videos])) { Label("Фото или видео",systemImage:"photo") }
                                Button { filePicker=true } label: { Label("Выбрать файл фото/видео",systemImage:"folder") }
                            } label: { Image(systemName:"plus").font(.title2).foregroundStyle(accent) }
                            TextField("Сообщение",text:$text,axis:.vertical).lineLimit(1...5)
                            Button { Task { await chat.toggleRecording() } } label: { Image(systemName:chat.recording ? "stop.circle.fill":"mic.fill").foregroundStyle(chat.recording ? .red:accent) }
                            Button { let value=text; Task { await chat.send(text:value); if chat.error.isEmpty {text=""} } } label: { Image(systemName:"arrow.up.circle.fill").font(.title).foregroundStyle(accent) }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || chat.busy)
                        }.padding().background(.white.opacity(0.04))
                        if chat.recording { Text("Идёт запись · нажмите стоп для отправки").font(.caption).foregroundStyle(.red).padding(6) }
                    }
                }
            }.toolbar(.hidden,for:.navigationBar)
        }
        .sheet(isPresented:$settings) { SettingsView() }
        .sheet(isPresented:$showProfile) { PeerProfileView(profile:chat.state.remoteProfile) }
        .sheet(isPresented:$showVideo,onDismiss:{ if let preview { try? FileManager.default.removeItem(at:preview) }; preview=nil }) { if let preview { VideoPlayer(player:AVPlayer(url:preview)).ignoresSafeArea() } }
        .alert("Тихо",isPresented:Binding(get:{!chat.error.isEmpty},set:{if !$0 {chat.error=""}})) { Button("Понятно") {chat.error=""} } message: { Text(chat.error) }
        .task { while !Task.isCancelled { if phase == .active { await chat.poll() }; try? await Task.sleep(for:.seconds(3)) } }
        .onChange(of:selection) { _,item in Task { do { if let data=try await item?.loadTransferable(type:Data.self) { await chat.send(kind:item?.supportedContentTypes.contains(where:{$0.conforms(to:.movie)}) == true ? "video":"photo",data:data) } } catch { chat.error=error.localizedDescription }; selection=nil } }
        .fileImporter(isPresented:$filePicker,allowedContentTypes:[.image,.movie]) { result in
            do { let url=try result.get(); let allowed=url.startAccessingSecurityScopedResource(); defer {if allowed {url.stopAccessingSecurityScopedResource()}}; let data=try Data(contentsOf:url); let movie=(try? url.resourceValues(forKeys:[.contentTypeKey]).contentType?.conforms(to:.movie)) ?? false; Task { await chat.send(kind:movie ? "video":"photo",data:data) } } catch {chat.error=error.localizedDescription}
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject var chat: Chat
    @Environment(\.dismiss) var dismiss
    @State var invite=""
    @State var avatar: PhotosPickerItem?
    @State var banner: PhotosPickerItem?
    @State var serverAddress=""
    var profileSection: some View {
                Section {
                    ZStack(alignment:.bottomLeading) {
                        LinearGradient(colors:[accent.opacity(0.6),.indigo,.black],startPoint:.topLeading,endPoint:.bottomTrailing)
                        if let data=chat.state.profile.banner, let image=UIImage(data:data) { Image(uiImage:image).resizable().scaledToFill().frame(height:140).clipped() }
                        HStack { Avatar(profile:chat.state.profile); Text(chat.state.profile.name).font(.title2.bold()) }.padding()
                    }.frame(height:140).listRowInsets(EdgeInsets())
                    TextField("Имя",text:$chat.state.profile.name)
                    TextField("О себе",text:$chat.state.profile.bio)
                    PhotosPicker("Фото или GIF на аватарку",selection:$avatar,matching:.images)
                    PhotosPicker("Изменить баннер",selection:$banner,matching:.images)
                    Button("Отправить обновлённый профиль") { Task { await chat.send(text:"Обновлён профиль",kind:"profile") } }.disabled(chat.state.peer == nil)
                } header: { Text("Мой профиль") }
    }
    var body: some View {
        NavigationStack {
            Form {
                profileSection
                Section {
                    TextField("https://адрес-сервера",text:$serverAddress).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Проверить и сохранить адрес") { Task { await chat.changeServer(serverAddress) } }.disabled(chat.busy)
                    Text(chat.connection).font(.caption).foregroundStyle(accent)
                    Button(chat.state.account == nil ? "Подключиться и создать адрес":"Адрес создан") { Task { await chat.changeServer(serverAddress); if chat.error.isEmpty { await chat.register() } } }.disabled(chat.busy || chat.state.account != nil)
                    Text("Работает через мобильный интернет и Wi-Fi. На обоих телефонах нужен один HTTPS-адрес. Если адрес туннеля изменился, укажите новый здесь: ключи и история сохранятся. Mac с сервером должен оставаться включённым.").font(.caption).foregroundStyle(.secondary)
                } header: {Text("Сервер")}
                if !chat.invitation.isEmpty {
                    Section("Приглашение") {
                        ShareLink(item:chat.invitation) { Label("Поделиться моим приглашением",systemImage:"square.and.arrow.up") }
                        Text("Передайте лично или через доверенный канал. Оба участника должны добавить приглашение друг друга.").font(.caption)
                        if chat.state.peer == nil {
                            TextField("Вставьте приглашение собеседника",text:$invite,axis:.vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Добавить контакт") { chat.addPeer(invite) }
                        }
                    }
                }
                if chat.state.peer != nil {
                    Section("Проверка безопасности") {
                        Text(chat.fingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        Text("Сверьте весь код на обоих iPhone лично или голосом. Он должен совпадать. Эта версия не поддерживает смену контакта.").font(.caption)
                    }
                }
                Section("О версии") {
                    Text("Тихо · прототип 0.2").foregroundStyle(accent)
                    Text("Ключи в Keychain. История зашифрована на устройстве. Сервер видит адреса доставки, размеры и время. Нет push-уведомлений: получение работает при открытом приложении. Нет Double Ratchet и forward secrecy; аудит безопасности не проводился.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Личное пространство").toolbar { Button("Готово") { chat.persist(); dismiss() } }.tint(accent)
        }
        .onAppear { serverAddress=chat.state.server }
        .onChange(of:avatar) { _,item in Task { if let data=try? await item?.loadTransferable(type:Data.self), data.count<2*1024*1024 { chat.state.profile.avatar=data; chat.persist() } else {chat.error="Аватарка должна быть меньше 2 МБ"} } }
        .onChange(of:banner) { _,item in Task { if let data=try? await item?.loadTransferable(type:Data.self), data.count<2*1024*1024 { chat.state.profile.banner=data; chat.persist() } else {chat.error="Баннер должен быть меньше 2 МБ"} } }
        .onDisappear { chat.persist() }
    }
}

struct PeerProfileView: View {
    let profile: Profile
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing:20) {
                ZStack {
                    LinearGradient(colors:[accent.opacity(0.5),.indigo,.black],startPoint:.topLeading,endPoint:.bottomTrailing)
                    if let data=profile.banner, let image=UIImage(data:data) { Image(uiImage:image).resizable().scaledToFill().frame(height:200).clipped() }
                }.frame(height:200)
                Avatar(profile:profile).scaleEffect(1.5).padding()
                Text(profile.name).font(.largeTitle.bold())
                Text(profile.bio).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                Label("Личная переписка",systemImage:"lock.fill").font(.caption).foregroundStyle(accent)
                Spacer()
            }.ignoresSafeArea(edges:.top).toolbar { Button("Готово") { dismiss() } }.tint(accent)
        }
    }
}
