import MeroKit
import SwiftUI

// MARK: - Chat home (spaces)

struct ChatHomeView: View {
    @ObservedObject var service: ChatService
    @Environment(\.dismiss) private var dismiss
    @State private var newSpace = ""
    @State private var showNewSpace = false
    @State private var showJoin = false

    var body: some View {
        NavigationStack {
            ZStack {
                Cal.bg.ignoresSafeArea()
                if service.appId == nil {
                    installGate
                } else {
                    spacesList
                }
                if service.busy { busyOverlay }
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
                        } label: {
                            Image(systemName: "plus")
                        }
                        .foregroundColor(Cal.lime)
                        .accessibilityIdentifier("chatAdd")
                    }
                }
            }
            .tint(Cal.lime)
        }
        .preferredColorScheme(.dark)
        .task {
            let env = ProcessInfo.processInfo.environment
            // e2e hook: with E2E_JOIN=<invite json> set, auto-install then join —
            // lets the multi-user harness hand a guest an invite without typing it.
            if let invite = env["E2E_JOIN"], !invite.isEmpty, service.appId == nil {
                await service.setup()
                await service.joinSpace(invite)
            } else {
                // Skip the install gate if curb is already installed on this node.
                await service.detectInstalled()
            }
        }
        .alert("New space", isPresented: $showNewSpace) {
            TextField("Space name", text: $newSpace)
            Button("Create") {
                let n = newSpace; newSpace = ""; Task { await service.createSpace(n) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showJoin) {
            JoinSheet(service: service)
        }
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Cal.lime).scaleEffect(1.3)
                Text(service.status.isEmpty ? "Working…" : service.status)
                    .font(.footnote).foregroundColor(Cal.text)
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 280)
            .background(Cal.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Cal.border, lineWidth: 1))
            .cornerRadius(16)
        }
        .transition(.opacity)
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
                    NavigationLink {
                        ChannelsView(service: service, space: space)
                    } label: {
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
    @State private var inviteError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !service.status.isEmpty {
                    HStack(spacing: 8) {
                        if service.busy { ProgressView().tint(Cal.lime) }
                        Text(service.status).font(.caption2).foregroundColor(Cal.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if service.channels.isEmpty && !service.busy {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No channels yet.").font(.subheadline).foregroundColor(Cal.text)
                        Text("If you just joined, channels sync from the inviter — tap Sync. Or create one with +.")
                            .font(.caption).foregroundColor(Cal.textDim)
                        Button {
                            Task { await service.resync(space) }
                        } label: {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(CalSecondaryButtonStyle())
                    }
                    .padding(14).background(Cal.surface)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1)).cornerRadius(12)
                }
                ForEach(service.channels) { ch in
                    NavigationLink {
                        ChannelView(service: service, channel: ch)
                    } label: {
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
                    Button("Invite people") {
                        Task {
                            let code = await service.makeInvite(space)
                            if let code { invite = code } else { inviteError = true }
                        }
                    }
                    Button("Sync now") { Task { await service.resync(space) } }
                } label: {
                    Image(systemName: "plus")
                }
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
            InviteSheet(text: box.text, spaceName: space.name)
        }
        .alert("Couldn't create invite", isPresented: $inviteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.status.isEmpty ? "The node did not return an invitation." : service.status)
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
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(service.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
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
            // Live updates over SSE — reload messages on each node event for this
            // context (no polling). Cancelling the task closes the SSE stream.
            await service.loadMessages(channel)
            do {
                for try await _ in service.eventStream(channel) {
                    await service.loadMessages(channel)
                }
            } catch {}
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
    var spaceName: String = "space"
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Share this invite code so someone can join “\(spaceName)”.")
                    .font(.footnote).foregroundColor(Cal.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    Text(text).font(Cal.mono).foregroundColor(Cal.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(maxHeight: 220)
                .background(Cal.surface2)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1)).cornerRadius(10)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(CalSecondaryButtonStyle())
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(CalSecondaryButtonStyle())
                }
                Spacer()
            }
            .padding(16)
            .background(Cal.bg)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundColor(Cal.lime) }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Cal.lime)
    }
}

struct JoinSheet: View {
    @ObservedObject var service: ChatService
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste an invite code").font(.headline).foregroundColor(Cal.text)
                TextEditor(text: $text)
                    .font(Cal.mono).foregroundColor(Cal.text).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 140).background(Cal.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1)).cornerRadius(10)
                    .disabled(service.busy)
                Button {
                    Task {
                        await service.joinSpace(text)
                        if service.status.hasPrefix("✓") { dismiss() }
                    }
                } label: {
                    if service.busy {
                        HStack(spacing: 8) {
                            ProgressView().tint(Cal.bg); Text("Joining…")
                        }
                    } else {
                        Text("Join space")
                    }
                }
                .buttonStyle(CalPrimaryButtonStyle())
                .disabled(service.busy || text.trimmingCharacters(in: .whitespaces).isEmpty)

                if !service.status.isEmpty {
                    HStack(spacing: 8) {
                        if service.busy { ProgressView().tint(Cal.lime) }
                        Text(service.status)
                            .font(.caption)
                            .foregroundColor(service.status.hasPrefix("✗") ? Cal.error : Cal.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding(16).background(Cal.bg)
            .navigationTitle("Join a space").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundColor(Cal.lime).disabled(service.busy)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Cal.lime)
    }
}

// MARK: - Message row (mero-chat style: avatar + name + time + text)

struct MessageRow: View {
    let message: ChatMessage

    private var name: String {
        message.senderUsername.isEmpty ? String(message.sender.prefix(6)) : message.senderUsername
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChatAvatar(name: name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                    Text(ChatTime.short(message.timestamp)).font(.caption2).foregroundColor(Cal.textDim)
                }
                Text(message.text)
                    .font(.subheadline)
                    .foregroundColor(Cal.text.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A colored initials avatar (deterministic color per name).
struct ChatAvatar: View {
    let name: String
    var size: CGFloat = 34

    private var initials: String {
        let parts = name.split(separator: " ")
        let joined = parts.prefix(2).map { String($0.prefix(1)) }.joined()
        return (joined.isEmpty ? String(name.prefix(1)) : joined).uppercased()
    }

    private var color: Color {
        let palette: [UInt] = [0xA5FF11, 0xFF7A00, 0x38BD_F8, 0xF472_B6, 0xA78B_FA, 0x34D3_99, 0xFBBF_24]
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let index = ((hash % palette.count) + palette.count) % palette.count
        return Color(hex: palette[index])
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundColor(Cal.bg)
            .frame(width: size, height: size)
            .background(color)
            .clipShape(Circle())
    }
}

enum ChatTime {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static func short(_ milliseconds: Int) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
