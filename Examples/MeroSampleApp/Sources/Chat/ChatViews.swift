import MeroKit
import SwiftUI
import UIKit

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
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.foregroundColor(Cal.accentInk) }
                if service.appId != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if service.canCreateSpaces {
                                Button("New space") { showNewSpace = true }
                            }
                            Button("Join with an invite") { showJoin = true }
                            Divider()
                            Button("Refresh") { Task { await service.loadSpaces() } }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .foregroundColor(Cal.accentInk)
                        .accessibilityIdentifier("chatAdd")
                    }
                }
            }
            .tint(Cal.accentInk)
        }
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
            Color(red: 19 / 255, green: 18 / 255, blue: 21 / 255).opacity(0.32).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Cal.accentInk).scaleEffect(1.3)
                Text(service.status.isEmpty ? "Working…" : service.status)
                    .font(.footnote).foregroundColor(Cal.text)
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 280)
            .background(Cal.surface)
            .overlay(RoundedRectangle(cornerRadius: Cal.cardRadius).stroke(Cal.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Cal.cardRadius))
        }
        .transition(.opacity)
    }

    private var installGate: some View {
        VStack(spacing: 16) {
            IconTile(systemName: "bubble.left.and.bubble.right", accent: true, size: 44)
            Text("Chat").font(.title2.bold()).foregroundColor(Cal.text)
            Text("Install the curb chat app (com.calimero.curb) from the registry to start.")
                .font(.footnote).foregroundColor(Cal.textDim).multilineTextAlignment(.center)
            Button {
                Task { await service.setup() }
            } label: {
                if service.busy { ProgressView().tint(Cal.text) } else { Text("Install mero-chat") }
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
                    EmptyState(
                        icon: "bubble.left.and.bubble.right", title: "No spaces yet",
                        message: service.canCreateSpaces
                            ? "Create a space with +, or join one with an invite."
                            : "Join a space with an invite from its admin. Tap + to paste one.")
                }
                ForEach(service.spaces) { space in
                    NavigationLink {
                        ChannelsView(service: service, space: space)
                    } label: {
                        HStack {
                            IconTile(systemName: "number", accent: true)
                            Text(space.name).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(Cal.textDim)
                        }
                        .padding(12).background(Cal.surface)
                        .overlay(RoundedRectangle(cornerRadius: Cal.cardRadius).stroke(Cal.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Cal.cardRadius))
                    }
                }
            }
            .padding(.horizontal, Cal.screenPad)
            .padding(.vertical, 14)
        }
        .refreshable { await service.loadSpaces() }
        .task { await service.loadSpaces() }
    }

    @ViewBuilder private var statusLine: some View {
        if !service.status.isEmpty {
            Text(service.status).font(.footnote)
                .foregroundColor(service.statusIsError ? Cal.error : Cal.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chatStatus")
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
                        if service.busy { ProgressView().tint(Cal.accentInk) }
                        Text(service.status).font(.footnote)
                            .foregroundColor(service.statusIsError ? Cal.error : Cal.textFaint)
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
                            IconTile(systemName: ch.kind == "Dm" ? "person" : "number")
                            Text(ch.name).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(Cal.textDim)
                        }
                        .padding(13).background(Cal.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Cal.border, lineWidth: 1)).cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, Cal.screenPad)
            .padding(.vertical, 14)
        }
        .background(Cal.bg)
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New channel") { showNew = true }
                    if service.canInvite {
                        Button("Invite people") {
                            Task {
                                let code = await service.makeInvite(space)
                                if let code { invite = code } else { inviteError = true }
                            }
                        }
                    }
                    Button("Sync now") { Task { await service.resync(space) } }
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundColor(Cal.accentInk)
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
                    .padding(.horizontal, Cal.screenPad)
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
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Cal.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Cal.lime))
                    .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("sendMessage")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Cal.surface)
        .overlay(alignment: .top) { Divider().overlay(Cal.border) }
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
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundColor(Cal.accentInk) }
            }
        }
        .tint(Cal.accentInk)
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
                // Single-line: an invite code is one line, so a one-liner avoids
                // stray line breaks that could mangle the code, and a Paste button
                // makes the (long, unreadable) code easy to drop in.
                HStack(spacing: 8) {
                    TextField("invite code", text: $text)
                        .font(Cal.mono).foregroundColor(Cal.text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(Cal.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cal.border, lineWidth: 1))
                        .cornerRadius(10)
                        .disabled(service.busy)
                        .accessibilityIdentifier("joinField")
                    Button {
                        if let clip = UIPasteboard.general.string { text = clip }
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.body)
                    }
                    .foregroundColor(Cal.accentInk)
                    .disabled(service.busy)
                }
                Button {
                    Task {
                        // Strip any whitespace/newlines a paste may have introduced.
                        if await service.joinSpace(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            dismiss()
                        }
                    }
                } label: {
                    if service.busy {
                        HStack(spacing: 8) {
                            ProgressView().tint(Cal.text); Text("Joining…")
                        }
                    } else {
                        Text("Join space")
                    }
                }
                .buttonStyle(CalPrimaryButtonStyle())
                .disabled(service.busy || text.trimmingCharacters(in: .whitespaces).isEmpty)

                if !service.status.isEmpty {
                    HStack(spacing: 8) {
                        if service.busy { ProgressView().tint(Cal.accentInk) }
                        Text(service.status)
                            .font(.caption)
                            .foregroundColor(service.statusIsError ? Cal.error : Cal.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding(16).background(Cal.bg)
            .navigationTitle("Join a space").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundColor(Cal.accentInk).disabled(service.busy)
                }
            }
        }
        .tint(Cal.accentInk)
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
                    Text(ChatTime.short(message.timestamp)).font(.caption).foregroundColor(Cal.textFaint)
                }
                Text(message.text)
                    .font(.subheadline)
                    .foregroundColor(Cal.text)
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
    var size: CGFloat = 32

    private var initials: String {
        let parts = name.split(separator: " ")
        let joined = parts.prefix(2).map { String($0.prefix(1)) }.joined()
        return (joined.isEmpty ? String(name.prefix(1)) : joined).uppercased()
    }

    /// Calimero avatar tones (background, foreground), chosen by name hash.
    private var tone: (Color, Color) {
        let tones: [(UInt, UInt)] = [
            (0xF0FFD6, 0x4A7300), (0xE6EEFB, 0x1D4F9F), (0xFBE9E4, 0x9A3412),
            (0xEFE8FB, 0x5B3AA8), (0xFDF3DC, 0x8A5300), (0xE2F4F1, 0x116A5C),
        ]
        var hash = 5381
        for byte in name.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let pick = tones[((hash % tones.count) + tones.count) % tones.count]
        return (Color(hex: pick.0), Color(hex: pick.1))
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundColor(tone.1)
            .frame(width: size, height: size)
            .background(tone.0)
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

/// Dashed empty state: icon tile, title, body.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            IconTile(systemName: icon, size: 40)
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Cal.text)
            Text(message).font(.footnote).foregroundColor(Cal.textDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 20)
        .overlay(
            RoundedRectangle(cornerRadius: Cal.cardRadius)
                .stroke(Cal.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
