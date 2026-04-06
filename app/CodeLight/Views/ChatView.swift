import SwiftUI
import PhotosUI

/// A pending image attachment in the compose bar (before send).
struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data      // compressed JPEG, ready to upload
    let thumbnail: UIImage
}

/// A conversation turn — user question + all Claude's responses until next user message.
struct ConversationTurn: Identifiable {
    let id: String          // Uses user message ID (or "initial" if no user msg)
    let userMessage: ChatMessage?
    let replies: [ChatMessage]
    let firstSeq: Int       // For sorting
    let questionText: String // For navigation
    let questionImageBlobIds: [String]   // For rendering attached images in the user bubble

    var anchorId: String { id }
}

/// Chat view with markdown rendering, lazy loading, and turn-based grouping.
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let sessionId: String

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pickerSelections: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var showCapabilitySheet = false
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreOlder = false
    @State private var selectedModel = "opus"
    @State private var selectedMode = "auto"
    @State private var showQuestionNav = false
    @State private var expandedTurns = Set<String>()
    @State private var shouldAutoScroll = true
    @State private var lastSeenSeq: Int = 0
    @State private var deltaFetchTask: Task<Void, Never>? = nil

    private let models = ["opus", "sonnet", "haiku"]
    private let modes = ["auto", "default", "plan"]

    // Group messages into turns
    private var turns: [ConversationTurn] {
        groupMessagesIntoTurns(messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages grouped into turns with lazy loading
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Load more button at top
                        if hasMoreOlder {
                            Button {
                                Task { await loadOlderMessages() }
                            } label: {
                                if isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding(8)
                                } else {
                                    Text(String(localized: "load_earlier_messages"))
                                        .font(.system(size: 11, weight: .medium))
                                        .tracking(0.3)
                                        .foregroundStyle(Theme.brand)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 14)
                                        .background(Theme.brandSoft, in: Capsule())
                                        .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 0.5))
                                }
                            }
                            .id("loadMore")
                        }

                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        }

                        ForEach(turns) { turn in
                            TurnView(turn: turn, isExpanded: isExpanded(turn), onToggle: { toggleTurn(turn) })
                                .id(turn.anchorId)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.last?.seq ?? 0) { oldSeq, newSeq in
                    // Only scroll to bottom when NEW messages arrive (seq increases),
                    // not when older messages are prepended.
                    guard shouldAutoScroll && newSeq > oldSeq else { return }
                    if let lastTurn = turns.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastTurn.anchorId, anchor: .bottom)
                        }
                    }
                }
                .sheet(isPresented: $showQuestionNav) {
                    QuestionNavSheet(
                        turns: turns,
                        isLoadingAll: isLoadingMore && hasMoreOlder
                    ) { turnId in
                        showQuestionNav = false
                        expandedTurns.insert(turnId)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(turnId, anchor: .top)
                        }
                    }
                    .presentationDetents([.medium, .large])
                    .task {
                        // When the sheet appears, page through all older messages
                        // so the question list reflects the full session history.
                        await loadAllOlderMessages()
                    }
                }
            }

            Divider()

            // Input bar
            composeBar
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQuestionNav = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
            }
        }
        .sheet(isPresented: $showCapabilitySheet) {
            CapabilitySheet { text in
                if inputText.isEmpty {
                    inputText = text
                } else if inputText.hasSuffix(" ") {
                    inputText += text
                } else {
                    inputText += " " + text
                }
            }
        }
        .task {
            await loadMessages()
            startLiveActivity()
        }
        .refreshable {
            // Pull-down at top of chat = load older history (matches user mental model
            // for chat apps). New messages already arrive in real-time via socket, so
            // refreshing the latest is meaningless here.
            if hasMoreOlder { await loadOlderMessages() }
        }
        .onReceive(appState.newMessageSubject) { event in
            guard event.sessionId == sessionId else { return }
            // Phase / status messages are not chat content, but they're a useful
            // heartbeat: every Claude state change emits one. Use them as a signal
            // to delta-fetch any messages we may have missed via socket. They do
            // NOT enter the chat history (would cause LazyVStack scroll glitches).
            if isStatusOnly(event.message) {
                scheduleDeltaFetch()
                return
            }
            // Replace optimistic local message if server echoes back with same localId.
            if let lid = event.message.localId,
               let idx = messages.firstIndex(where: { $0.localId == lid }) {
                messages[idx] = event.message
                return
            }
            // Otherwise dedup by id and append.
            if !messages.contains(where: { $0.id == event.message.id }) {
                messages.append(event.message)
            }
        }
        .onDisappear {
            deltaFetchTask?.cancel()
            deltaFetchTask = nil
        }
    }

    // MARK: - Turn State

    private func isExpanded(_ turn: ConversationTurn) -> Bool {
        // The last turn is always expanded by default; others follow user toggle
        if turn.id == turns.last?.id { return true }
        return expandedTurns.contains(turn.id)
    }

    private func toggleTurn(_ turn: ConversationTurn) {
        if expandedTurns.contains(turn.id) {
            expandedTurns.remove(turn.id)
        } else {
            expandedTurns.insert(turn.id)
        }
    }

    // MARK: - Turn Grouping

    private func groupMessagesIntoTurns(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var currentUserMsg: ChatMessage?
        var currentReplies: [ChatMessage] = []
        var currentFirstSeq: Int = 0
        var initialReplies: [ChatMessage] = []

        func flushCurrent() {
            if let user = currentUserMsg {
                let question = extractTextFromMessage(user)
                let blobIds = extractImageBlobIds(user)
                turns.append(ConversationTurn(
                    id: user.id,
                    userMessage: user,
                    replies: currentReplies,
                    firstSeq: currentFirstSeq,
                    questionText: question,
                    questionImageBlobIds: blobIds
                ))
            }
            currentUserMsg = nil
            currentReplies = []
        }

        for msg in messages {
            let type = messageType(msg)

            if type == "user" {
                flushCurrent()
                currentUserMsg = msg
                currentFirstSeq = msg.seq
            } else if currentUserMsg != nil {
                currentReplies.append(msg)
            } else {
                initialReplies.append(msg)
            }
        }
        flushCurrent()

        // Prepend initial replies (before first user message) if any
        if !initialReplies.isEmpty {
            turns.insert(ConversationTurn(
                id: "initial-\(initialReplies.first?.id ?? "")",
                userMessage: nil,
                replies: initialReplies,
                firstSeq: initialReplies.first?.seq ?? 0,
                questionText: String(localized: "session_start"),
                questionImageBlobIds: []
            ), at: 0)
        }

        return turns
    }

    private func messageType(_ msg: ChatMessage) -> String {
        if let data = msg.content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            return type
        }
        return "user" // Plain text = user message from phone
    }

    private func extractTextFromMessage(_ msg: ChatMessage) -> String {
        if let data = msg.content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = dict["text"] as? String {
            return text
        }
        return msg.content
    }

    private func extractImageBlobIds(_ msg: ChatMessage) -> [String] {
        guard let data = msg.content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = dict["images"] as? [[String: Any]]
        else { return [] }
        return images.compactMap { $0["blobId"] as? String }
    }

    private func startLiveActivity() {
        // Delay to ensure app is fully visible (fixes "visibility" error on launch)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await MainActor.run { doStartLiveActivity() }
        }
    }

    private func doStartLiveActivity() {
        // Delegate to AppState's global activity manager
        appState.startLiveActivitiesForActiveSessions()
    }

    // MARK: - Compose Bar

    private var composeBar: some View {
        VStack(spacing: 8) {
            // Attachment thumbnails
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: att.thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button {
                                    pendingAttachments.removeAll { $0.id == att.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 72)
            }

            HStack(spacing: 8) {
                // Left-side tool pill — three 32pt icon buttons, consistent size/weight.
                HStack(spacing: 2) {
                    PhotosPicker(
                        selection: $pickerSelections,
                        maxSelectionCount: 6,
                        matching: .images
                    ) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .onChange(of: pickerSelections) { _, newItems in
                        Task { await loadPickedImages(newItems) }
                    }

                    Button {
                        showCapabilitySheet = true
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 32, height: 32)
                    }

                    Button {
                        sendControlKey("escape")
                    } label: {
                        Image(systemName: "escape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                }
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 0.5)
                )

                TextField(String(localized: "message_placeholder"), text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )
                    .lineLimit(1...5)

                // Send button only exists when there's something to send. Lime
                // filled circle with near-black icon for max contrast.
                if canSend || isSending {
                    Button { send() } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.brand)
                                .frame(width: 32, height: 32)
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Theme.onBrand)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.onBrand)
                            }
                        }
                    }
                    .disabled(isSending)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.bgPrimary)
        .overlay(
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    /// Send a control key (escape, enter, ctrl+c, …) to the session. Doesn't touch
    /// the input box — it's a fire-and-forget side channel.
    private func sendControlKey(_ key: String) {
        let payload: [String: Any] = ["type": "key", "key": key]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        appState.sendMessage(str, toSession: sessionId)
    }

    /// Read selected PhotosPicker items, compress, and stage them as attachments.
    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        var newAttachments: [PendingAttachment] = []
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let compressed = ImageCompressor.compress(raw) else { continue }
            guard let thumb = UIImage(data: compressed) else { continue }
            newAttachments.append(PendingAttachment(data: compressed, thumbnail: thumb))
        }
        await MainActor.run {
            pendingAttachments.append(contentsOf: newAttachments)
            pickerSelections.removeAll()
        }
    }

    // MARK: - Data

    private var sessionTitle: String {
        appState.sessions.first { $0.id == sessionId }?.metadata?.displayProjectName ?? String(localized: "session")
    }

    /// Returns true if the message is a transient status update (phase/heartbeat)
    /// that should not appear in chat history. These are surfaced through the
    /// Live Activity instead.
    private func isStatusOnly(_ msg: ChatMessage) -> Bool {
        guard let data = msg.content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else { return false }
        return type == "phase" || type == "heartbeat" || type == "key"
    }

    private func loadMessages() async {
        // Initial load only — never destructively replace once we have data.
        // New messages stream in via newMessageSubject; older ones come from the
        // explicit "Load earlier" button. This guard makes the function safe even
        // if SwiftUI re-runs the .task closure for any reason.
        guard messages.isEmpty else { return }
        isLoading = true
        if let socket = appState.socket {
            let result = (try? await socket.fetchMessages(sessionId: sessionId, limit: 50)) ?? SocketClient.FetchResult(messages: [], hasMore: false)
            messages = result.messages.filter { !isStatusOnly($0) }
            hasMoreOlder = result.hasMore
        }
        isLoading = false
    }

    private func loadOlderMessages() async {
        guard !isLoadingMore, let oldest = messages.first else { return }
        isLoadingMore = true
        if let socket = appState.socket {
            let result = (try? await socket.fetchOlderMessages(sessionId: sessionId, beforeSeq: oldest.seq, limit: 50)) ?? SocketClient.FetchResult(messages: [], hasMore: false)
            let filtered = result.messages.filter { !isStatusOnly($0) }
            messages.insert(contentsOf: filtered, at: 0)
            hasMoreOlder = result.hasMore
        }
        isLoadingMore = false
    }

    /// Page through every older batch until we've loaded the entire history.
    /// Used by the "Jump to question" sheet so users can navigate to questions
    /// that haven't been pulled into the visible window yet.
    private func loadAllOlderMessages() async {
        while hasMoreOlder && !Task.isCancelled {
            await loadOlderMessages()
        }
    }

    /// Debounced delta fetch — pulls any messages with seq > our current last
    /// seq from the server. Triggered by phase heartbeat messages so we self-heal
    /// from any dropped/missed real-time broadcasts (Claude responses are the
    /// main victim because they go through Mac's debounced JSONL parser).
    private func scheduleDeltaFetch() {
        deltaFetchTask?.cancel()
        deltaFetchTask = Task { [sessionId] in
            // Small debounce so a burst of phase events coalesces into one fetch.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let socket = appState.socket else { return }
            let afterSeq = messages.last?.seq ?? 0
            guard let result = try? await socket.fetchNewerMessages(sessionId: sessionId, afterSeq: afterSeq) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                for msg in result.messages {
                    if isStatusOnly(msg) { continue }
                    // Replace optimistic local row if localId matches.
                    if let lid = msg.localId,
                       let idx = messages.firstIndex(where: { $0.localId == lid }) {
                        messages[idx] = msg
                        continue
                    }
                    // Dedup by id.
                    if messages.contains(where: { $0.id == msg.id }) { continue }
                    messages.append(msg)
                }
            }
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        guard !text.isEmpty || !attachmentsToSend.isEmpty else { return }

        inputText = ""
        pendingAttachments = []
        isSending = true

        Task {
            // Upload blobs first (if any), keeping the raw data in a local cache so
            // MessageRow can render the image immediately in history.
            var blobIds: [String] = []
            if !attachmentsToSend.isEmpty, let socket = appState.socket {
                for att in attachmentsToSend {
                    if let id = try? await socket.uploadBlob(data: att.data, mime: "image/jpeg") {
                        blobIds.append(id)
                        await MainActor.run { appState.sentImageCache[id] = att.data }
                    }
                }
            }

            // Compose payload. If there are blobs, send JSON; otherwise keep plain text so
            // CodeIsland's existing "plain text = user message" path still works.
            let payloadString: String
            if !blobIds.isEmpty {
                var payload: [String: Any] = ["type": "user", "text": text]
                payload["images"] = blobIds.map { ["blobId": $0, "mime": "image/jpeg"] }
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let str = String(data: data, encoding: .utf8) {
                    payloadString = str
                } else {
                    payloadString = text
                }
            } else {
                payloadString = text
            }

            // Share one localId between the socket emit and the optimistic
            // ChatMessage so the server echo can replace the local row instead
            // of producing a duplicate.
            let localId = UUID().uuidString
            await MainActor.run {
                appState.sendMessage(payloadString, toSession: sessionId, localId: localId)
                let msg = ChatMessage(id: "local-\(localId)",
                                      seq: (messages.last?.seq ?? 0) + 1,
                                      content: payloadString,
                                      localId: localId)
                messages.append(msg)
                isSending = false
            }
        }
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    @EnvironmentObject var appState: AppState
    let message: ChatMessage
    @State private var hasAppeared = false

    var body: some View {
        let parsed = parseContent(message.content)

        HStack(alignment: .top, spacing: 10) {
            // Unified 18x18 icon rail on the left so every event type lines up
            // vertically. One width/weight across the board.
            Image(systemName: roleIcon(parsed.type))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(roleColor(parsed.type))
                .frame(width: 18, height: 18)
                .padding(.top, 4)

            // Body. The old uppercase role label is gone — the icon rail already
            // carries identity, and the per-event visual styling (bubble, dot,
            // border) makes the type obvious without repeating it in text.
            VStack(alignment: .leading, spacing: 0) {
                switch parsed.type {
                case "tool":
                    toolView(parsed)
                case "thinking":
                    thinkingView(parsed)
                case "interrupted":
                    interruptedView
                case "terminal_output":
                    terminalOutputView(parsed)
                case "assistant":
                    assistantView(parsed)
                default:
                    if !parsed.text.isEmpty {
                        markdownContent(parsed.text)
                    }
                    if !parsed.imageBlobIds.isEmpty {
                        attachmentsView(blobIds: parsed.imageBlobIds)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 4)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { hasAppeared = true }
        }
    }

    // MARK: - Assistant Bubble

    @ViewBuilder
    private func assistantView(_ parsed: ParsedMessage) -> some View {
        // Solid brand card with near-black text — high contrast, single block.
        VStack(alignment: .leading, spacing: 4) {
            if !parsed.text.isEmpty {
                markdownContent(parsed.text)
            }
            if !parsed.imageBlobIds.isEmpty {
                attachmentsView(blobIds: parsed.imageBlobIds)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(Theme.onBrand)
        .tint(Theme.onBrand)
    }

    // MARK: - Interrupted

    @ViewBuilder
    private var interruptedView: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10, weight: .medium))
            Text(String(localized: "interrupted_by_user"))
                .font(.caption)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func attachmentsView(blobIds: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(blobIds, id: \.self) { id in
                    if let data = appState.sentImageCache[id],
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 120, height: 120)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
            }
        }
    }

    // MARK: - Markdown Rendering

    @ViewBuilder
    private func markdownContent(_ text: String) -> some View {
        let parts = splitCodeBlocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.isCode {
                    codeBlockView(part)
                } else if !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocksView(part.text)
                }
            }
        }
    }

    /// Render a non-code chunk by splitting it into block-level markdown
    /// elements (headings, lists, blockquotes, rules, paragraphs) and styling
    /// each block. Inline markdown inside each block is still handled by
    /// AttributedString — only block-level structure is parsed manually.
    @ViewBuilder
    private func blocksView(_ text: String) -> some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                inlineText(text)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .ordered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                inlineText(text)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                inlineText(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
                Spacer(minLength: 0)
            }
        case .rule:
            Divider()
                .padding(.vertical, 2)
        case .paragraph(let text):
            inlineText(text)
                .font(.subheadline)
        case .table(let rows, let hasHeader):
            tableView(rows: rows, hasHeader: hasHeader)
        }
    }

    @ViewBuilder
    private func tableView(rows: [[String]], hasHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inlineText(cell)
                            .font(.system(size: 12, weight: hasHeader && idx == 0 ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                if idx < rows.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    /// Render inline-only markdown (bold, italic, code, links) as a Text view.
    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }

    // MARK: - Block-Level Markdown Parsing

    fileprivate enum MarkdownBlock {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case ordered(indent: Int, number: String, text: String)
        case quote(text: String)
        case rule
        case paragraph(text: String)
        case table(rows: [[String]], hasHeader: Bool)
    }

    /// Walk lines and classify each as a block-level element. Consecutive
    /// paragraph lines collapse into a single paragraph block (joined with
    /// newlines so AttributedString can preserve soft wraps).
    private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                let joined = paragraphBuffer.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.paragraph(text: joined))
                }
                paragraphBuffer.removeAll()
            }
        }

        // Split on \n; we want to preserve order and handle empty lines as
        // paragraph breaks (already implicit since empty lines don't match any
        // pattern and just get filtered out of paragraphBuffer).
        let lines = text.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let rawLine = lines[i]

            // Empty/whitespace-only line → paragraph break
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule: --- *** ___ on a line by themselves
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3,
               trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // GFM table: a row of pipe-delimited cells immediately followed by
            // a separator row like `| --- | --- |`. Both lines are required —
            // a single `|...|` line by itself stays a paragraph.
            if isPipeRow(rawLine),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var rows: [[String]] = [parseTableRow(rawLine)]
                i += 2 // skip header and separator
                while i < lines.count, isPipeRow(lines[i]) {
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                // Normalize column count so missing trailing cells render as empty.
                let columnCount = rows.map(\.count).max() ?? 0
                let normalized = rows.map { row -> [String] in
                    if row.count < columnCount {
                        return row + Array(repeating: "", count: columnCount - row.count)
                    }
                    return row
                }
                blocks.append(.table(rows: normalized, hasHeader: true))
                continue
            }

            // ATX heading: 1-6 # then space then text
            if let heading = matchHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Blockquote: leading > then optional space then text
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(text: text))
                i += 1
                continue
            }

            // Unordered list: leading whitespace + (-|*|+) + space
            if let bullet = matchBullet(rawLine) {
                flushParagraph()
                blocks.append(.bullet(indent: bullet.indent, text: bullet.text))
                i += 1
                continue
            }

            // Ordered list: leading whitespace + digits + . + space
            if let ordered = matchOrdered(rawLine) {
                flushParagraph()
                blocks.append(.ordered(indent: ordered.indent, number: ordered.number, text: ordered.text))
                i += 1
                continue
            }

            // Default: paragraph line
            paragraphBuffer.append(rawLine)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    /// True if the line looks like a row of pipe-delimited cells (`|a|b|`).
    /// Lenient: accepts missing leading/trailing pipes too as long as there is
    /// at least one interior pipe.
    private func isPipeRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty
    }

    /// True if the line is a GFM table separator: `| --- | :---: | ---: |`.
    private func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        // Each cell must be all dashes with optional leading/trailing colons.
        let cells = parseTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "")
                               .trimmingCharacters(in: .whitespaces)
            return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
        }
    }

    /// Parse a `|a|b|c|` row into cell strings. Strips leading/trailing pipes
    /// and trims each cell.
    private func parseTableRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func matchHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        // Must have at least one space separating # from text
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private func matchBullet(_ line: String) -> (indent: Int, text: String)? {
        // Count leading spaces (tab = 4 spaces) for indent level
        var spaces = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let marker = line[i]
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }
        let after = line.index(after: i)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let text = String(line[line.index(after: after)...])
        let indent = spaces / 2 // 2 spaces per nesting level
        return (indent, text)
    }

    private func matchOrdered(_ line: String) -> (indent: Int, number: String, text: String)? {
        var spaces = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
            i = line.index(after: i)
        }
        var digits = ""
        while i < line.endIndex, line[i].isNumber {
            digits.append(line[i])
            i = line.index(after: i)
        }
        guard !digits.isEmpty, i < line.endIndex, line[i] == "." else { return nil }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let text = String(line[line.index(after: afterDot)...])
        let indent = spaces / 2
        return (indent, digits, text)
    }

    private func codeBlockView(_ part: TextPart) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !part.language.isEmpty {
                HStack {
                    Text(part.language)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = part.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(part.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tool / Thinking Views

    private func toolView(_ parsed: ParsedMessage) -> some View {
        let status = parsed.toolStatus?.lowercased() ?? ""
        let isRunning = status == "running" || status == "pending"
        let color = statusColor(status)

        // Single-line chip, no card, no accent bar, no shimmer. The timeline
        // rail + left icon already carry the "tool event" signal; this view
        // only needs to name the tool and show status. Keeps multi-tool bursts
        // dense instead of eating half the screen.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isRunning {
                    PulseDot(color: color, size: 6)
                } else {
                    Image(systemName: status == "error" || status == "failed"
                          ? "xmark.circle.fill"
                          : "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color)
                }
                Image(systemName: toolIcon(parsed.toolName ?? ""))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(parsed.toolName ?? "tool")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if !parsed.text.isEmpty {
                Text(parsed.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func thinkingView(_ parsed: ParsedMessage) -> some View {
        // The left-side rail icon already shows a brain — don't repeat it here.
        HStack(spacing: 6) {
            if parsed.text.isEmpty {
                ThinkingDots(color: .purple)
            } else {
                Text(parsed.text)
                    .font(.system(size: 12))
                    .italic()
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.purple.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Code Block Parsing

    private struct TextPart {
        let text: String
        let isCode: Bool
        let language: String
    }

    private func splitCodeBlocks(_ text: String) -> [TextPart] {
        var parts: [TextPart] = []
        let pattern = "```(\\w*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [TextPart(text: text, isCode: false, language: "")]
        }

        let nsText = text as NSString
        var lastEnd = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if beforeRange.length > 0 {
                parts.append(TextPart(text: nsText.substring(with: beforeRange), isCode: false, language: ""))
            }
            let lang = match.numberOfRanges > 1 ? nsText.substring(with: match.range(at: 1)) : ""
            let code = match.numberOfRanges > 2 ? nsText.substring(with: match.range(at: 2)) : ""
            parts.append(TextPart(text: code, isCode: true, language: lang))
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsText.length {
            parts.append(TextPart(text: nsText.substring(from: lastEnd), isCode: false, language: ""))
        }

        return parts.isEmpty ? [TextPart(text: text, isCode: false, language: "")] : parts
    }

    // MARK: - Parse

    private struct ParsedMessage {
        let type: String
        let text: String
        let toolName: String?
        let toolStatus: String?
        let imageBlobIds: [String]
        let command: String?     // For terminal_output messages
    }

    private func parseContent(_ content: String) -> ParsedMessage {
        if let data = content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            var blobIds: [String] = []
            if let images = dict["images"] as? [[String: Any]] {
                blobIds = images.compactMap { $0["blobId"] as? String }
            }
            return ParsedMessage(
                type: type,
                text: dict["text"] as? String ?? "",
                toolName: dict["toolName"] as? String,
                toolStatus: dict["toolStatus"] as? String,
                imageBlobIds: blobIds,
                command: dict["command"] as? String
            )
        }
        return ParsedMessage(type: "user", text: content, toolName: nil, toolStatus: nil, imageBlobIds: [], command: nil)
    }

    // MARK: - Terminal Output View

    @ViewBuilder
    private func terminalOutputView(_ parsed: ParsedMessage) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(roleColor("terminal_output"))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            VStack(alignment: .leading, spacing: 4) {
                if let cmd = parsed.command {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(cmd)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(parsed.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(minWidth: 0, alignment: .leading)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Style Helpers

    private func roleColor(_ type: String) -> Color {
        switch type {
        case "user": return Theme.info
        case "assistant": return Theme.brand
        case "thinking": return .purple
        case "tool": return .cyan
        case "interrupted": return Theme.danger
        case "terminal_output": return Theme.warning
        default: return Theme.textTertiary
        }
    }

    private func roleIcon(_ type: String) -> String {
        switch type {
        case "user": return "person.crop.circle.fill"
        case "assistant": return "sparkle"
        case "thinking": return "brain.head.profile"
        case "tool": return "hammer.fill"
        case "interrupted": return "exclamationmark.octagon.fill"
        case "terminal_output": return "apple.terminal.fill"
        default: return "circle.fill"
        }
    }

    private func roleLabel(_ type: String) -> String {
        switch type {
        case "user": return String(localized: "role_you")
        case "assistant": return String(localized: "role_claude")
        case "thinking": return String(localized: "role_thinking")
        case "tool": return String(localized: "role_tool")
        case "interrupted": return String(localized: "role_interrupted")
        case "terminal_output": return "TERMINAL"
        default: return type
        }
    }

    private func toolIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write": return "doc.badge.plus"
        case "edit": return "pencil"
        case "glob": return "folder.badge.magnifyingglass"
        case "grep": return "magnifyingglass"
        case "agent": return "person.2"
        case "task": return "checklist"
        default: return "gearshape"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "success", "completed": return Theme.brand
        case "error", "failed": return Theme.danger
        case "running", "pending": return Theme.warning
        default: return Theme.textSecondary
        }
    }
}

// MARK: - Turn View

private struct TurnView: View {
    @EnvironmentObject var appState: AppState
    let turn: ConversationTurn
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User question header — minimal: a 2pt brand accent bar on the left,
            // monospaced YOU label, and the question text. No avatar circle.
            if turn.userMessage != nil {
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(Theme.brand)
                            .frame(width: 2)
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOU")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(Theme.brand)
                            if !turn.questionText.isEmpty {
                                Text(turn.questionText)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(isExpanded ? nil : 2)
                                    .multilineTextAlignment(.leading)
                            }
                            if !turn.questionImageBlobIds.isEmpty {
                                userImageStrip(turn.questionImageBlobIds)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 2)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Initial replies (no user message)
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .medium))
                    Text(turn.questionText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.vertical, 4)
            }

            // Replies (collapsible) with a timeline rail + rhythmic spacing.
            if isExpanded {
                repliesTimeline
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !turn.replies.isEmpty {
                // Collapsed summary
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(turn.replies.count) \(String(localized: "replies"))")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
        }
    }

    /// Replies stacked with a continuous timeline rail behind the icon column and
    /// rhythmic spacing — tight between same-type consecutive events, wider at
    /// type transitions — so the eye can parse grouped activity at a glance.
    @ViewBuilder
    private var repliesTimeline: some View {
        ZStack(alignment: .topLeading) {
            // The rail sits behind the 18pt icon column in MessageRow. Icons start
            // at x=0 of MessageRow, are 18pt wide, so center is x=9.
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
                .padding(.leading, 9)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(turn.replies.enumerated()), id: \.element.id) { idx, reply in
                    MessageRow(message: reply)
                        .padding(.top, spacingBefore(idx))
                }
            }
        }
    }

    /// Vertical gap to put above message at index `idx`.
    ///   - 0 for the first message
    ///   - 2pt for consecutive same-type events (tight group — tool bursts)
    ///   - 10pt for a type transition (breathing room)
    private func spacingBefore(_ idx: Int) -> CGFloat {
        guard idx > 0 else { return 0 }
        let prev = messageType(turn.replies[idx - 1])
        let cur = messageType(turn.replies[idx])
        return prev == cur ? 2 : 10
    }

    private func messageType(_ msg: ChatMessage) -> String {
        if let data = msg.content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            return type
        }
        return "user"
    }

    /// Horizontal strip of image thumbnails for the user's attached photos.
    /// Pulls bytes from `appState.sentImageCache` (populated when the message
    /// was sent), falls back to a placeholder photo icon for cache misses
    /// (e.g. session re-opened after process restart — server has already
    /// purged the blob).
    @ViewBuilder
    private func userImageStrip(_ blobIds: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(blobIds, id: \.self) { id in
                    if let data = appState.sentImageCache[id],
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 96, height: 96)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                    Text("Sent")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            )
                    }
                }
            }
        }
        .frame(height: 96)
    }
}

