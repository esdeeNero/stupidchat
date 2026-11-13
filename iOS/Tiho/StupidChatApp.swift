import SwiftUI
import PhotosUI
import AVKit
import WebKit
import UniformTypeIdentifiers

@main struct StupidChatApp: App {
    @UIApplicationDelegateAdaptor(PushRegistration.self) var push
    @AppStorage("appearance") var appearance = "Системная"
    @AppStorage("palette") var palette = Palette.ocean
    @StateObject private var chat = Chat(preview: Self.previewEnabled)
    private static var previewEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview")
        #else
        false
        #endif
    }
    var body: some Scene { WindowGroup { RootView().environmentObject(chat).tint(palette.color).preferredColorScheme(appearance == "Светлая" ? .light : appearance == "Тёмная" ? .dark : nil) } }
}
enum Palette: String, CaseIterable {
    case ocean = "Океан", lilac = "Сирень", forest = "Лес"
    var color: Color {
        switch self {
        case .ocean: Color(red:0.15,green:0.51,blue:0.84)
        case .lilac: Color(red:0.57,green:0.38,blue:0.82)
        case .forest: Color(red:0.12,green:0.54,blue:0.40)
        }
    }
}
struct AppearanceView: View {
    @AppStorage("appearance") var appearance = "Системная"
    @AppStorage("palette") var palette = Palette.ocean
    @AppStorage("pattern") var pattern = true
    var body: some View {
        Form {
            Section {
                ZStack {
                    ChatWallpaper()
                    VStack(spacing:8) {
                        MessageBubble(message:Message(text:"Привет!",mine:false),onPlay:{},onVideo:{})
                        MessageBubble(message:Message(text:"Увидимся вечером?"),onPlay:{},onVideo:{})
                    }.padding(12)
                }.clipShape(RoundedRectangle(cornerRadius:16)).listRowInsets(EdgeInsets())
            }
            Picker("Тема",selection:$appearance) { ForEach(["Системная","Светлая","Тёмная"],id:\.self) {Text($0)} }
            Picker("Цвет",selection:$palette) {ForEach(Palette.allCases,id:\.self) {Text($0.rawValue).tag($0)}}
            Toggle("Узор в чате",isOn:$pattern)
        }.navigationTitle("Оформление")
    }
}
enum ChatTheme {
    static let background=Color(uiColor:.systemGroupedBackground)
    static let outgoing=Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.15,green:0.30,blue:0.43,alpha:1):UIColor(red:0.85,green:0.94,blue:1,alpha:1) })
    static let incoming=Color(uiColor:.secondarySystemGroupedBackground)
    static let wallpaper=Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.06,green:0.10,blue:0.15,alpha:1):UIColor(red:0.91,green:0.94,blue:0.96,alpha:1) })
}
struct AnimatedImage: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> WKWebView {
        let config=WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view=WKWebView(frame:.zero,configuration:config)
        view.isOpaque=false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled=false; view.isUserInteractionEnabled=false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard view.url == nil else { return }
        view.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0;background:transparent}img{width:100%;height:100%;object-fit:cover;position:absolute}</style><img src='data:image/gif;base64,\(data.base64EncodedString())'>",baseURL:nil)
    }
}
struct Avatar: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    let profile: Profile
    var size: CGFloat = 52
    var body: some View {
        ZStack {
            LinearGradient(colors:[accent,Color(red:0.48,green:0.39,blue:0.84)],startPoint:.topLeading,endPoint:.bottomTrailing)
            Text(String(profile.name.prefix(1)).uppercased()).font(.system(size:size*0.40,weight:.semibold)).foregroundStyle(.white)
            if let data=profile.avatar {
                if String(data:data.prefix(3),encoding:.ascii)=="GIF" {AnimatedImage(data:data).id(data.hashValue)}
                else if let image=UIImage(data:data) {Image(uiImage:image).resizable().scaledToFill()}
            }
        }.frame(width:size,height:size).clipShape(Circle()).accessibilityLabel("Аватар: \(profile.name)")
    }
}
struct RootView: View {
    @EnvironmentObject var chat: Chat
    @Environment(\.scenePhase) var phase
    @State private var selected=1
    var body: some View {
        TabView(selection:$selected) {
            ContactsView().tabItem { Label("Контакты",systemImage:"person.crop.circle") }.tag(0)
            ChatListView().tabItem { Label("Чаты",systemImage:"bubble.left.and.bubble.right.fill") }.badge(chat.unreadCount).tag(1)
            SettingsView().tabItem { Label("Настройки",systemImage:"gearshape") }.tag(2)
        }
        .alert("stupidchat",isPresented:Binding(get:{!chat.error.isEmpty},set:{if !$0 {chat.error=""}})) {
            Button("Понятно") { chat.error="" }
        } message: { Text(chat.error) }
        .task(id:phase) { guard phase == .active else {chat.peerOnline=nil;return}; if PushRegistration.supported && UserDefaults.standard.bool(forKey:"pushEnabled") { UIApplication.shared.registerForRemoteNotifications() }; while !Task.isCancelled { await chat.poll(); try? await Task.sleep(for:.seconds(3)) } }
    }
}
struct ChatListView: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    @EnvironmentObject var chat: Chat
    @State private var search=""
    @State private var filter="Все"
    @State private var addContact=false
    @State private var archives=false
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                HStack(spacing:24) {
                    ForEach(["Все","Непрочитанные","Медиа"],id:\.self) { item in
                        Button { filter=item } label: {
                            VStack(spacing:10) {
                                Text(item).font(.subheadline.weight(.semibold))
                                Capsule().fill(filter == item ? accent:.clear).frame(height:3)
                            }.foregroundStyle(filter == item ? accent:Color.secondary)
                        }.buttonStyle(.plain).fixedSize(horizontal:true,vertical:false)
                    }
                    Spacer(minLength:0)
                }.padding(.horizontal,20).padding(.top,8).background(Color(uiColor:.systemBackground))
                if chat.state.peer == nil { emptyInbox }
                else {
                    List {
                        if chat.state.archived == true {
                            Button { archives.toggle() } label: {
                                HStack(spacing:16) {
                                    Image(systemName:"archivebox.fill").font(.title2).frame(width:56,height:56).foregroundStyle(.white).background(.gray,in:Circle())
                                    VStack(alignment:.leading,spacing:4) { Text("Архив").font(.headline).foregroundStyle(.primary); Text(chat.state.remoteProfile.name).font(.subheadline).foregroundStyle(.secondary) }
                                    Spacer(); Image(systemName:archives ? "chevron.up":"chevron.down").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if visible && (chat.state.archived != true || archives) {
                            NavigationLink { ConversationView() } label: { ConversationRow() }.accessibilityIdentifier("conversationRow")
                                .swipeActions(edge:.trailing) { Button { chat.archive(chat.state.archived != true) } label: { Label(chat.state.archived == true ? "Вернуть":"В архив",systemImage:"archivebox") }.tint(accent) }
                                .contextMenu { Button(chat.state.archived == true ? "Вернуть из архива":"В архив",systemImage:"archivebox") { chat.archive(chat.state.archived != true) } }
                        } else if chat.state.archived != true {
                            ContentUnavailableView.search(text:search).listRowSeparator(.hidden)
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Чаты").navigationBarTitleDisplayMode(.large)
            .searchable(text:$search,prompt:"Поиск сообщений и людей")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Image("StupidLogo").resizable().frame(width:30,height:30).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel("stupidchat") }
                ToolbarItem(placement:.topBarTrailing) { Button { addContact=true } label: { Image(systemName:"square.and.pencil") }.accessibilityLabel("Добавить контакт") }
            }
            .sheet(isPresented:$addContact) { NavigationStack {ConnectionView()} }
        }
    }
    private var visible: Bool {
        let matches=search.isEmpty || chat.state.remoteProfile.name.localizedCaseInsensitiveContains(search) || chat.state.messages.contains { $0.visible && $0.text.localizedCaseInsensitiveContains(search) }
        return matches && (filter != "Непрочитанные" || chat.unreadCount>0) && (filter != "Медиа" || chat.state.messages.contains { $0.visible && ["photo","video","voice"].contains($0.kind) })
    }
    private var emptyInbox: some View {
        VStack(spacing:18) {
            Spacer()
            Image("StupidLogo").resizable().scaledToFit().frame(width:112,height:112).clipShape(RoundedRectangle(cornerRadius:27))
            Text("Начни с одного «привет»").font(.title2.bold())
            Text("Добавь близкого человека.\nВаш разговор останется вашим.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { addContact=true } label: { Label("Начать общение",systemImage:"square.and.pencil").font(.headline).padding(.horizontal,20).padding(.vertical,10) }.buttonStyle(.borderedProminent).clipShape(Capsule())
            Spacer(); Label("Сквозное шифрование",systemImage:"lock.fill").font(.caption).foregroundStyle(.secondary).padding(.bottom,28)
        }.frame(maxWidth:.infinity).background(ChatTheme.background)
    }
}
struct ConversationRow: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    @EnvironmentObject var chat: Chat
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            Avatar(profile:chat.state.remoteProfile,size:60)
            VStack(alignment:.leading,spacing:7) {
                HStack {
                    Text(chat.state.remoteProfile.name).font(.headline).lineLimit(1)
                    Spacer()
                    if let last=chat.state.messages.last(where:{$0.visible}) { Text(last.date,style:.time).font(.caption).foregroundStyle(.secondary) }
                }
                HStack(alignment:.top) {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                    if chat.unreadCount>0 { Text("\(chat.unreadCount)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,4).background(accent,in:Capsule()) }
                }
            }.padding(.top,3)
        }.padding(.vertical,6)
    }
    private var preview: String {
        guard let last=chat.state.messages.last(where:{$0.visible}) else { return "Написать сообщение" }
        let value: String
        switch last.kind { case "photo": value="📷 Фото"; case "video":value="📹 Видео"; case "voice":value="🎤 Голосовое сообщение"; case "profile":value="Профиль обновлён"; default:value=last.text }
        return (last.mine ? "Вы: ":"")+value
    }
}
struct ContactsView: View {
    @EnvironmentObject var chat: Chat
    @State private var search=""
    @State private var add=false
    var body: some View {
        NavigationStack {
            List {
                Button { add=true } label: { Label("Добавить по приглашению",systemImage:"person.badge.plus") }
                if chat.state.peer != nil && (search.isEmpty || chat.state.remoteProfile.name.localizedCaseInsensitiveContains(search)) {
                    NavigationLink { PeerProfileView() } label: {
                        HStack(spacing:14) { Avatar(profile:chat.state.remoteProfile); VStack(alignment:.leading,spacing:4) { Text(chat.state.remoteProfile.name).font(.headline); Text(chat.state.remoteProfile.bio).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                    }
                } else { Text("Контакты появятся после обмена приглашениями.").font(.subheadline).foregroundStyle(.secondary) }
            }.navigationTitle("Контакты").navigationBarTitleDisplayMode(.inline).searchable(text:$search,prompt:"Поиск")
                .sheet(isPresented:$add) { NavigationStack {ConnectionView()} }
        }
    }
}
struct ChatWallpaper: View {
    @AppStorage("pattern") private var pattern = true
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    var body: some View {
        Canvas { context,size in
            guard pattern else {return}
            for row in 0..<Int(size.height/72)+1 {
                for column in 0..<Int(size.width/72)+1 {
                    let x=CGFloat(column)*72+(row%2 == 0 ? 12:42), y=CGFloat(row)*72+20
                    var star=Path(); star.move(to:CGPoint(x:x-5,y:y)); star.addLine(to:CGPoint(x:x+5,y:y)); star.move(to:CGPoint(x:x,y:y-5)); star.addLine(to:CGPoint(x:x,y:y+5))
                    context.stroke(star,with:.color(accent.opacity(0.08)),lineWidth:1.2)
                    context.stroke(Path(ellipseIn:CGRect(x:x+23,y:y+25,width:8,height:8)),with:.color(accent.opacity(0.07)),lineWidth:1)
                }
            }
        }.background(accent.opacity(0.10).background(ChatTheme.wallpaper)).ignoresSafeArea()
    }
}
struct ConversationView: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    @EnvironmentObject var chat: Chat
    @State private var text=""
    @State private var selection: PhotosPickerItem?
    @State private var filePicker=false
    @State private var preview: URL?
    @State private var showVideo=false
    @State private var profile=false
    @State private var search=""
    @State private var editing: Message?
    @State private var replacement=""
    @State private var removing: Message?
    @State private var searching=false
    var body: some View {
        ZStack {
            ChatWallpaper()
            VStack(spacing:0) {
                if searching { TextField("Поиск в переписке",text:$search).textFieldStyle(.roundedBorder).padding(10).background(.bar) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing:7) {
                            Label("Сообщения зашифрованы",systemImage:"lock.fill").font(.caption2).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,6).background(.thinMaterial,in:Capsule()).padding(.vertical,14)
                            if chat.state.messages.isEmpty { Text("Здесь начинается ваш разговор").font(.subheadline).foregroundStyle(.secondary).padding(24) }
                            ForEach(visibleMessages) { message in
                                MessageBubble(message:message,onPlay:{ if let data=message.data { chat.play(data) } },onVideo:{ openVideo(message) })
                                    .contextMenu {
                                        if message.mine {
                                            if message.kind=="text" {Button("Редактировать",systemImage:"pencil") {replacement=message.text;editing=message}}
                                            Button("Удалить у обоих",systemImage:"trash",role:.destructive) {removing=message}
                                        }
                                    }
                                    .id(message.id)
                            }
                        }.padding(.horizontal,10).padding(.bottom,12)
                    }.scrollDismissesKeyboard(.interactively)
                        .onAppear { if let id=chat.state.messages.last(where:{$0.visible})?.id { proxy.scrollTo(id,anchor:.bottom) }; chat.markRead() }
                        .onChange(of:chat.state.messages.count) { _,_ in if let id=chat.state.messages.last(where:{$0.visible})?.id { withAnimation {proxy.scrollTo(id,anchor:.bottom)} }; chat.markRead() }
                }
            }
        }
        .safeAreaInset(edge:.bottom,spacing:0) { composer }
        .sheet(item:$editing) { message in
            NavigationStack {
                Form { TextField("Текст сообщения",text:$replacement,axis:.vertical) }
                    .navigationTitle("Редактирование")
                    .toolbar {
                        ToolbarItem(placement:.cancellationAction) {Button("Отмена") {editing=nil}}
                        ToolbarItem(placement:.confirmationAction) {Button("Сохранить") {Task {if await chat.send(text:replacement,kind:"edit",target:message.id) {editing=nil}}}.disabled(replacement.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                    }
            }.presentationDetents([.medium,.large])
        }
        .confirmationDialog("Удалить сообщение у обоих?",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}}),titleVisibility:.visible,presenting:removing) {message in
            Button("Удалить у обоих",role:.destructive) {Task {await chat.send(kind:"delete",target:message.id)}}
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden,for:.tabBar)
        .toolbar {
            ToolbarItem(placement:.principal) {
                Button { profile=true } label: {
                    VStack(spacing:2) {
                        Text(chat.state.remoteProfile.name).font(.headline).foregroundStyle(.primary)
                        Text(chat.peerOnline.map { $0 ? "В сети" : "Не в сети" } ?? "Статус неизвестен").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement:.topBarTrailing) { Button {profile=true} label: {Avatar(profile:chat.state.remoteProfile,size:34)}.accessibilityLabel("Профиль собеседника") }
            ToolbarItem(placement:.topBarTrailing) { Button {searching.toggle(); if !searching {search=""}} label: {Image(systemName:"magnifyingglass")}.accessibilityLabel("Поиск в переписке") }
        }
        .sheet(isPresented:$profile) { NavigationStack { PeerProfileView() } }
        .sheet(isPresented:$showVideo,onDismiss:{if let preview {try? FileManager.default.removeItem(at:preview)};preview=nil}) { if let preview { VideoPlayer(player:AVPlayer(url:preview)).ignoresSafeArea() } }
        .onChange(of:selection) { _,item in Task { do { if let data=try await item?.loadTransferable(type:Data.self) { await chat.send(kind:item?.supportedContentTypes.contains(where:{$0.conforms(to:.movie)}) == true ? "video":"photo",data:data) } } catch {chat.error=error.localizedDescription};selection=nil } }
        .fileImporter(isPresented:$filePicker,allowedContentTypes:[.image,.movie]) { result in
            do {
                let url=try result.get();let allowed=url.startAccessingSecurityScopedResource();defer {if allowed {url.stopAccessingSecurityScopedResource()}}
                let data=try Data(contentsOf:url);let movie=(try? url.resourceValues(forKeys:[.contentTypeKey]).contentType?.conforms(to:.movie)) ?? false
                Task {await chat.send(kind:movie ? "video":"photo",data:data)}
            } catch {chat.error=error.localizedDescription}
        }
    }
    private var visibleMessages: [Message] {chat.state.messages.filter {$0.visible && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search))}}
    private var composer: some View {
        VStack(spacing:0) {
            if chat.recording { Text("● Запись · нажмите стоп для отправки").font(.caption).foregroundStyle(.red).padding(.top,8) }
            HStack(alignment:.bottom,spacing:12) {
                Menu {
                    PhotosPicker(selection:$selection,matching:.any(of:[.images,.videos])) {Label("Фото или видео",systemImage:"photo")}
                    Button {filePicker=true} label: {Label("Из файлов",systemImage:"folder")}
                } label: {Image(systemName:"paperclip").font(.system(size:24)).foregroundStyle(.secondary).frame(width:28,height:40)}
                TextField("Сообщение",text:$text,axis:.vertical).lineLimit(1...6).padding(.horizontal,13).padding(.vertical,10).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:20)).accessibilityIdentifier("messageInput")
                if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    Button {Task {await chat.toggleRecording()}} label: {Image(systemName:chat.recording ? "stop.circle.fill":"mic.fill").font(.system(size:25)).frame(width:34,height:40).foregroundStyle(chat.recording ? .red:accent)}.accessibilityLabel(chat.recording ? "Отправить голосовое":"Записать голосовое")
                } else {
                    Button {let value=text;Task {if await chat.send(text:value) {text=""}}} label: {
                        if chat.busy {ProgressView().frame(width:34,height:40)} else {Image(systemName:"arrow.up.circle.fill").font(.system(size:34)).frame(height:40)}
                    }.disabled(chat.busy).accessibilityLabel("Отправить сообщение")
                }
            }.padding(.horizontal,12).padding(.vertical,8)
        }.background(.bar)
    }
    private func openVideo(_ message: Message) {
        guard let data=message.data else {return}
        let url=URL.temporaryDirectory.appendingPathComponent("\(message.id).mov")
        do {try data.write(to:url,options:.completeFileProtection);preview=url;showVideo=true} catch {chat.error=error.localizedDescription}
    }
}
struct MessageBubble: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    let message: Message
    let onPlay: () -> Void
    let onVideo: () -> Void
    var body: some View {
        HStack {
            if message.mine {Spacer(minLength:40)}
            VStack(alignment:.leading,spacing:7) {
                if message.kind == "photo",let data=message.data,let image=UIImage(data:data) {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:280).clipShape(RoundedRectangle(cornerRadius:12))}
                if message.kind == "video" {Button(action:onVideo) {Label("Смотреть видео",systemImage:"play.rectangle.fill").padding(.vertical,20)}.buttonStyle(.plain).foregroundStyle(accent)}
                if message.kind == "voice" {
                    Button(action:onPlay) {
                        HStack(spacing:10) {
                            Image(systemName:"play.circle.fill").font(.system(size:34))
                            Image(systemName:"waveform").font(.title2)
                            Text("Голосовое").font(.subheadline.weight(.medium))
                        }.padding(.vertical,5)
                    }.buttonStyle(.plain).foregroundStyle(accent)
                }
                if !message.text.isEmpty {Text(message.text).textSelection(.enabled)}
                HStack(spacing:4) {
                    if message.edited != nil {Text("изменено").font(.caption2)}
                    Text(message.date,style:.time).font(.system(size:10))
                    if message.mine {Image(systemName:message.delivery == "pending" ? "clock":"checkmark").font(.system(size:10,weight:.semibold)).accessibilityLabel(message.delivery == "pending" ? "Ожидает отправки":"Принято сервером")}
                }.foregroundStyle(.secondary)
            }.padding(.horizontal,11).padding(.vertical,8)
                .background(message.mine ? accent.opacity(0.23):Color.clear,in:UnevenRoundedRectangle(topLeadingRadius:17,bottomLeadingRadius:message.mine ? 17:5,bottomTrailingRadius:message.mine ? 5:17,topTrailingRadius:17))
                .background(ChatTheme.incoming,in:UnevenRoundedRectangle(topLeadingRadius:17,bottomLeadingRadius:message.mine ? 17:5,bottomTrailingRadius:message.mine ? 5:17,topTrailingRadius:17))
                .shadow(color:.black.opacity(0.035),radius:1,y:1).frame(maxWidth:285,alignment:message.mine ? .trailing:.leading)
            if !message.mine {Spacer(minLength:40)}
        }
    }
}
struct SettingsView: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    @EnvironmentObject var chat: Chat
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { EditProfileView() } label: {
                        HStack(spacing:16) {Avatar(profile:chat.state.profile,size:66);VStack(alignment:.leading,spacing:5) {Text(chat.state.profile.name).font(.title2.bold());Text(chat.state.profile.bio).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)}}.padding(.vertical,8)
                    }
                }
                PushSettings()
                Section {
                    NavigationLink { AppearanceView() } label: {SettingsLabel(title:"Оформление",symbol:"paintpalette.fill",color:accent)}
                    NavigationLink { ConnectionView() } label: {SettingsLabel(title:"Подключение и приглашения",symbol:"network",color:accent)}
                    NavigationLink { EditProfileView() } label: {SettingsLabel(title:"Аватарка и профиль",symbol:"person.crop.circle.fill",color:.purple)}
                    NavigationLink { SecurityView() } label: {SettingsLabel(title:"Конфиденциальность",symbol:"lock.fill",color:.blue)}
                }
                Section {
                    HStack(spacing:14) {
                        Image("StupidLogo").resizable().frame(width:46,height:46).clipShape(RoundedRectangle(cornerRadius:11))
                        VStack(alignment:.leading,spacing:4) {Text("stupidchat").font(.headline);Text("Версия 0.4.1").font(.caption).foregroundStyle(.secondary)}
                    }.padding(.vertical,4)
                    Text("Переписка загружается при открытии приложения.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
        }
    }
}
struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {HStack(spacing:13) {Image(systemName:symbol).font(.system(size:17,weight:.medium)).foregroundStyle(.white).frame(width:30,height:30).background(color,in:RoundedRectangle(cornerRadius:7));Text(title)}}
}
struct EditProfileView: View {
    @EnvironmentObject var chat: Chat
    @Environment(\.dismiss) private var dismiss
    @State private var avatar: PhotosPickerItem?
    @State private var banner: PhotosPickerItem?
    var body: some View {
        Form {
            Section {ProfileHeader(profile:chat.state.profile).listRowInsets(EdgeInsets())}
            Section("О вас") {TextField("Имя",text:$chat.state.profile.name);TextField("О себе",text:$chat.state.profile.bio,axis:.vertical)}
            Section {
                PhotosPicker("Фото или GIF на аватарку",selection:$avatar,matching:.images)
                PhotosPicker("Изменить баннер",selection:$banner,matching:.images)
                if let progress=chat.profileUploadProgress {ProgressView("Синхронизация профиля…",value:progress).font(.caption)}
                Button("Отправить обновлённый профиль") {Task {await chat.publishProfileIfNeeded(force:true)}}.disabled(chat.state.peer == nil || chat.busy)
            }
        }.navigationTitle("Мой профиль").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.topBarTrailing) {Button("Готово") {chat.persist();Task {await chat.publishProfileIfNeeded()};dismiss()}}}
            .onDisappear {chat.persist();Task {await chat.publishProfileIfNeeded()}}
            .onChange(of:avatar) {_,item in Task {if let data=try? await item?.loadTransferable(type:Data.self),let prepared=Chat.optimizedImage(data,maxDimension:320,targetBytes:192*1024,preserveGIF:true),prepared.count<2*1024*1024 {chat.state.profile.avatar=prepared;chat.persist();await chat.publishProfileIfNeeded()} else {chat.error="Аватарка должна быть меньше 2 МБ"}}}
            .onChange(of:banner) {_,item in Task {if let data=try? await item?.loadTransferable(type:Data.self),let prepared=Chat.optimizedImage(data,maxDimension:960,targetBytes:192*1024,preserveGIF:false),prepared.count<2*1024*1024 {chat.state.profile.banner=prepared;chat.persist();await chat.publishProfileIfNeeded()} else {chat.error="Баннер должен быть меньше 2 МБ"}}}
    }
}
struct ProfileHeader: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    let profile: Profile
    var body: some View {
        ZStack(alignment:.bottomLeading) {
            LinearGradient(colors:[accent,.indigo,Color(red:0.10,green:0.10,blue:0.25)],startPoint:.topLeading,endPoint:.bottomTrailing)
            if let data=profile.banner,let image=UIImage(data:data) {Image(uiImage:image).resizable().scaledToFill().frame(height:190).clipped()}
            LinearGradient(colors:[.clear,.black.opacity(0.5)],startPoint:.center,endPoint:.bottom)
            HStack(spacing:14) {Avatar(profile:profile,size:64).overlay(Circle().stroke(.white.opacity(0.8),lineWidth:2));Text(profile.name).font(.title2.bold()).foregroundStyle(.white)}.padding(18)
        }.frame(height:190).clipped()
    }
}
struct PeerProfileView: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    @EnvironmentObject var chat: Chat
    private var profile: Profile {chat.state.remoteProfile}
    var body: some View {
        List {
            Section {ProfileHeader(profile:profile).listRowInsets(EdgeInsets())}
            if let progress=chat.attachmentProgress {Section {ProgressView("Получение обновлений…",value:progress)}}
            Section("О себе") {Text(profile.bio)}
            Section {Label("Сквозное шифрование",systemImage:"lock.fill").foregroundStyle(accent)}
        }.navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
    }
}
struct ConnectionView: View {
    @EnvironmentObject var chat: Chat
    @State private var serverAddress=""
    @State private var accessKey=""
    @State private var invite=""
    var body: some View {
            Form {
                Section("Сервер") {
                    TextField("https://адрес-сервера",text:$serverAddress).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Ключ доступа к частному серверу",text:$accessKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if Deployment.discoveryURL != nil {
                        Toggle("Автоматически находить сервер",isOn:Binding(get:{chat.state.automaticEndpoint != false},set:{chat.state.automaticEndpoint=$0;chat.persist()}))
                        Button("Найти актуальный адрес") {Task {do {_ = try await chat.refreshEndpoint(force:true);serverAddress=chat.state.server} catch {chat.error="Не удалось получить подписанный адрес: \(error.localizedDescription)"}}}.disabled(chat.busy)
                    }
                    Button("Проверить и сохранить") {Task {await configure()}}.disabled(chat.busy)
                    LabeledContent("Состояние",value:chat.connection).font(.caption)
                    if chat.state.account == nil {Button("Создать мой адрес") {Task {await configure();if chat.error.isEmpty {await chat.register()}}}.disabled(chat.busy)}
                    Text("На обоих iPhone нужен один HTTPS-адрес. Сервер на Mac должен оставаться включённым. При смене адреса используйте тот же сервер: ключи и история сохранятся.").font(.caption).foregroundStyle(.secondary)
                }
                if !chat.invitation.isEmpty {
                    Section("Приглашение") {
                        ShareLink(item:chat.invitation) {Label("Поделиться моим приглашением",systemImage:"square.and.arrow.up")}
                        if chat.state.peer == nil {
                            TextField("Приглашение собеседника",text:$invite,axis:.vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Добавить контакт") {chat.addPeer(invite)}.disabled(invite.isEmpty)
                        }
                        Text("Обменяйтесь приглашениями через доверенный канал. Каждый добавляет код другого, затем сверяет код безопасности.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {NavigationLink("Проверка шифрования") {SecurityView()}}
            }.navigationTitle("Начать общение").navigationBarTitleDisplayMode(.inline)
        .onAppear {serverAddress=chat.state.server;accessKey=chat.relayAccessKey}
        .onChange(of:chat.state.server) {_,value in serverAddress=value}
    }
    private func configure() async {
        let oldKey=chat.state.relayAccessKey
        chat.state.relayAccessKey=accessKey.trimmingCharacters(in:.whitespacesAndNewlines)
        await chat.changeServer(serverAddress)
        if !chat.error.isEmpty {chat.state.relayAccessKey=oldKey}
    }
}
struct SecurityView: View {
    @AppStorage("palette") private var palette = Palette.ocean
    private var accent: Color { palette.color }
    @EnvironmentObject var chat: Chat
    var body: some View {
        Form {
            Section {Label("Сквозное шифрование",systemImage:"lock.shield.fill").foregroundStyle(accent);Text("Ключи находятся на устройствах. Сообщения и вложения шифруются до отправки, история хранится зашифрованной.").font(.subheadline)}
            if chat.state.peer != nil {
                Section("Код безопасности") {Text(chat.fingerprint).font(.system(.body,design:.monospaced)).textSelection(.enabled);Text("Сверьте весь код на обоих телефонах лично или голосом. Он должен полностью совпасть.").font(.caption).foregroundStyle(.secondary)}
            }
            Section("Ограничения прототипа") {Text("Сервер видит метаданные доставки. Нет Double Ratchet, forward secrecy и независимого аудита. Не используйте прототип там, где нужна проверенная защита высокого уровня.").font(.caption).foregroundStyle(.secondary)}
        }.navigationTitle("Конфиденциальность").navigationBarTitleDisplayMode(.inline)
    }
}
