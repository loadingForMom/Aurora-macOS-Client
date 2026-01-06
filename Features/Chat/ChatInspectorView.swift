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

// MARK: - Pinned title slot probe (viewport overlay; does NOT scroll)

private struct _PinnedTitleSlotProbe: View {
    let title: String
    let topPadding: CGFloat
    let avatarSize: CGFloat
    let titleSpacing: CGFloat

    var body: some View {
        VStack(spacing: titleSpacing) {
            // Avatar placeholder (matches pinned chrome layout)
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
        // Keep it in the tree for measurement but invisible.
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ChatInspectorView: View {
    @EnvironmentObject private var store: TelegramStore
    let chat: TGChat

    // MARK: - Layout (tuned for macOS inspector column)

    private let heroHeight: CGFloat = 340
    private let overlapFraction: CGFloat = 0.58       // stronger overlap to eliminate the mid-gap between top glass and lower blur
    private let pinnedChromeHeight: CGFloat = 280
    // more room for larger avatar + title and a softer fade

    private let pinnedTopPadding: CGFloat = 20
    private let pinnedAvatarSize: CGFloat = 70
    private let pinnedTitleSpacing: CGFloat = 8

    // MARK: - Pin logic tuning

    /// “Дошло до места” (порог). До него pinned = 0.
    private let appearThreshold: CGFloat = 2

    /// Насколько быстро проявляется pinned chrome (мини‑аватар + имя).
    private let appearRange: CGFloat = 20

    /// Блюр должен “обогнать” chrome: к моменту полной видимости pinned,
    /// постер уже почти в полном блюре.
    private var blurRange: CGFloat { appearThreshold + appearRange } // ~12pt

    /// Кнопки исчезают уже после того, как pinned‑состояние сформировалось.
    private var actionsFadeStart: CGFloat { appearThreshold + appearRange }
    private let actionsFadeRange: CGFloat = 50

    private let maxPosterBlur: CGFloat = 18

    // MARK: - Measurements (ScrollView coordinate space)

    @State private var heroTitleScrollMinY: CGFloat = .nan
    @State private var pinnedTitleScrollMinY: CGFloat = .nan
    @State private var pinBaselineDelta: CGFloat = .nan // captured at rest so beyondPin starts at 0
    @State private var hasBaseline: Bool = false
    // Baseline warmup: during the first few ticks after appear, layout can still shift (esp. long titles/emoji).
    // We track the MAX raw delta so `beyondPin` starts at 0 instead of starting “already pinned”.
    @State private var baselineWarmupUntil: CFAbsoluteTime = 0
    // Track actual scroll movement so warmup doesn’t “eat” the first slow drag.
    @State private var scrollTopMinY: CGFloat = .nan
    @State private var baselineScrollTopMinY: CGFloat = .nan
    // Debounced settle check to re-zero tiny residual beyondPin after fast fling/bounce.
    @State private var settleBaselineWork: DispatchWorkItem?

    private var avatarImage: NSImage? {
        store.chatAvatarNSImage(chatId: chat.id)
    }

    // MARK: - Derived progress

    /// How far the hero title moved above the pinned title slot (in the SAME ScrollView coord space).
    private var beyondPin: CGFloat {
        guard heroTitleScrollMinY.isFinite, pinnedTitleScrollMinY.isFinite else { return 0 }
        // Until we have a baseline, treat the view as “resting” so buttons never start blurred.
        guard hasBaseline, pinBaselineDelta.isFinite else { return 0 }
        let rawDelta = pinnedTitleScrollMinY - heroTitleScrollMinY
        return max(0, rawDelta - pinBaselineDelta)
    }

    /// Progress for pinned chrome appearance (thresholded).
    private var handoffProgress: CGFloat {
        let x = max(0, beyondPin - appearThreshold)
        return (x / appearRange).clamped(0, 1)
    }

    /// Progress for poster blur (fast).
    private var blurProgress: CGFloat {
        (beyondPin / blurRange).clamped(0, 1)
    }

    /// Gamma-corrected alpha so the first few % aren’t visually “already there”.
    private var chromeAlpha: Double {
        pow(Double(handoffProgress), 1.6)
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
        // Never blur in the expanded state; start blurring only once fade has actually begun.
        if p <= 0.02 { return 0 }
        return 2.2 * p
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

    // Toggle quickly when debugging
    #if DEBUG
    private let showDebugOverlay: Bool = false
    #endif

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

    /// After fast scroll/bounce, SwiftUI can leave us with a tiny residual delta at rest.
    /// If we’re back at the top and not actually pinned, snap the baseline to the current rawDelta.
    private func snapBaselineIfNeeded() {
        guard hasBaseline, pinBaselineDelta.isFinite else { return }
        guard heroTitleScrollMinY.isFinite, pinnedTitleScrollMinY.isFinite else { return }
        guard baselineScrollTopMinY.isFinite, scrollTopMinY.isFinite else { return }

        // Only when we’re essentially back at the top.
        let nearTop = abs(scrollTopMinY - baselineScrollTopMinY) < 0.9
        guard nearTop else { return }

        let rawDelta = pinnedTitleScrollMinY - heroTitleScrollMinY
        let residual = max(0, rawDelta - pinBaselineDelta)

        // If we’re not in pinned mode (or barely starting), and residual is tiny, re-zero it.
        if handoffProgress < 0.05, residual > 0, residual < 8 {
            pinBaselineDelta = rawDelta
        }
    }

    // MARK: - Baseline capture (warmup, then lock)
    private func updateBaseline() {
        guard heroTitleScrollMinY.isFinite, pinnedTitleScrollMinY.isFinite else { return }

        let rawDelta = pinnedTitleScrollMinY - heroTitleScrollMinY
        let now = CFAbsoluteTimeGetCurrent()

        // First sample
        if !pinBaselineDelta.isFinite {
            pinBaselineDelta = rawDelta
            hasBaseline = true
            return
        }

        // During warmup, layout may still move the probe/title a few points.
        if now < baselineWarmupUntil {
            // If the user starts scrolling, immediately lock baseline to the CURRENT state.
            // This prevents fast fling up/down from ever capturing a “moving” baseline.
            if baselineScrollTopMinY.isFinite, scrollTopMinY.isFinite {
                if abs(scrollTopMinY - baselineScrollTopMinY) > 1.5 {
                    baselineWarmupUntil = 0
                    pinBaselineDelta = rawDelta
                    baselineScrollTopMinY = scrollTopMinY
                }
            }

            // If still warming up (no user scroll yet), track MAX raw delta so resting state yields beyondPin == 0.
            if now < baselineWarmupUntil {
                pinBaselineDelta = max(pinBaselineDelta, rawDelta)
            }
        }

        hasBaseline = true
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {

            PosterBackground(
                image: avatarImage,
                headerHeight: heroHeight,
                overlapFraction: overlapFraction,
                posterBlurRadius: posterBlurRadius,
                frostAmount: blurProgress
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Scroll offset probe (moves with content)
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
                heroTitleScrollMinY = $0
                updateBaseline()
            }
            .onPreferenceChange(_PinnedTitleMinYKey.self) {
                pinnedTitleScrollMinY = $0
                updateBaseline()
            }
            .onAppear {
                resetBaseline()
                DispatchQueue.main.async { updateBaseline() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { updateBaseline() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { updateBaseline() }
            }
            .onChange(of: chat.id) { _ in
                resetBaseline()
                DispatchQueue.main.async { updateBaseline() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { updateBaseline() }
            }
            .onPreferenceChange(_ScrollTopMinYKey.self) {
                scrollTopMinY = $0

                // Capture the initial “top rest” position once (used to detect return-to-top).
                if !baselineScrollTopMinY.isFinite, $0.isFinite {
                    baselineScrollTopMinY = $0
                }

                updateBaseline()
                scheduleBaselineSettleCheck()
            }

            PinnedHeaderChrome(
                title: chat.title,
                avatar: avatarImage,
                height: pinnedChromeHeight,
                topPadding: pinnedTopPadding,
                avatarSize: pinnedAvatarSize,
                titleSpacing: pinnedTitleSpacing,
                chromeAlpha: chromeAlpha
            )
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)

            #if DEBUG
            if showDebugOverlay {
                Text("beyondPin \(Int(beyondPin))  handoff \(String(format: "%.2f", Double(handoffProgress)))  blur \(String(format: "%.2f", Double(blurProgress)))")
                    .font(.caption2)
                    .padding(6)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 6)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            #endif
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let width = geo.size.width

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
                            // Blend the photo into the lower material so there’s no visible “band”.
                            .overlay(photoMaterialBlend)

                        if let strip = img.bottomStripImage(height: 28) {
                            Image(nsImage: strip)
                                .resizable(resizingMode: .stretch)
                                .frame(width: width, height: max(0, totalHeight - headerHeight))
                                // Blend better with the hero photo: reduce the base blur and let it follow posterBlurRadius more.
                                .blur(radius: 24 + (posterBlurRadius * 0.80), opaque: true)
                                // Less dark tint so it doesn’t read as a “band”.
                                .overlay(Color.black.opacity(0.03))
                                // Soft top fade so the seam at `headerHeight` is less noticeable.
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

    // Material fade on the hero photo itself.
    // This removes the hard transition where the lower overlap material begins.
    private var photoMaterialBlend: some View {
        let base: AnyView = {
            if reduceTransparency {
                return AnyView(Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.22)))
            } else {
                return AnyView(Rectangle().fill(.ultraThinMaterial))
            }
        }()

        return base
            // In dark mode, Liquid Glass can create a bright “highlight belt”.
            // Counter it with a subtle dark tint; in light mode keep a neutral window tint.
            .overlay(colorScheme == .dark
                     ? Color.black.opacity(0.08)
                     : Color(nsColor: .windowBackgroundColor).opacity(0.04))
            .mask(
                LinearGradient(
                    // Smoother ramp: avoids a mid-level plateau that reads as a horizontal band.
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
        let overlapHeight = headerHeight * overlapFraction
        let overlayTop = headerHeight - overlapHeight
        let overlayHeight = max(0, totalHeight - overlayTop)
        let overlapRatio = overlayHeight > 0 ? overlapHeight / overlayHeight : 0

        let base: AnyView = {
            if reduceTransparency {
                return AnyView(Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            } else {
                return AnyView(Rectangle().fill(.ultraThinMaterial))
            }
        }()

        return base
            .frame(width: width, height: overlayHeight)
            // Neutral tint for legibility. In dark mode, keep it lighter to avoid a visible belt.
            .overlay(colorScheme == .dark
                     ? Color.black.opacity(0.03)
                     : Color(nsColor: .windowBackgroundColor).opacity(0.06))
            .mask(
                LinearGradient(
                    stops: [
                        // Avoid a fully-clear band at the top — it reads as a “gap” between blur layers.
                        .init(color: .black.opacity(0.03),  location: 0.00),
                        .init(color: .black.opacity(0.08),  location: max(0.00, overlapRatio * 0.10)),
                        .init(color: .black.opacity(0.18),  location: max(0.00, overlapRatio * 0.30)),
                        .init(color: .black.opacity(0.45),  location: max(0.00, overlapRatio * 0.60)),
                        .init(color: .black.opacity(0.75),  location: max(0.00, overlapRatio * 0.85)),
                        .init(color: .black,               location: overlapRatio),
                        .init(color: .black,               location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .offset(y: overlayTop)
            .allowsHitTesting(false)
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
                    // Measurement copy (in ScrollView coordinate space, no transforms)
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

                    // Visible copy (with transforms for “pin feel”)
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

                // IMPORTANT: don’t apply `.blur(radius: 0)` — it can still trigger offscreen rendering
                // and make SF Symbols look soft at rest. Only blur while we’re actually fading.
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
        // IMPORTANT: GlassEffectContainer can composite the extracted glass layer above sibling content.
        // For crisp icons, keep glass local to each circle background.
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
                        // IMPORTANT: glass only on the background shape.
                        // Keep the symbol as a separate layer above it.
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

    var body: some View {
        ZStack(alignment: .top) {
            chromeBackground
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
        // No explicit divider: the glass fade should blend without a hard line.
    }

    private var chromeBackground: some View {
        let base: AnyView = {
            if reduceTransparency {
                return AnyView(Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.95)))
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
                .opacity(0.70)
            )
            // Extra blur/softness at the very top (stronger “glass” there), fading out downward.
            .overlay(
                Group {
                    if reduceTransparency {
                        EmptyView()
                    } else {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            // In dark mode, avoid a bright highlight belt by slightly darkening.
                            .overlay(colorScheme == .dark ? Color.black.opacity(0.06) : Color.clear)
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
                        // Hold the glass “solid” longer.
                        .init(color: .black,               location: 0.35),
                        // Start the fade later and make it much longer.
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

// MARK: - Helpers

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
