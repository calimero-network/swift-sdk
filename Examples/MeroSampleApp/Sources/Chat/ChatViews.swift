import MeroKit
import SwiftUI

// MARK: - Chat home (spaces)

struct ChatHomeView: View {
    @StateObject private var service: ChatService
    @Environment(\.dismiss) private var dismiss
    @State private var newSpace = ""
    @State private var showNewSpace = false
    @State private var showJoin = false
    @State private var joinText = ""

    init(mero: Mero, username: String) {
        _service = StateObject(wrappedValue: ChatService(mero: mero, username: username))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Cal.bg.ignoresSafeArea()
                if service.appId == nil {
                    installGate
                } else {
                    spacesList
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.foregroundColor(Cal.lime) }
                if service.appId != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New space") { showNewSpace = true }
                            Button("Join with invite") { showJoin = true }
                        } label: { Image(systemName: "plus") }
                        .foregroundColor(Cal.lime)
                        .accessibilityIdentifier("chatAdd")
                    }
                }
            }
            .tint(Cal.lime)
        }
        .preferredColorScheme(.dark)
        .task { if service.appId == nil { /* wait for user to install */ } }
        .alert("New space", isPresented: $showNewSpace) {
            TextField("Space name", text: $newSpace)
            Button("Create") { let n = newSpace; newSpace = ""; Task { await service.createSpace(n) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showJoin) {
            JoinSheet(text: $joinText) { Task { await service.joinSpace(joinText); showJoin = false } }
        }
    }

    private var installGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 44)).foregroundColor(Cal.lime)
            Text("mero-chat").font(.title2.bold()).foregroundColor(Cal.text)
            Text("Install the curb chat app (com.calimero.curb) from the registry to start.")
                .font(.footnote).foregroundColor(Cal.textDim).multilineTextAlignment(.center)
            Button {
                Task { await service.setup() }
            } label: {
                if service.busy { ProgressView().tint(Cal.bg) } else { Text("Install mero-chat") }
            }
            .buttonStyle(CalPrimaryButtonStyle()).disabled(service.busy).frame(maxWidth: 280)
            .accessibilityIdentifier("installChat")
            statusLine
        }
        .padding(24)
    }

    private var spacesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                statusLine
                if service.spaces.isEmpty {
                    Text("No spaces yet. Tap + to create one.").font(.footnote).foregroundColor(Cal.textDim)
                }
                ForEach(service.spaces) { space in
                    NavigationLink { ChannelsView(service: service, space: space) } label: {
                        HStack {
                            Image(systemName: "number.square.fill").foregroundColor(Cal.lime)
                            Text(space.name).font(.headline).foregroundColor(Cal.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(Cal.textDim)
                        }
                        .padding(14).background(Cal.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1)).cornerRadius(12)
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await service.loadSpaces() }
        .task { await service.loadSpaces() }
    }

    @ViewBuilder private var statusLine: some View {
        if !service.status.isEmpty {
            Text(service.status).font(.caption2).foregroundColor(Cal.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Channels in a space

struct ChannelsView: View {
    @ObservedObject var service: ChatService
    let space: ChatSpace
    @State private var newChannel = ""
    @State private var showNew = false
    @State private var openChannel = true
    @State private var invite: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if service.channels.isEmpty {
                    Text("No channels yet. Tap + to create one.").font(.footnote).foregroundColor(Cal.textDim)
                }
                ForEach(service.channels) { ch in
                    NavigationLink { ChannelView(service: service, channel: ch) } label: {
                        HStack {
                            Image(systemName: ch.kind == "Dm" ? "person.fill" : "number").foregroundColor(Cal.lime)
                            Text(ch.name).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(Cal.textDim)
                        }
                        .padding(13).background(Cal.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1)).cornerRadius(12)
                    }
                }
            }
            .padding(16)
        }
        .background(Cal.bg)
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New channel") { showNew = true }
                    Button("Invite people") { Task { invite = await service.makeInvite(space) } }
                } label: { Image(systemName: "plus") }
                .foregroundColor(Cal.lime)
                .accessibilityIdentifier("channelAdd")
            }
        }
        .task { await service.loadChannels(space) }
        .refreshable { await service.loadChannels(space) }
        .alert("New channel", isPresented: $showNew) {
            TextField("channel-name", text: $newChannel)
            Button("Create") {
                let n = newChannel; newChannel = ""
                Task { await service.createChannel(in: space, name: n, open: openChannel) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: Binding(get: { invite.map { InviteBox(text: $0) } }, set: { _ in invite = nil })) { box in
            InviteSheet(text: box.text)
        }
    }
}

private struct InviteBox: Identifiable { let id = UUID(); let text: String }

// MARK: - A channel's messages

struct ChannelView: View {
    @ObservedObject var service: ChatService
    let channel: ChatChannel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(service.messages) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.sender_username.isEmpty ? String(m.sender.prefix(8)) : m.sender_username)
                                    .font(.caption2.weight(.bold)).foregroundColor(Cal.lime)
                                Text(m.text).font(.subheadline).foregroundColor(Cal.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Cal.surface)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1)).cornerRadius(10)
                            .id(m.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: service.messages.count) { _ in
                    if let last = service.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(Cal.bg.ignoresSafeArea())
        .navigationTitle("#\(channel.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: channel.id) {
            while !Task.isCancelled {
                await service.loadMessages(channel)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message #\(channel.name)", text: $draft)
                .font(.subheadline).foregroundColor(Cal.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Cal.surface2)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Cal.border, lineWidth: 1)).cornerRadius(20)
                .accessibilityIdentifier("messageField")
            Button {
                let t = draft; draft = ""
                Task { await service.sendMessage(channel, t) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(Cal.lime)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("sendMessage")
        }
        .padding(10).background(Cal.bg)
    }
}

// MARK: - Invite / Join sheets

struct InviteSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(Cal.mono).foregroundColor(Cal.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(Cal.bg)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = text }.foregroundColor(Cal.lime)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundColor(Cal.lime) }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct JoinSheet: View {
    @Binding var text: String
    let onJoin: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste an invite").font(.headline).foregroundColor(Cal.text)
                TextEditor(text: $text)
                    .font(Cal.mono).foregroundColor(Cal.text).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 160).background(Cal.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1)).cornerRadius(10)
                Button("Join space") { onJoin() }.buttonStyle(CalPrimaryButtonStyle())
                Spacer()
            }
            .padding(16).background(Cal.bg)
            .navigationTitle("Join").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundColor(Cal.lime) } }
        }
        .preferredColorScheme(.dark)
    }
}