// MARK: - Question Navigation Sheet

private struct QuestionNavSheet: View {
    let turns: [ConversationTurn]
    let isLoadingAll: Bool
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isLoadingAll {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "loading_earlier"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if turns.isEmpty && !isLoadingAll {
                    ContentUnavailableView(
                        String(localized: "no_questions_yet"),
                        systemImage: "questionmark.bubble"
                    )
                } else {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        Button {
                            onSelect(turn.anchorId)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(.blue, in: Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(turn.questionText)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)

                                    if turn.replies.count > 0 {
                                        Text("\(turn.replies.count) \(String(localized: "replies"))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "arrow.up.forward")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(String(localized: "jump_to_question"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared Animated Components

/// A small dot that pulses between two sizes/opacities continuously. Used by the
/// running-tool indicator and wherever we need to say "something is in flight".
struct PulseDot: View {
    let color: Color
    let size: CGFloat
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.15 : 0.75)
            .opacity(on ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Conditionally applies `shimmering()` only when the tool is running.
/// Needed because SwiftUI can't swap modifiers mid-hierarchy without this
/// @ViewBuilder trick — re-creating the modifier on every frame would stutter.
struct ToolRunningShimmer: ViewModifier {
    let isRunning: Bool
    func body(content: Content) -> some View {
        if isRunning {
            content.shimmering()
        } else {
            content
        }
    }
}

/// A modifier that sweeps a soft highlight across the content horizontally,
/// creating a "scanning" feel for in-flight states. Used by running tool cards.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.4

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let gradient = LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0.0),
                            .init(color: .white.opacity(0.22), location: 0.5),
                            .init(color: .white.opacity(0), location: 1.0),
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    Rectangle()
                        .fill(gradient)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width * 2)
                        .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 0.8
                }
            }
    }
}

extension View {
    /// Applies the shimmer sweep effect (see `ShimmerModifier`).
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

/// A row of three dots that cascade up and down, giving "thinking…" a heartbeat
/// so empty thinking events feel alive instead of static.
struct ThinkingDots: View {
    let color: Color
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color.opacity(0.9))
                    .frame(width: 4, height: 4)
                    .scaleEffect(phase == i ? 1.4 : 0.8)
                    .opacity(phase == i ? 1.0 : 0.4)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}
