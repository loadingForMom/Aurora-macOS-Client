//
//  MessageBubble.swift
//  Aurora
//
//  Bubble styling + macOS trackpad timestamp reveal.
//

import SwiftUI
import AppKit

struct MessageBubble: View {
    @ObservedObject var store: TelegramStore
    let msg: TGMessage
    let currentChatId: Int64

    /// Trackpad “reveal exact time” (0…maxReveal), passed from parent.
    let revealTimeX: CGFloat

    /// Simplified visual effects mode for dense windows and live scroll.
    let heavyEffectsDisabled: Bool

    /// Native live scrolling state from NSScrollView.
    let isLiveScrolling: Bool

    /// Transient lightweight mode that may outlive live scroll for a short debounce.
    let isScrollPerformanceMode: Bool

    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Kept for compatibility; jelly is applied by the parent at the group level.
    var jellyOffsetY: CGFloat = 0

    private let maxReveal: CGFloat = 72
    private let bubbleMaxWidth: CGFloat = 560

    init(
        store: TelegramStore,
        msg: TGMessage,
        currentChatId: Int64,
        revealTimeX: CGFloat = 0,
        heavyEffectsDisabled: Bool = false,
        isLiveScrolling: Bool = false,
        isScrollPerformanceMode: Bool = false,
        onRetry: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        jellyOffsetY: CGFloat = 0
    ) {
        self.store = store
        self.msg = msg
        self.currentChatId = currentChatId
        self.revealTimeX = revealTimeX
        self.heavyEffectsDisabled = heavyEffectsDisabled
        self.isLiveScrolling = isLiveScrolling
        self.isScrollPerformanceMode = isScrollPerformanceMode
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.jellyOffsetY = jellyOffsetY

    }

