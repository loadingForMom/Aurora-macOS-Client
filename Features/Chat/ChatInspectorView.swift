//
//  ChatInspectorView.swift
//  Aurora
//
//  Scroll-driven “pin” + dissolve-under-glass inspector (macOS 26)
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit
import Foundation

private enum _InspectorCS {
    static let scroll = "InspectorScroll"
}

private enum _InspectorLiquidGlass {
    static let enabledKey = "inspector_liquid_enabled"
    static let glassStrengthKey = "inspector_liquid_glass_strength"
    static let tintStrengthKey = "inspector_liquid_tint_strength"
    static let posterBlurKey = "inspector_liquid_poster_blur"
    static let actionsBlurKey = "inspector_liquid_actions_blur"
    static let chromeOpacityKey = "inspector_liquid_chrome_opacity"

    static let enabledDefault = true
    static let glassStrengthDefault = 0.82
    static let tintStrengthDefault = 0.18
    static let posterBlurDefault = 4.0
    static let actionsBlurDefault = 1.2
    static let chromeOpacityDefault = 0.92
}

private struct _PinnedTitleSlotProbe: View {
    let title: String
    let topPadding: CGFloat
    let avatarSize: CGFloat
    let titleSpacing: CGFloat

    var body: some View {
        VStack(spacing: titleSpacing) {
            Color.clear
                .frame(width: avatarSize, height: avatarSize)

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: _PinnedTitleMinYKey.self,
                            value: geo.frame(in: .named(_InspectorCS.scroll)).minY
                        )
                    }
                )
        }
        .padding(.top, topPadding)
        .frame(maxWidth: .infinity)
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ChatInspectorView: View {
    @EnvironmentObject private var store: TelegramStore
    let chat: TGChat

    @AppStorage(_InspectorLiquidGlass.enabledKey) private var liquidGlassEnabled = _InspectorLiquidGlass.enabledDefault
    @AppStorage(_InspectorLiquidGlass.glassStrengthKey) private var liquidGlassStrength = _InspectorLiquidGlass.glassStrengthDefault
    @AppStorage(_InspectorLiquidGlass.tintStrengthKey) private var liquidGlassTint = _InspectorLiquidGlass.tintStrengthDefault
    @AppStorage(_InspectorLiquidGlass.posterBlurKey) private var liquidPosterBlur = _InspectorLiquidGlass.posterBlurDefault
    @AppStorage(_InspectorLiquidGlass.actionsBlurKey) private var liquidActionsBlur = _InspectorLiquidGlass.actionsBlurDefault
    @AppStorage(_InspectorLiquidGlass.chromeOpacityKey) private var liquidChromeOpacity = _InspectorLiquidGlass.chromeOpacityDefault

    private let heroHeight: CGFloat = 340
    private let overlapFraction: CGFloat = 0.58
    private let pinnedChromeHeight: CGFloat = 280

    private let pinnedTopPadding: CGFloat = 20
    private let pinnedAvatarSize: CGFloat = 70
    private let pinnedTitleSpacing: CGFloat = 8

    private let appearThreshold: CGFloat = 2
    private let appearRange: CGFloat = 20
    private var blurRange: CGFloat { appearThreshold + appearRange }
    private var actionsFadeStart: CGFloat { appearThreshold + appearRange }
    private let actionsFadeRange: CGFloat = 50
    private var maxPosterBlur: CGFloat {
        CGFloat(liquidGlassEnabled ? liquidPosterBlur : 18)
    }

    @State private var heroTitleScrollMinY: CGFloat = .nan
    @State private var pinnedTitleScrollMinY: CGFloat = .nan
    @State private var pinBaselineDelta: CGFloat = .nan
    @State private var hasBaseline: Bool = false
    @State private var baselineWarmupUntil: CFAbsoluteTime = 0
    @State private var scrollTopMinY: CGFloat = .nan
    @State private var baselineScrollTopMinY: CGFloat = .nan
    @State private var settleBaselineWork: DispatchWorkItem?

    // IMPORTANT:
    // Для инспектора берём две разные миниатюры:
    // - posterImage: крупная (для постера/blur), но всё ещё thumbnail, не полный decode исходника.
    // - chromeAvatarImage: маленькая (для pinned chrome), чтобы не тащить огромную картинку в UI.
    //
    // Ключевое: размер постера зависит от ширины окна. Если брать фиксированное значение,
    // на широких инспекторах (и особенно на Retina) получится “мыло”.
    private func posterImage(forWidth width: CGFloat) -> NSImage? {
        let posterPointSize = max(width, heroHeight) // points
        return store.chatAvatarNSImage(
            chatId: chat.id,
            pointSize: posterPointSize,
            preferHiRes: true,
            maxClamp: 3072,
            kindOverride: "chat_poster"
        )
    }

    private var chromeAvatarImage: NSImage? {
        store.chatAvatarNSImage(chatId: chat.id, pointSize: pinnedAvatarSize, preferHiRes: true)
    }

    private var beyondPin: CGFloat {
        guard heroTitleScrollMinY.isFinite, pinnedTitleScrollMinY.isFinite else { return 0 }
        guard hasBaseline, pinBaselineDelta.isFinite else { return 0 }
        let rawDelta = pinnedTitleScrollMinY - heroTitleScrollMinY
        return max(0, rawDelta - pinBaselineDelta)
    }

    private var handoffProgress: CGFloat {
        let x = max(0, beyondPin - appearThreshold)
        return (x / appearRange).clamped(0, 1)
    }

    private var blurProgress: CGFloat {
        (beyondPin / blurRange).clamped(0, 1)
    }

    private var chromeAlpha: Double {
        let base = pow(Double(handoffProgress), 1.6)
        if liquidGlassEnabled {
            return (base * liquidChromeOpacity).clamped(0, 1)
        }
        return base
    }

    private var posterBlurRadius: CGFloat {
        maxPosterBlur * blurProgress
    }

    private var actionsFadeProgress: CGFloat {
        let x = beyondPin - actionsFadeStart
        if x <= 0 { return 0 }
        return (x / actionsFadeRange).clamped(0, 1)
    }

    private var actionsOpacity: Double {
        Double((1 - actionsFadeProgress).clamped(0, 1))
    }

    private var actionsBlur: CGFloat {
        let p = actionsFadeProgress
        if p <= 0.02 { return 0 }
        let maxBlur = liquidGlassEnabled ? CGFloat(liquidActionsBlur) : 2.2
        return maxBlur * p
    }

    private var heroTitleOpacity: Double {
        (1 - chromeAlpha).clamped(0, 1)
    }

    private var heroTitleScale: CGFloat {
        1 - (0.10 * handoffProgress)
    }

    private var heroTitleLift: CGFloat {
        -12 * handoffProgress
    }

    private var subtitleOpacity: Double {
        Double((1 - (handoffProgress * 1.35)).clamped(0, 1))
    }

    private func resetBaseline() {
        settleBaselineWork?.cancel()
        settleBaselineWork = nil

        hasBaseline = false
        pinBaselineDelta = .nan
        baselineScrollTopMinY = .nan
        baselineWarmupUntil = CFAbsoluteTimeGetCurrent() + 0.25
    }

    private func scheduleBaselineSettleCheck() {
        settleBaselineWork?.cancel()
        let work = DispatchWorkItem { snapBaselineIfNeeded() }
        settleBaselineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func snapBaselineIfNeeded() {
        guard hasBaseline, pinBaselineDelta.isFinite else { return }
        guard heroTitleScrollMinY.isFinite, pinnedTitleScrollMinY.isFinite else { return }
        guard baselineScrollTopMinY.isFinite, scrollTopMinY.isFinite else { return }

        let nearTop = abs(scrollTopMinY - baselineScrollTopMinY) < 0.9
        guard nearTop else { return }

        let rawDelta = pinnedTitleScrollMinY - heroTitleScrollMinY
        let residual = max(0, rawDelta - pinBaselineDelta)

        if handoffProgress < 0.05, residual > 0, residual < 8 {
            pinBaselineDelta = rawDelta
        }
    }

    private func updateBaseline() {
        guard heroTitleScrollMinY.isFinite, pinnedTitleScrollMinY.isFinite else { return }

        let rawDelta = pinnedTitleScrollMinY - heroTitleScrollMinY
        let now = CFAbsoluteTimeGetCurrent()

        if !pinBaselineDelta.isFinite {
            pinBaselineDelta = rawDelta
            hasBaseline = true
            return
        }

        if now < baselineWarmupUntil {
            if baselineScrollTopMinY.isFinite, scrollTopMinY.isFinite {
                if abs(scrollTopMinY - baselineScrollTopMinY) > 1.5 {
                    baselineWarmupUntil = 0
                    pinBaselineDelta = rawDelta
                    baselineScrollTopMinY = scrollTopMinY
                }
            }

            if now < baselineWarmupUntil {
                pinBaselineDelta = max(pinBaselineDelta, rawDelta)
            }
        }

        hasBaseline = true
    }

    private func shouldAcceptScrollMetricUpdate(previous: CGFloat, next: CGFloat, epsilon: CGFloat = 0.35) -> Bool {
        if previous.isNaN || next.isNaN {
            return previous.isNaN != next.isNaN
        }
        if !previous.isFinite || !next.isFinite {
            return previous.isFinite != next.isFinite
        }
        return abs(previous - next) >= epsilon
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .top) {
                PosterBackground(
                    image: posterImage(forWidth: width),
                    headerHeight: heroHeight,
                    overlapFraction: overlapFraction,
                    posterBlurRadius: posterBlurRadius,
                    frostAmount: blurProgress,
                    liquidGlassEnabled: liquidGlassEnabled,
                    liquidGlassStrength: CGFloat(liquidGlassStrength),
                    liquidGlassTint: CGFloat(liquidGlassTint)
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: _ScrollTopMinYKey.self,
                                        value: geo.frame(in: .named(_InspectorCS.scroll)).minY
                                    )
                                }
                            )

                        HeroHeader(
                            height: heroHeight,
                            title: chat.title,
                            subtitle: chat.kind.label.isEmpty ? "Chat" : chat.kind.label,
                            titleOpacity: heroTitleOpacity,
                            titleScale: heroTitleScale,
                            titleLift: heroTitleLift,
                            subtitleOpacity: subtitleOpacity,
                            actionsOpacity: actionsOpacity,
                            actionsBlur: actionsBlur
                        )

                        QuickActionsCard()
                        PlaceholderOptionsCard()
                        MoreStubsCard()
                        DebugFillers()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .coordinateSpace(name: _InspectorCS.scroll)
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .top) {
                    _PinnedTitleSlotProbe(
                        title: chat.title,
                        topPadding: pinnedTopPadding,
                        avatarSize: pinnedAvatarSize,
                        titleSpacing: pinnedTitleSpacing
                    )
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onPreferenceChange(_HeroTitleMinYKey.self) {
                    let value = $0
                    DispatchQueue.main.async {
                        guard shouldAcceptScrollMetricUpdate(previous: heroTitleScrollMinY, next: value) else { return }
                        heroTitleScrollMinY = value
                        updateBaseline()
                    }
                }
                .onPreferenceChange(_PinnedTitleMinYKey.self) {
                    let value = $0
                    DispatchQueue.main.async {
                        guard shouldAcceptScrollMetricUpdate(previous: pinnedTitleScrollMinY, next: value) else { return }
                        pinnedTitleScrollMinY = value
                        updateBaseline()
                    }
                }
                .onAppear {
                    // Important: попросим hi-res у TDLib только когда инспектор реально открыт
                    store.prefetchChatAvatarHiResIfNeeded(chatId: chat.id)
                    DispatchQueue.main.async {
                        resetBaseline()
                        updateBaseline()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { updateBaseline() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { updateBaseline() }
                }
                .onPreferenceChange(_ScrollTopMinYKey.self) {
                    let value = $0
                    DispatchQueue.main.async {
                        guard shouldAcceptScrollMetricUpdate(previous: scrollTopMinY, next: value) else { return }
                        scrollTopMinY = value

                        if !baselineScrollTopMinY.isFinite, value.isFinite {
                            baselineScrollTopMinY = value
                        }

                        updateBaseline()
                        scheduleBaselineSettleCheck()
                    }
                }

                PinnedHeaderChrome(
                    title: chat.title,
                    avatar: chromeAvatarImage,
                    height: pinnedChromeHeight,
                    topPadding: pinnedTopPadding,
                    avatarSize: pinnedAvatarSize,
                    titleSpacing: pinnedTitleSpacing,
                    chromeAlpha: chromeAlpha,
                    liquidGlassEnabled: liquidGlassEnabled,
                    liquidGlassStrength: CGFloat(liquidGlassStrength),
                    liquidGlassTint: CGFloat(liquidGlassTint)
                )
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Background (photo + stretched strip + overlap blur)

private struct PosterBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    let image: NSImage?
    let headerHeight: CGFloat
    let overlapFraction: CGFloat

    let posterBlurRadius: CGFloat
    let frostAmount: CGFloat // 0..1
    let liquidGlassEnabled: Bool
    let liquidGlassStrength: CGFloat
    let liquidGlassTint: CGFloat

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let width = geo.size.width
            let stripBlurRadius = liquidGlassEnabled
                ? (10 + (posterBlurRadius * 0.35))
                : (24 + (posterBlurRadius * 0.80))

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if let img = image {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: headerHeight)
                            .clipped()
                            .blur(radius: posterBlurRadius, opaque: true)
                            .overlay(photoDimming)
                            .overlay(Color.black.opacity(0.06 * frostAmount))
                            .overlay(photoMaterialBlend)

                        if let strip = img.bottomStripImage(height: 28) {
                            Image(nsImage: strip)
                                .resizable(resizingMode: .stretch)
                                .frame(width: width, height: max(0, totalHeight - headerHeight))
                                .blur(radius: stripBlurRadius, opaque: true)
                                .overlay(Color.black.opacity(0.03))
                                .overlay(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear,               location: 0.00),
                                            .init(color: .black.opacity(0.05), location: 0.35),
                                            .init(color: .black.opacity(0.08), location: 1.00),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        } else {
                            Rectangle()
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.35))
                                .frame(width: width, height: max(0, totalHeight - headerHeight))
                        }
                    } else {
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor).gradient)
                    }
                }

                if image != nil {
                    overlapBlurOverlay(totalHeight: totalHeight, width: width)
                }
            }
        }
    }

    private var photoDimming: some View {
        LinearGradient(
            stops: [
                .init(color: .clear,               location: 0.00),
                .init(color: .black.opacity(0.10), location: 0.70),
                .init(color: .black.opacity(0.24), location: 1.00),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var photoMaterialBlend: some View {
        let strength = liquidGlassStrength.clamped(0, 1.5)
        let tint = liquidGlassTint.clamped(0, 1)

        let base: AnyView = {
            if reduceTransparency {
                return AnyView(Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.22)))
            } else if liquidGlassEnabled {
                return AnyView(
                    Color.clear
                        .glassEffect(in: Rectangle())
                        .overlay(
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .opacity(0.14 + (0.30 * strength))
                        )
                )
            } else {
                return AnyView(Rectangle().fill(.ultraThinMaterial))
            }
        }()

        return base
            .overlay(colorScheme == .dark
                     ? Color.black.opacity(0.04 + (0.18 * tint))
                     : Color(nsColor: .windowBackgroundColor).opacity(0.02 + (0.11 * tint)))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear,               location: 0.00),
                        .init(color: .clear,               location: 0.22),
                        .init(color: .black.opacity(0.10),  location: 0.42),
                        .init(color: .black.opacity(0.26),  location: 0.56),
                        .init(color: .black.opacity(0.48),  location: 0.68),
                        .init(color: .black.opacity(0.72),  location: 0.82),
                        .init(color: .black,               location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }

    private func overlapBlurOverlay(totalHeight: CGFloat, width: CGFloat) -> some View {
        let strength = liquidGlassStrength.clamped(0, 1.5)
        let tint = liquidGlassTint.clamped(0, 1)
        let overlapHeight = headerHeight * overlapFraction
        let overlayTop = headerHeight - overlapHeight
        let overlayHeight = max(0, totalHeight - overlayTop)

        // 1) если высоты почти нет — нечего маскировать
        guard overlayHeight > 1 else {
            return AnyView(EmptyView())
        }

        // 2) clamp ratio в 0...1 и защитимся от NaN/inf
        let raw = overlapHeight / overlayHeight
        let r: CGFloat = raw.isFinite ? raw.clamped(0, 1) : 0

        // 3) гарантируем строго возрастающие стопы
        let eps: CGFloat = 0.0005
        let s0: CGFloat = 0.0
        let s1: CGFloat = max(s0 + eps, min(r * 0.10, 1 - eps * 5))
        let s2: CGFloat = max(s1 + eps, min(r * 0.30, 1 - eps * 4))
        let s3: CGFloat = max(s2 + eps, min(r * 0.60, 1 - eps * 3))
        let s4: CGFloat = max(s3 + eps, min(r * 0.85, 1 - eps * 2))
        let s5: CGFloat = max(s4 + eps, min(r,        1 - eps))
        let s6: CGFloat = 1.0

        let base: AnyView = {
            if reduceTransparency {
                return AnyView(Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            } else if liquidGlassEnabled {
                return AnyView(
                    Color.clear
                        .glassEffect(in: Rectangle())
                        .overlay(
                            Rectangle()
                                .fill(.thinMaterial)
                                .opacity(0.14 + (0.34 * strength))
                        )
                )
            } else {
                return AnyView(Rectangle().fill(.ultraThinMaterial))
            }
        }()

        return AnyView(
            base
                .frame(width: width, height: overlayHeight)
                .overlay(colorScheme == .dark
                         ? Color.black.opacity(0.02 + (0.10 * tint))
                         : Color(nsColor: .windowBackgroundColor).opacity(0.03 + (0.14 * tint)))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.03), location: s0),
                            .init(color: .black.opacity(0.08), location: s1),
                            .init(color: .black.opacity(0.18), location: s2),
                            .init(color: .black.opacity(0.45), location: s3),
                            .init(color: .black.opacity(0.75), location: s4),
                            .init(color: .black,               location: s5),
                            .init(color: .black,               location: s6),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(y: overlayTop)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Hero header

private struct HeroHeader: View {
    let height: CGFloat
    let title: String
    let subtitle: String

    let titleOpacity: Double
    let titleScale: CGFloat
    let titleLift: CGFloat
    let subtitleOpacity: Double

    let actionsOpacity: Double
    let actionsBlur: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            VStack(spacing: 4) {
                ZStack {
                    Text(title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .opacity(0.001)
                        .accessibilityHidden(true)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: _HeroTitleMinYKey.self,
                                    value: geo.frame(in: .named(_InspectorCS.scroll)).minY
                                )
                            }
                        )

                    Text(title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                        .lineLimit(2)
                        .scaleEffect(titleScale)
                        .offset(y: titleLift)
                        .opacity(titleOpacity)
                }

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
                    .lineLimit(1)
                    .opacity(subtitleOpacity)

                Group {
                    if actionsBlur > 0.001 {
                        HeroActionRow()
                            .compositingGroup()
                            .blur(radius: actionsBlur, opaque: false)
                    } else {
                        HeroActionRow()
                    }
                }
                .opacity(actionsOpacity)
                .allowsHitTesting(actionsOpacity > 0.05)
                .padding(.top, 4)
            }
            .padding(.bottom, 12)
            .padding(.horizontal, 8)
        }
        .frame(height: height)
    }
}

