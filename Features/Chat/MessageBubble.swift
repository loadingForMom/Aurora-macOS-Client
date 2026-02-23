//
//  MessageBubble.swift
//  Aurora
//
//  Bubble styling + macOS trackpad timestamp reveal.
//

import SwiftUI
import AppKit

struct MessageBubble: View {
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

    let mediaService: MediaService
    let mediaStateObserver: MediaProgressProvider.Observer
    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Kept for compatibility; jelly is applied by the parent at the group level.
    var jellyOffsetY: CGFloat = 0

    private let maxReveal: CGFloat = 72
    private let bubbleMaxWidth: CGFloat = 560

    init(
        msg: TGMessage,
        currentChatId: Int64,
        revealTimeX: CGFloat = 0,
        heavyEffectsDisabled: Bool = false,
        isLiveScrolling: Bool = false,
        isScrollPerformanceMode: Bool = false,
        mediaService: MediaService,
        mediaStateObserver: MediaProgressProvider.Observer,
        onRetry: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        jellyOffsetY: CGFloat = 0
    ) {
        self.msg = msg
        self.currentChatId = currentChatId
        self.revealTimeX = revealTimeX
        self.heavyEffectsDisabled = heavyEffectsDisabled
        self.isLiveScrolling = isLiveScrolling
        self.isScrollPerformanceMode = isScrollPerformanceMode
        self.mediaService = mediaService
        self.mediaStateObserver = mediaStateObserver
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.jellyOffsetY = jellyOffsetY

    }

    var body: some View {
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "MessageBubble.body",
            details: "chatId=\(msg.chatId) messageId=\(msg.id) outgoing=\(msg.isOutgoing)"
        )
#endif
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

                        MessageBubbleContentView(
                            msg: msg,
                            bubbleMaxWidth: bubbleMaxWidth,
                            isRevealingTime: isRevealingTime,
                            heavyEffectsDisabled: heavyEffectsDisabled,
                            isLiveScrolling: isLiveScrolling,
                            isScrollPerformanceMode: isScrollPerformanceMode,
                            mediaService: mediaService,
                            mediaStateObserver: mediaStateObserver,
                            onRetry: onRetry
                        )
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
        .onAppear {
#if DEBUG
            PerfCounters.bumpEvent(
                "MessageBubble.onAppear",
                details: "chatId=\(msg.chatId) messageId=\(msg.id) liveScrolling=\(isLiveScrolling)"
            )
#endif
        }
        .onDisappear {
#if DEBUG
            PerfCounters.bumpEvent(
                "MessageBubble.onDisappear",
                details: "chatId=\(msg.chatId) messageId=\(msg.id)"
            )
#endif
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

    private func exactTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

struct MessageMediaAttachmentView: View {
    let chatId: Int64
    let messageId: Int64
    let descriptor: TGMessageMediaDescriptor
    let isLiveScrolling: Bool
    let isScrollPerformanceMode: Bool
    let mediaService: MediaService
    @ObservedObject var mediaStateObserver: MediaProgressProvider.Observer

    @State private var thumbImage: NSImage?
    @State private var thumbPath: String?
    @State private var imageLoadTask: Task<Void, Never>? = nil

    private var mediaState: TGMediaState? {
        mediaStateObserver.state
    }

    private var perfMode: Bool {
        isLiveScrolling || isScrollPerformanceMode
    }

    private var taskId: String {
        let size = placeholderSize
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return "\(chatId):\(messageId):\(descriptor.kind.rawValue):\(descriptor.width)x\(descriptor.height):\(descriptor.thumbnail?.fileId ?? 0):\(descriptor.media?.fileId ?? 0):\(perfMode ? 1 : 0):\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int((scale * 100).rounded()))"
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
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let request = MediaEnsureRequest(
                chatId: chatId,
                messageId: messageId,
                descriptor: descriptor,
                targetPointSize: size,
                screenScale: scale,
                preferThumbnail: perfMode
            )
            let state = await ensureMediaState(for: request)
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

    private func ensureMediaState(for request: MediaEnsureRequest) async -> TGMediaState {
        if request.preferThumbnail {
            return await mediaService.ensureThumbnail(
                chatId: request.chatId,
                messageId: request.messageId,
                descriptor: request.descriptor,
                targetPointSize: request.targetPointSize,
                screenScale: request.screenScale
            )
        }
        return await mediaService.ensureImage(
            chatId: request.chatId,
            messageId: request.messageId,
            descriptor: request.descriptor,
            targetPointSize: request.targetPointSize,
            screenScale: request.screenScale
        )
    }
}

struct BubbleTextView: View {
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
            .foregroundStyle(.white)
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

private struct MessageBubblePreviewContainer: View {
    @StateObject private var store = TelegramStore.preview
    private let mediaProgressProvider = MediaProgressProvider()

    private var incomingMessage: TGMessage {
        TGMessage(
            id: 10_001,
            chatId: 101,
            date: Int(Date().timeIntervalSince1970) - 120,
            isOutgoing: false,
            senderUserId: 7_002,
            text: "Morning! The SwiftUI snapshot now renders instantly."
        )
    }

    private var outgoingMessage: TGMessage {
        TGMessage(
            id: 10_002,
            chatId: 101,
            date: Int(Date().timeIntervalSince1970) - 75,
            isOutgoing: true,
            senderUserId: 7_001,
            text: "Nice. I also disabled network calls in preview mode."
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            MessageBubble(
                msg: incomingMessage,
                currentChatId: 101,
                mediaService: store.mediaService,
                mediaStateObserver: mediaProgressProvider.observer(chatId: 101, messageId: incomingMessage.id)
            )
            MessageBubble(
                msg: outgoingMessage,
                currentChatId: 101,
                mediaService: store.mediaService,
                mediaStateObserver: mediaProgressProvider.observer(chatId: 101, messageId: outgoingMessage.id)
            )
        }
        .padding(16)
        .frame(width: 720)
    }
}

#Preview("MessageBubble") {
    MessageBubblePreviewContainer()
}