    var body: some View {
        let reveal = min(max(0, revealTimeX), maxReveal)
        let isRevealingTime = reveal > 0.5

        return Group {
            if msg.chatId != currentChatId {
#if DEBUG
                Text("[debug] message/chat mismatch")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
#else
                EmptyView()
#endif
            } else {
                ZStack(alignment: .trailing) {
                    HStack {
                        if msg.isOutgoing { Spacer(minLength: 40) }

                        content(isRevealingTime: isRevealingTime)
                            .offset(x: -reveal)

                        if !msg.isOutgoing { Spacer(minLength: 40) }
                    }

                    if isRevealingTime {
                        Text(exactTime(msg.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .opacity(min(1, reveal / 16))
                            .offset(x: (maxReveal - reveal))
                            .padding(.trailing, 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: msg.isOutgoing ? .trailing : .leading)
                .offset(y: jellyOffsetY)
                .modifier(
                    MessageContextMenuModifier(
                        enabled: !isLiveScrolling,
                        msg: msg,
                        onRetry: onRetry,
                        onDelete: onDelete
                    )
                )
            }
        }
        .transaction { transaction in
            if isLiveScrolling || isScrollPerformanceMode {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }

    private struct MessageContextMenuModifier: ViewModifier {
        let enabled: Bool
        let msg: TGMessage
        let onRetry: () -> Void
        let onDelete: () -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.contextMenu {
                    if let copyText = msg.textForRendering?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !copyText.isEmpty {
                        Button("Copy") {
                            copyToPasteboard(copyText)
                        }
                    }

                    if msg.isOutgoing {
                        if case .failed = msg.sendState, msg.canRetry {
                            Button("Retry") { onRetry() }
                        }
                        Button("Delete") { onDelete() }
                    }
                }
            } else {
                content
            }
        }

        private func copyToPasteboard(_ value: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    @ViewBuilder
    private func content(isRevealingTime: Bool) -> some View {
        let hideStatusLine = isRevealingTime && isSentState
        let hasMedia = mediaDescriptor != nil
        let shouldRenderText = shouldRenderTextContent

        VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 4) {
            VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: hasMedia && shouldRenderText ? 8 : 0) {
                if let descriptor = mediaDescriptor {
                    MessageMediaAttachmentView(
                        store: store,
                        chatId: msg.chatId,
                        messageId: msg.id,
                        descriptor: descriptor,
                        isLiveScrolling: isLiveScrolling,
                        isScrollPerformanceMode: isScrollPerformanceMode
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, shouldRenderText ? 0 : 8)
                }

                if shouldRenderText {
                    BubbleTextView(
                        chatId: msg.chatId,
                        messageId: msg.id,
                        rawText: msg.textForRendering,
                        entities: msg.entities,
                        isOutgoing: msg.isOutgoing,
                        textSelectionEnabled: !isLiveScrolling
                    )
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if !heavyEffectsDisabled {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
            }

            HStack(spacing: 6) {
                if msg.isEdited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(isRevealingTime ? 0 : 1)
                }
                statusView
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            // Keep status row in layout while revealing so bubbles do not jump on Y.
            .opacity(hideStatusLine ? 0 : 1)
            .allowsHitTesting(!hideStatusLine)
        }
        .frame(maxWidth: bubbleMaxWidth, alignment: msg.isOutgoing ? .trailing : .leading)
    }

    private var mediaDescriptor: TGMessageMediaDescriptor? {
        guard msg.contentType == "messagePhoto" || msg.contentType == "messageVideo" else { return nil }
        return msg.media
    }

    private var shouldRenderTextContent: Bool {
        if mediaDescriptor != nil {
            guard let text = msg.textForRendering?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !text.isEmpty
        }
        return true
    }

    private var isSentState: Bool {
        if case .sent = msg.sendState { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch msg.sendState {
        case .sent:
            Text(relativeTime(msg.date))

        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }

        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }

        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)

                if msg.canRetry {
                    Button("Retry") { onRetry() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                } else {
                    Text("Failed")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if msg.isOutgoing {
            // Make outgoing bubbles always “Messages blue” on macOS.
            return AnyShapeStyle(Color(nsColor: .systemBlue))
        } else {
            if heavyEffectsDisabled {
                return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            }
            return AnyShapeStyle(.thinMaterial)
        }
    }

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func exactTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.timeFormatter.string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

private struct MessageMediaAttachmentView: View {
    @ObservedObject var store: TelegramStore
    let chatId: Int64
    let messageId: Int64
    let descriptor: TGMessageMediaDescriptor
    let isLiveScrolling: Bool
    let isScrollPerformanceMode: Bool

    @State private var thumbImage: NSImage?
    @State private var thumbPath: String?
    @State private var imageLoadTask: Task<Void, Never>? = nil

    private var mediaState: TGMediaState? {
        store.mediaStateByMessageKey[TGMessageMediaKey(chatId: chatId, messageId: messageId)]
    }

    private var perfMode: Bool {
        isLiveScrolling || isScrollPerformanceMode
    }

    private var taskId: String {
        "\(chatId):\(messageId):\(descriptor.kind.rawValue):\(descriptor.width)x\(descriptor.height):\(descriptor.thumbnail?.fileId ?? 0):\(descriptor.media?.fileId ?? 0):\(perfMode ? 1 : 0)"
    }

    private var placeholderSize: CGSize {
        let rawAspect = CGFloat(max(1, descriptor.width)) / CGFloat(max(1, descriptor.height))
        let aspect = min(max(rawAspect, 0.42), 2.2)
        let width: CGFloat = perfMode ? 220 : 240
        let height = min(300, max(120, width / aspect))
        return CGSize(width: width, height: height)
    }

    var body: some View {
        let size = placeholderSize

        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.22))

            if let thumbImage {
                Image(nsImage: thumbImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }

            if descriptor.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.45))
                    )
            }

            if let state = mediaState, state.isLoading {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.26))
                    if let progress = state.progress, progress > 0 {
                        VStack(spacing: 6) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: max(72, size.width * 0.48))
                            Text("\(Int(progress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: taskId) {
            let state = await store.ensureMediaThumbnail(
                chatId: chatId,
                messageId: messageId,
                descriptor: descriptor,
                preferThumbnailOnly: perfMode
            )
            scheduleImageLoad(path: state.thumbnailPath)
        }
        .onChange(of: mediaState?.thumbnailPath) { _, newPath in
            scheduleImageLoad(path: newPath)
        }
        .onDisappear {
            imageLoadTask?.cancel()
            imageLoadTask = nil
        }
        .animation(perfMode ? nil : .easeOut(duration: 0.14), value: thumbPath)
    }

    @MainActor
    private func scheduleImageLoad(path: String?) {
        imageLoadTask?.cancel()
        imageLoadTask = Task { @MainActor [path] in
            await loadThumbnail(path: path)
        }
    }

    @MainActor
    private func loadThumbnail(path: String?) async {
        guard let path, !path.isEmpty else {
            thumbPath = nil
            thumbImage = nil
            return
        }
        if thumbPath == path, thumbImage != nil {
            return
        }
        thumbPath = path
        let loaded = await DiskImageCache.shared.imageAsync(path: path)
        guard !Task.isCancelled else { return }
        guard thumbPath == path else { return }
        thumbImage = loaded
    }
}

private struct BubbleTextView: View {
    let chatId: Int64
    let messageId: Int64
    let rawText: String?
    let entities: [TGTextEntity]
    let isOutgoing: Bool
    let textSelectionEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var attributed: AttributedString
    @State private var renderTask: Task<Void, Never>? = nil
    @State private var lastRenderedTextSignature: TextRenderSignature? = nil
    @State private var inFlightTextSignature: TextRenderSignature? = nil

    private struct TextRenderSignature: Hashable {
        let rawText: String?
        let entities: [TGTextEntity]
        let style: MessageTextStyle
        let colorScheme: ColorScheme
        let dynamicTypeSize: DynamicTypeSize
    }

    init(
        chatId: Int64,
        messageId: Int64,
        rawText: String?,
        entities: [TGTextEntity],
        isOutgoing: Bool,
        textSelectionEnabled: Bool
    ) {
        self.chatId = chatId
        self.messageId = messageId
        self.rawText = rawText
        self.entities = entities
        self.isOutgoing = isOutgoing
        self.textSelectionEnabled = textSelectionEnabled
        let initialInput = MessageTextRenderInput(
            chatId: chatId,
            messageId: messageId,
            rawText: rawText,
            entities: entities,
            style: .bubbleBody
        )
        _attributed = State(
            initialValue: MessageTextPipeline.cachedValue(initialInput)
                ?? Self.fallbackAttributed(rawText: rawText)
        )
    }

    var body: some View {
        selectableText
            .foregroundStyle(isOutgoing ? .white : .primary)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            let textSignature = textRenderSignature
            if lastRenderedTextSignature == nil,
               MessageTextPipeline.cachedValue(renderInput) != nil {
                lastRenderedTextSignature = textSignature
            }
            scheduleRerenderIfNeeded()
        }
        .onChange(of: messageId) { _, _ in
            scheduleRerenderIfNeeded()
        }
        .onChange(of: rawText) { _, _ in
            scheduleRerenderIfNeeded()
        }
        .onChange(of: entities) { _, _ in
            scheduleRerenderIfNeeded()
        }
        .onChange(of: colorScheme) { _, _ in
            scheduleRerenderIfNeeded()
        }
        .onChange(of: dynamicTypeSize) { _, _ in
            scheduleRerenderIfNeeded()
        }
        .onDisappear {
            renderTask?.cancel()
            renderTask = nil
            inFlightTextSignature = nil
        }
    }

    @ViewBuilder
    private var selectableText: some View {
        if textSelectionEnabled {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(attributed)
                .textSelection(.disabled)
        }
    }

    private var renderInput: MessageTextRenderInput {
        MessageTextRenderInput(
            chatId: chatId,
            messageId: messageId,
            rawText: rawText,
            entities: entities,
            style: .bubbleBody
        )
    }

    private var textRenderSignature: TextRenderSignature {
        TextRenderSignature(
            rawText: rawText,
            entities: entities,
            style: .bubbleBody,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    @MainActor
    private func scheduleRerenderIfNeeded() {
        let signature = textRenderSignature
        guard lastRenderedTextSignature != signature else { return }
        guard inFlightTextSignature != signature else { return }

        renderTask?.cancel()
        inFlightTextSignature = signature
        let input = renderInput

        renderTask = Task { [signature, input] in
            let rendered = await MessageTextPipeline.renderAsync(input, priority: .userInitiated)
            guard !Task.isCancelled else { return }
            guard inFlightTextSignature == signature else { return }
            attributed = rendered
            lastRenderedTextSignature = signature
            inFlightTextSignature = nil
            renderTask = nil
        }
    }

    private static func fallbackAttributed(rawText: String?) -> AttributedString {
        if let rawText, !rawText.isEmpty {
            return AttributedString(rawText)
        }
        return AttributedString("[unsupported message]")
    }
}