// MARK: - Hero actions (Liquid Glass)

private struct HeroActionRow: View {
    var body: some View {
        HStack(spacing: 10) {
            HeroActionButton(icon: "message.fill", label: "Chat")
            HeroActionButton(icon: "phone.fill", label: "Audio")
            HeroActionButton(icon: "video.fill", label: "Video")
            HeroActionButton(icon: "bell.fill", label: "Mute")
        }
        .padding(10)
    }
}

private struct HeroActionButton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let icon: String
    let label: String

    var body: some View {
        Button {
            // stub
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if reduceTransparency {
                        Circle()
                            .fill(Color.black.opacity(0.25))
                            .frame(width: 44, height: 44)
                    } else {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .glassEffect(in: Circle())
                    }

                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 0.5)
                }
                .frame(width: 44, height: 44)

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pinned chrome

private struct PinnedHeaderChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let avatar: NSImage?

    let height: CGFloat
    let topPadding: CGFloat
    let avatarSize: CGFloat
    let titleSpacing: CGFloat

    let chromeAlpha: Double
    let liquidGlassEnabled: Bool
    let liquidGlassStrength: CGFloat
    let liquidGlassTint: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            chromeBackground
                .offset(y: ChatHeaderFixedMetrics.inspectorGlassOffsetY)
                .opacity(chromeAlpha)

            VStack(spacing: titleSpacing) {
                MiniAvatar(avatar: avatar, title: title, size: avatarSize)
                    .opacity(chromeAlpha)

                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .opacity(chromeAlpha)
            }
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
    }

    private var chromeBackground: some View {
        let strength = liquidGlassStrength.clamped(0, 1.5)
        let tint = liquidGlassTint.clamped(0, 1)

        let base: AnyView = {
            if reduceTransparency {
                return AnyView(Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.95)))
            } else if liquidGlassEnabled {
                return AnyView(
                    Color.clear
                        .glassEffect(in: Rectangle())
                        .overlay(
                            Rectangle()
                                .fill(.regularMaterial)
                                .opacity(0.10 + (0.28 * strength))
                        )
                )
            } else {
                return AnyView(Color.clear.glassEffect(in: Rectangle()))
            }
        }()

        return base
            .overlay(
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor).opacity(0.28),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(0.52 + (0.24 * tint))
            )
            .overlay(
                Group {
                    if reduceTransparency {
                        EmptyView()
                    } else {
                        Rectangle()
                            .fill(liquidGlassEnabled ? .thinMaterial : .ultraThinMaterial)
                            .overlay(
                                colorScheme == .dark
                                    ? Color.black.opacity(liquidGlassEnabled ? (0.03 + (0.08 * tint)) : 0.06)
                                    : Color.clear
                            )
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black,               location: 0.00),
                                        .init(color: .black.opacity(0.95), location: 0.35),
                                        .init(color: .black.opacity(0.55), location: 0.60),
                                        .init(color: .black.opacity(0.20), location: 0.78),
                                        .init(color: .clear,              location: 1.00),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black,               location: 0.00),
                        .init(color: .black,               location: 0.35),
                        .init(color: .black.opacity(0.92),  location: 0.60),
                        .init(color: .black.opacity(0.70),  location: 0.75),
                        .init(color: .black.opacity(0.45),  location: 0.86),
                        .init(color: .black.opacity(0.22),  location: 0.94),
                        .init(color: .black.opacity(0.10),  location: 0.98),
                        .init(color: .clear,               location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private struct MiniAvatar: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let avatar: NSImage?
    let title: String
    let size: CGFloat

    var body: some View {
        ZStack {
            if reduceTransparency {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                    .frame(width: size, height: size)
            } else {
                Color.clear
                    .frame(width: size, height: size)
                    .glassEffect(in: Circle())
            }

            if let avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size - 6, height: size - 6)
                    .clipShape(Circle())
            } else {
                Text(initials(from: title))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .accessibilityLabel(Text("Avatar"))
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).map { String($0.prefix(1)).uppercased() }
        return parts.isEmpty ? "?" : parts.joined()
    }
}

// MARK: - Cards

private struct InspectorCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) { content() }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct InspectorRowButton: View {
    let title: String
    let systemImage: String

    var body: some View {
        Button {
            // stub
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct QuickActionsCard: View {
    var body: some View {
        InspectorCard(title: "Quick actions") {
            InspectorRowButton(title: "Search in chat", systemImage: "magnifyingglass")
            Divider().opacity(0.35)
            InspectorRowButton(title: "Shared media", systemImage: "photo.on.rectangle")
            Divider().opacity(0.35)
            InspectorRowButton(title: "Notifications", systemImage: "bell")
            Divider().opacity(0.35)
            InspectorRowButton(title: "Privacy", systemImage: "hand.raised")
        }
    }
}

private struct PlaceholderOptionsCard: View {
    var body: some View {
        InspectorCard(title: "Options (stub)") {
            InspectorRowButton(title: "Pinned messages", systemImage: "pin")
            Divider().opacity(0.35)
            InspectorRowButton(title: "Appearance", systemImage: "paintbrush")
            Divider().opacity(0.35)
            InspectorRowButton(title: "Report / Block", systemImage: "exclamationmark.bubble")
        }
    }
}

private struct MoreStubsCard: View {
    private let items: [(String, String)] = [
        ("Members", "person.2"),
        ("Invite link", "link"),
        ("Files", "doc"),
        ("Links", "link.circle"),
        ("Voice", "waveform"),
        ("Bots", "cpu"),
        ("Saved messages", "bookmark"),
        ("Wallpaper", "sparkles"),
        ("Statistics", "chart.bar"),
        ("Permissions", "lock"),
        ("Devices", "laptopcomputer"),
        ("Storage", "externaldrive"),
        ("Data export", "square.and.arrow.up"),
        ("Language", "globe"),
        ("About", "info.circle"),
        ("Advanced", "gearshape.2")
    ]

    var body: some View {
        InspectorCard(title: "More (stub)") {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                InspectorRowButton(title: item.0, systemImage: item.1)
                if i != items.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }
}

private struct DebugFillers: View {
    var body: some View {
        ForEach(0..<10, id: \.self) { i in
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .frame(height: 52)
                .overlay(
                    HStack {
                        Text("Placeholder \(i)")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

// MARK: - Preference keys (NaN-safe)

private struct _ScrollTopMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if value.isNaN { value = next; return }
        if next.isNaN { return }
        value = min(value, next)
    }
}

private struct _HeroTitleMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if value.isNaN { value = next; return }
        if next.isNaN { return }
        value = min(value, next)
    }
}

private struct _PinnedTitleMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if value.isNaN { value = next; return }
        if next.isNaN { return }
        value = min(value, next)
    }
}

private extension CGFloat {
    func clamped(_ min: CGFloat, _ max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, min), max)
    }
}

private extension Double {
    func clamped(_ min: Double, _ max: Double) -> Double {
        Swift.min(Swift.max(self, min), max)
    }
}

private extension NSImage {
    func bottomStripImage(height: Int) -> NSImage? {
        guard let cg = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width
        let h = cg.height
        guard w > 2, h > 2 else { return nil }

        let stripH = Swift.max(1, Swift.min(height, h))
        let y = Swift.max(0, h - stripH)

        guard let cropped = cg.cropping(to: CGRect(x: 0, y: y, width: w, height: stripH)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: w, height: stripH))
    }
}

private struct ChatInspectorViewPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview

    private let chat = TGChat(
        id: 101,
        title: "Preview Playground",
        kind: .basicGroup,
        order: 9_999_999,
        lastMessagePreview: "Looks great. Let's ship this setup.",
        lastMessageDate: Int(Date().timeIntervalSince1970) - 75
    )

    var body: some View {
        ChatInspectorView(chat: chat)
            .environmentObject(store)
            .frame(width: 380, height: 820)
    }
}

#Preview("ChatInspectorView") {
    ChatInspectorViewPreviewContainer()
}
