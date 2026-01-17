// File: ContentView.swift
// Elapsed
//
// Main screen that orchestrates playback, swipe-up transition, and overlays.
// Persistent UI: top-right stats icon (opens drawer).
// Transitioning layer: video, bottom gradient overlay, right-side placeholder column.
//
// Notes for assets: Add your .mp4 files to the app target, then update `videoFilenames`
// in VideoQueue.swift.

import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    // Observe app lifecycle to pause/resume playback
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var stats: StatsStore

    // Player state: two players for cross-prepared transitions
    @State private var currentPlayer: AVPlayer? = nil
    @State private var nextPlayer: AVPlayer? = nil
    @State private var currentPlayerViewID: UUID = UUID()
    @State private var nextPlayerViewID: UUID = UUID()
    // One progress value drives BOTH layers. 0 = idle (A on-screen, B fully below), 1 = complete.
    @State private var transitionProgress: CGFloat = 0
    @State private var isTransitioning: Bool = false
    @State private var showInitialLoading: Bool = true

    @State private var isStatsPresented: Bool = false
    @State private var isInfoPresented: Bool = false

    @State private var encounteredNoValidVideos: Bool = false
    @State private var readyTimer: Timer? = nil
    @State private var readyCheckDeadline: Date? = nil

    @State private var didStartInitialPlaybackStats: Bool = false

    // We keep a reference to the queue which handles shuffle + preloading
    @State private var queue = VideoQueue()

    // Split 2: Boredom persistence and ephemeral playback state
    @StateObject private var boredomStore = BoredomStore()

    // Ephemeral per-playback state
    @State private var boredSkipActive: Bool = false
    @State private var boredSkipTimerRemaining: Double = 5.0
    @State private var boredSkipTriggeredThisPlay: Bool = false
    @State private var expandedBoredom: Bool = false
    @State private var borderOpacity: Double = 0.0

    // Shared button shadow (top stats + bottom bored)
    private let buttonShadowColor: Color = .black.opacity(1)
    private let buttonShadowRadius: CGFloat = 4
    private let buttonShadowX: CGFloat = 0
    private let buttonShadowY: CGFloat = 2

    // Timers
    @State private var boredCountdownTimer: Timer? = nil
    @State private var boredAccumulationTimer: Timer? = nil
    @State private var lastAccumulationTick: Date? = nil

    // Audio crossfade state
    @State private var volumeFadeTimer: Timer? = nil
    @State private var volumeFadeStart: Date? = nil
    @State private var volumeFadeDuration: TimeInterval = 0

    // User mute toggle state
    @State private var userMuted: Bool = false
    // Mute HUD: hidden by default; appears on double-tap, then disappears after 1s.
    @State private var muteHUDVisible: Bool = false
    @State private var muteHUDShouldDisappear: Bool = false
    @State private var muteHUDDrawOnActive: Bool = true
    @State private var muteHUDDisappearWorkItem: DispatchWorkItem? = nil
    @State private var muteHUDHideWorkItem: DispatchWorkItem? = nil

    private var muteHUDSymbol: String {
        userMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    // MARK: - Animation tuning
    // 1) Transition duration between videos
    private let videoTransitionDuration: TimeInterval = 1 // keep in sync with the .animation duration

    // 2) Transition duration when zzz icon changes to progress indicator
    //    (This is the animation SwiftUI uses when `isExpandedForThisLayer` toggles.)
    private let boredSymbolSwapDuration: TimeInterval = 0.24

    // 3) Transition duration when pressing the zzz button and the label grows
    // Spring used for the left label scale transition (make it obviously bouncy for QA)
    private let boredLabelSpring: Animation = .interpolatingSpring(stiffness: 200, damping: 20)

    // Used for the swipe-up trigger window before the video ends.
    private var transitionLeadTime: TimeInterval { videoTransitionDuration }

    // Periodic observer so we can trigger the transition BEFORE the final frozen frame
    @State private var timeObserverToken: Any? = nil
    @State private var timeObserverOwner: AVPlayer? = nil

    // MARK: - Body
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Background color
            Color.black.ignoresSafeArea()

            // Transitioning stack: two layers that slide up on change
            GeometryReader { proxy in
                // ONE canonical "phone" size from the same coordinate space we draw/clamp in.
                let W = proxy.size.width
                let H = proxy.size.height
                let p = max(0, min(1, transitionProgress))

                ZStack(alignment: .top) {
                    // Video A: y = 0 -> -H
                    transitioningLayer(player: currentPlayer, viewID: currentPlayerViewID, isCurrent: true)
                        .frame(width: W, height: H)
                        .offset(y: -H * p)
                        .opacity(1 - p) // keep your linear opacity rule

                    // Video B: y = +H -> 0
                    transitioningLayer(player: nextPlayer, viewID: nextPlayerViewID, isCurrent: false)
                        .frame(width: W, height: H)
                        .offset(y: H * (1 - p))
                }
                .frame(width: W, height: H)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { handleDoubleTap() }
                .allowsHitTesting(!isStatsPresented && !isInfoPresented)
            }
            .ignoresSafeArea()

            // Persistent top-right buttons (styled to match the bottom bored button)
            VStack(spacing: 0) {
                // Stats (chart) button
                Button(action: { isStatsPresented = true }) {
                    Image(systemName: "lines.measurement.horizontal.aligned.bottom", variableValue: 0.4)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.white, .white.opacity(0.6))
                        .shadow(color: buttonShadowColor, radius: buttonShadowRadius, x: buttonShadowX, y: buttonShadowY)
                }
                .frame(width: 48, height: 48)
                .buttonStyle(.plain)
                .disabled(isStatsPresented || isInfoPresented)
                .allowsHitTesting(!isTransitioning && !isStatsPresented && !isInfoPresented)

                // Info button (same style)
                Button(action: { isInfoPresented = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.white, .white.opacity(0.6))
                        .shadow(color: buttonShadowColor, radius: buttonShadowRadius, x: buttonShadowX, y: buttonShadowY)
                }
                .frame(width: 48, height: 48)
                .buttonStyle(.plain)
                .disabled(isStatsPresented || isInfoPresented)
                .allowsHitTesting(!isTransitioning && !isStatsPresented && !isInfoPresented)
            }
            .padding(.top, 18)
            .padding(.trailing, 12)

            // Removed persistent bottom-right "I'm bored" button per instructions
        }
        .overlay {
            if showInitialLoading {
                loadingView
            } else if encounteredNoValidVideos {
                errorView
            }
        }
        .overlay(alignment: .center) {
            if muteHUDVisible {
                Image(systemName: muteHUDSymbol)
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.white)
                    .opacity(0.6)
                    .shadow(color: .black.opacity(1), radius: 16, x: 0, y: 2)
                    // SF Symbols-only: drawOn effect on each double tap.
                    .symbolEffect(.drawOn.byLayer, options: .speed(1), isActive: muteHUDDrawOnActive)
                    // SF Symbols-only: disappear 1s after each double tap.
                    .symbolEffect(.disappear, options: .speed(0.5), isActive: muteHUDShouldDisappear)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isStatsPresented) {
            NavigationStack {
                StatsDrawer()
                    .navigationTitle("Stats")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isStatsPresented = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationCornerRadius(28)
            .preferredColorScheme(.dark)
            .environmentObject(stats)
        }
        .sheet(isPresented: $isInfoPresented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("About Elapsed")
                            .font(.title2).bold()

                        Text("A calm, continuous loop of your videos. Elapsed helps you unwind, focus, or simply enjoy motion.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("What is Elapsed?")
                                .font(.headline)
                            Text("Elapsed plays your videos back-to-back with gentle transitions. It tracks how often you skip and how long you feel bored so you can discover what truly keeps you engaged.")

                            Text("How it works")
                                .font(.headline)
                            Text("• Shuffles and preloads your videos for smooth playback.\n• Transitions early to avoid frozen frames.\n• Lets you mark boredom and auto-skip after a short countdown.\n• Summarizes your viewing stats in the drawer.")

                            Text("Privacy")
                                .font(.headline)
                            Text("All data stays on your device. We never upload your media or stats anywhere.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .navigationTitle("About Elapsed")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isInfoPresented = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationCornerRadius(28)
            .preferredColorScheme(.dark)
        }
        .onAppear {
            prepareInitialPlayers()
            installPreEndObserverIfNeeded()
            if scenePhase == .active {
                stats.startRealElapsedTimer()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: RunLoop.main)) { notif in
            // Only advance when the CURRENT player's item ends.
            guard let endedItem = notif.object as? AVPlayerItem else { return }
            guard endedItem == currentPlayer?.currentItem else { return }
            advanceToNextVideo()
        }
        .onDisappear {
            stats.stopRealElapsedTimer()
            readyTimer?.invalidate(); readyTimer = nil
            removePreEndObserver()
            boredCountdownTimer?.invalidate(); boredCountdownTimer = nil
            boredAccumulationTimer?.invalidate(); boredAccumulationTimer = nil
            volumeFadeTimer?.invalidate(); volumeFadeTimer = nil
        }
        // Optional debug advance: enable for testing only
        // .contentShape(Rectangle())
        // .onTapGesture { advanceToNextVideo() }
    }

    // MARK: - Transitioning Layer
    @ViewBuilder
    private func transitioningLayer(player: AVPlayer?, viewID: UUID, isCurrent: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // Video fills the screen (aspect fill / crop)
            PlayerView(player: player)
                .id(viewID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Top gradient overlay for subtle contrast (mirrors bottom)
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.4), Color.clear]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Bottom gradient overlay for subtle contrast
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.4), Color.clear]),
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // Right-side bored control (aligned bottom)
            let filename = currentFilename(for: player)
            let instanceCount = (filename != nil) ? boredomStore.instanceCount(for: filename!) : 0
            let timeAccum = (filename != nil) ? boredomStore.getBoredomTime(for: filename!) : 0
            let countdownProgress = max(0.0, min(1.0, (5.0 - boredSkipTimerRemaining) / 5.0))
            let isExpandedForThisLayer = isCurrent && expandedBoredom

            HStack(spacing: 0) {
                // LEFT: label container (hug-sized, not part of the button)
                if isExpandedForThisLayer {
                    Group {
                        HStack(spacing: 6) {
                            Text("Bored on this video for:")
                            Text("\(formatBoredTime(timeAccum))")
                        }
                        .font(.footnote)
                        // Auto-contrast against light/dark glass by inverting the pixels behind.
                        .foregroundStyle(.white)
                        .compositingGroup()
                        .blendMode(.difference)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Native Liquid Glass
                        .modifier(LiquidGlassIfAvailable(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                        // Removed .transition(.opacity)
                        .animation(boredLabelSpring, value: isExpandedForThisLayer)
                    }
                }

                // RIGHT: main button (fixed size, transparent background)
                Button(action: { if isCurrent { boredButtonTapped() } }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Image(systemName: "zzz")
                                    .opacity(isExpandedForThisLayer ? 0 : 1)
                                    .scaleEffect(isExpandedForThisLayer ? 0.9 : 1)

                                Image(systemName: "progress.indicator", variableValue: countdownProgress)
                                    .opacity(isExpandedForThisLayer ? 1 : 0)
                                    .scaleEffect(isExpandedForThisLayer ? 1 : 1.1)
                            }
                            .animation(.easeInOut(duration: boredSymbolSwapDuration), value: isExpandedForThisLayer)
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.white, .white.opacity(0.20))
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.easeInOut(duration: boredSymbolSwapDuration), value: isExpandedForThisLayer)

                            Text("\(instanceCount)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: buttonShadowColor, radius: buttonShadowRadius, x: buttonShadowX, y: buttonShadowY)
                    }
                    .frame(width: 48, height: 48)
                    .fixedSize()

                .buttonStyle(.plain)
                .disabled(!(isCurrent && !isTransitioning && !isStatsPresented))
                .allowsHitTesting(isCurrent && !isTransitioning && !isStatsPresented)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 96)
            .zIndex(5)
        }
    }

    // MARK: - Loading View
    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("Preparing…")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Error View (no videos)
    private var errorView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 28))
                Text("No playable videos found.")
                    .foregroundStyle(.white.opacity(0.9))
                Text("Add .mp4 files and update videoFilenames in VideoQueue.swift")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding()
        }
    }

    // MARK: - Audio Crossfade Helpers
    private func startCrossfade(from old: AVPlayer?, to new: AVPlayer?, duration: TimeInterval) {
        volumeFadeTimer?.invalidate(); volumeFadeTimer = nil
        volumeFadeStart = Date()
        volumeFadeDuration = max(0.01, duration)

        // Initialize volumes
        old?.isMuted = userMuted
        new?.isMuted = userMuted
        old?.volume = 1.0
        new?.volume = 0.0

        volumeFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            tickCrossfade(old: old, new: new)
        }
        if let timer = volumeFadeTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tickCrossfade(old: AVPlayer?, new: AVPlayer?) {
        guard let start = volumeFadeStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        let t = min(1.0, max(0.0, elapsed / volumeFadeDuration))
        let outVol = Float(1.0 - t)
        let inVol = Float(t)
        old?.volume = outVol
        new?.volume = inVol

        if t >= 1.0 {
            volumeFadeTimer?.invalidate(); volumeFadeTimer = nil
            volumeFadeStart = nil
            old?.volume = 0.0
            new?.volume = 1.0
        }
    }

    // MARK: - Mute Toggle Handling
    private func applyMuteState() {
        currentPlayer?.isMuted = userMuted
        nextPlayer?.isMuted = userMuted
    }

    private func handleDoubleTap() {
        userMuted.toggle()
        applyMuteState()

        // Show HUD immediately.
        muteHUDVisible = true
        muteHUDShouldDisappear = false

        // Ensure the symbol starts in the "undrawn" state WITHOUT animating.
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            muteHUDDrawOnActive = true
        }

        // Animate to the drawn state after the HUD is in the view tree.
        DispatchQueue.main.async {
            muteHUDDrawOnActive = false
        }

        // Cancel any pending scheduled effects from previous taps.
        muteHUDDisappearWorkItem?.cancel()
        muteHUDHideWorkItem?.cancel()

        // 1s after tap: play the SF Symbols disappear effect.
        let disappearItem = DispatchWorkItem {
            muteHUDShouldDisappear = true

            // After the disappear effect has time to play, remove the icon entirely.
            let hideItem = DispatchWorkItem {
                muteHUDVisible = false
                muteHUDShouldDisappear = false

                // Reset to "undrawn" without animating.
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    muteHUDDrawOnActive = true
                }
            }
            muteHUDHideWorkItem = hideItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: hideItem)
        }
        muteHUDDisappearWorkItem = disappearItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: disappearItem)
    }

    // MARK: - Startup readiness check
    private func startReadyCheckTimer() {
        readyTimer?.invalidate()
        readyCheckDeadline = Date().addingTimeInterval(2.0) // fallback cutoff
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            if isPlayerReadyToDisplay() || (readyCheckDeadline?.timeIntervalSinceNow ?? 0) <= 0 {
                showInitialLoading = false
                readyTimer?.invalidate()
                readyTimer = nil
            }
        }
    }

    private func isPlayerReadyToDisplay() -> Bool {
        guard let item = currentPlayer?.currentItem else { return false }
        switch item.status {
        case .readyToPlay:
            return true
        case .failed, .unknown:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Pre-end transition trigger (avoid frozen last frame)
    private func installPreEndObserverIfNeeded() {
        removePreEndObserver()
        guard let player = currentPlayer else { return }
        timeObserverOwner = player

        // Check 10x/sec. Cheap and good enough.
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            maybeStartTransitionBeforeEnd()
        }
    }

    private func removePreEndObserver() {
        guard let token = timeObserverToken else {
            timeObserverOwner = nil
            return
        }

        // IMPORTANT: remove from the same player instance that installed it.
        if let owner = timeObserverOwner {
            owner.removeTimeObserver(token)
        }

        timeObserverToken = nil
        timeObserverOwner = nil
    }

    private func maybeStartTransitionBeforeEnd() {
        guard scenePhase == .active, !isTransitioning else { return }
        guard let item = currentPlayer?.currentItem else { return }

        let dur = item.duration
        guard dur.isNumeric, dur.seconds.isFinite, dur.seconds > 0 else { return }

        let now = item.currentTime().seconds
        let remaining = dur.seconds - now

        // Start the transition a bit before the end.
        if remaining <= transitionLeadTime {
            advanceToNextVideo()
        }
    }

    // MARK: - Lifecycle handlers
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            currentPlayer?.play()
            applyMuteState()
            stats.startRealElapsedTimer()
            // Resume timers when app becomes active
            if boredSkipActive && boredSkipTimerRemaining > 0 {
                startBoredCountdown()
            }
            startAccumulation()
        case .inactive:
            break

        case .background:
            volumeFadeTimer?.invalidate(); volumeFadeTimer = nil
            currentPlayer?.pause()
            stats.flushNow()
            stats.stopRealElapsedTimer()
            // Pause timers only when the app actually goes to background.
            boredCountdownTimer?.invalidate(); boredCountdownTimer = nil
            stopAccumulation()
        @unknown default:
            break
        }
    }

    // MARK: - Initial prep
    private func prepareInitialPlayers() {
        encounteredNoValidVideos = false
        showInitialLoading = true

        // Build initial shuffled queue and get the first two items
        queue.resetAndReshuffle()

        // Prepare current player
        if let first = queue.dequeuePreparedPlayer() {
            currentPlayer = first
            currentPlayerViewID = UUID()
            installPreEndObserverIfNeeded()
            currentPlayer?.isMuted = userMuted
            currentPlayer?.volume = 1.0
            if scenePhase == .active {
                currentPlayer?.play()

                // Always start stats/timers for the very first playback (even if AVPlayer is still buffering).
                if !didStartInitialPlaybackStats {
                    didStartInitialPlaybackStats = true
                    newPlaybackStarted()
                }
            }
            // Start readiness check to avoid black flash
            startReadyCheckTimer()
        } else {
            // Try a reshuffle once more
            queue.resetAndReshuffle()
            if let fallback = queue.dequeuePreparedPlayer() {
                currentPlayer = fallback
                currentPlayerViewID = UUID()
                installPreEndObserverIfNeeded()
                currentPlayer?.isMuted = userMuted
                currentPlayer?.volume = 1.0
                if scenePhase == .active {
                    currentPlayer?.play()

                    // Always start stats/timers for the very first playback (even if AVPlayer is still buffering).
                    if !didStartInitialPlaybackStats {
                        didStartInitialPlaybackStats = true
                        newPlaybackStarted()
                    }
                }
                startReadyCheckTimer()
            } else {
                // No valid videos available
                encounteredNoValidVideos = true
                showInitialLoading = false
            }
        }

        // Preload next
        nextPlayer = queue.peekPreparedNextPlayer()
        nextPlayer?.volume = 0.0
        nextPlayer?.isMuted = userMuted
        nextPlayerViewID = UUID()
    }

    // MARK: - I’m bored button
    private func boredButtonTapped() {
        guard scenePhase == .active else { return }
        guard !expandedBoredom else { return }
        guard let filename = currentFilename(for: currentPlayer) else { return }

        // Persist boredom instance and declaration
        boredomStore.incrementInstance(for: filename)
        stats.addBoredomInstance(for: filename)
        boredomStore.declareBoredomIfNeeded(for: filename)

        // Expand UI
        withAnimation(boredLabelSpring) {
            expandedBoredom = true
        }

        // Start skip countdown once per playback
        if !boredSkipTriggeredThisPlay {
            boredSkipTriggeredThisPlay = true
            boredSkipActive = true

            // Start AFTER the expand animation finishes.
            // Starting the timer while the view is transitioning can cause the variable symbol
            // to render at its default (full) and then never visually update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Only start if we're still in the expanded state for the current layer.
                guard expandedBoredom, boredSkipActive else { return }
                startBoredCountdown(resetToFull: true)
            }
        }
    }

    // MARK: - Advance logic with animation
    private func advanceToNextVideo(force: Bool = false) {
        guard scenePhase == .active, !isTransitioning else { return }

        // Prefer the preloaded next if available
        let hadPreloaded = (nextPlayer != nil)
        var incoming: AVPlayer? = nextPlayer

        if incoming == nil {
            // No preloaded player? Dequeue one now.
            incoming = queue.dequeuePreparedPlayer()
        } else {
            // Consume the prepared one in the queue since we're about to use it.
            _ = queue.dequeuePreparedPlayer()
        }

        if incoming == nil {
            // Still nothing: reshuffle and try once more.
            queue.resetAndReshuffle()
            incoming = queue.dequeuePreparedPlayer()
        }

        guard let newPlayer = incoming else { return }

        // If we didn't have a preloaded next, assign it now so the animation has content to slide in.
        if !hadPreloaded {
            nextPlayer = newPlayer
            nextPlayerViewID = UUID()
        }

        // Prepare one more ahead for smoothness
        queue.prepareNextIfNeeded()

        // Start B immediately so it has frames ready while A slides away.
        // If B was already preloaded/playing, DO NOT seek (seeking can delay the first frame).
        if !hadPreloaded {
            nextPlayer?.seek(to: .zero)
        }
        nextPlayer?.isMuted = userMuted
        nextPlayer?.volume = 0.0
        if scenePhase == .active {
            nextPlayer?.play()
        }
        // Ensure current is audible before crossfade
        currentPlayer?.isMuted = userMuted
        currentPlayer?.volume = 1.0

        // Begin swipe-up transition (both layers move together via the SAME progress value)
        startCrossfade(from: currentPlayer, to: nextPlayer, duration: videoTransitionDuration)
        isTransitioning = true
        withAnimation(.easeInOut(duration: videoTransitionDuration)) {
            transitionProgress = 1
        }

        // Swap players after the visual motion completes
        DispatchQueue.main.asyncAfter(deadline: .now() + videoTransitionDuration) {
            // Capture the next preloaded player, but DO NOT assign it to `nextPlayer` yet.
            // While `isAnimatingTransition == true`, `nextPlayer` is the visible incoming layer.
            let upcomingNext = queue.peekPreparedNextPlayer()

            // Do the player swap without any implicit SwiftUI animations.
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                // Pause old player to avoid background playback
                currentPlayer?.volume = 0.0
                currentPlayer?.pause()

                // Promote the incoming player to become current
                currentPlayer = newPlayer
                // Keep the incoming layer identity so the swap doesn't flash.
                currentPlayerViewID = nextPlayerViewID

                installPreEndObserverIfNeeded()

                // IMPORTANT: do NOT seek here. B is already playing during the transition.
                currentPlayer?.isMuted = userMuted
                currentPlayer?.volume = 1.0
                if scenePhase == .active {
                    currentPlayer?.play()
                    newPlaybackStarted()
                }

                // Reset instantly for the next cycle (no animation).
                transitionProgress = 0
                isTransitioning = false
            }

            // Now that the transition has ended (next layer is off-screen), refresh the preloaded next.
            nextPlayer = upcomingNext
            nextPlayerViewID = UUID()
        }
    }

    // MARK: - Split 2 Helpers
    private func currentFilename(for player: AVPlayer?) -> String? {
        guard let item = player?.currentItem else { return nil }
        if let urlAsset = item.asset as? AVURLAsset { return urlAsset.url.lastPathComponent }
        return nil
    }

    private func formatBoredTime(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds) / 60
        let remSec = Int(seconds) % 60
        if minutes < 60 { return "\(minutes)m \(remSec)s" }
        let hours = minutes / 60
        let remMin = minutes % 60
        return "\(hours)h \(remMin)m"
    }

    private func resetEphemeralForNewPlayback() {
        boredSkipActive = false
        boredSkipTimerRemaining = 5.0
        boredSkipTriggeredThisPlay = false
        expandedBoredom = false
        borderOpacity = 0.0
    }

    private func newPlaybackStarted() {
        boredomStore.incrementTotalVideoPlays()
        stats.incrementPlays()
        resetEphemeralForNewPlayback()
        // Always accumulate elapsed time for stats; boredom time is still gated inside tickAccumulation().
        startAccumulation()
    }

    private func newPlaybackStartedIfPossible() {
        guard !didStartInitialPlaybackStats else { return }
        if currentPlayer?.timeControlStatus == .playing {
            didStartInitialPlaybackStats = true
            newPlaybackStarted()
        }
    }

    // MARK: Countdown handling
    private func startBoredCountdown(resetToFull: Bool = false) {
        boredCountdownTimer?.invalidate()
        if resetToFull {
            boredSkipTimerRemaining = 5.0
        } else {
            boredSkipTimerRemaining = max(0, boredSkipTimerRemaining)
        }
        borderOpacity = 1.0
        boredCountdownTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            tickCountdown()
        }
        RunLoop.main.add(boredCountdownTimer!, forMode: .common)
    }

    private func tickCountdown() {
        guard scenePhase == .active, boredSkipActive else { return }
        withAnimation(.linear(duration: 0.05)) {
            boredSkipTimerRemaining = max(0, boredSkipTimerRemaining - 0.05)
        }
        if boredSkipTimerRemaining <= 0 {
            boredSkipTimerRemaining = 0

            // Collapse the label (scale back to 0) as the transition starts.
            withAnimation(boredLabelSpring) {
                expandedBoredom = false
            }

            withAnimation(.easeOut(duration: 0.35)) { borderOpacity = 0.0 }
            boredCountdownTimer?.invalidate(); boredCountdownTimer = nil

            // Trigger transition to next video
            advanceToNextVideo(force: true)
        } else {
            borderOpacity = 1.0
        }
    }

    // MARK: Accumulation handling
    private func startAccumulation() {
        lastAccumulationTick = Date()
        boredAccumulationTimer?.invalidate()
        boredAccumulationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            tickAccumulation()
        }
        RunLoop.main.add(boredAccumulationTimer!, forMode: .common)
    }

    private func stopAccumulation() {
        boredAccumulationTimer?.invalidate(); boredAccumulationTimer = nil
        lastAccumulationTick = nil
    }

    private func tickAccumulation() {
        guard scenePhase == .active else { return }
        guard let filename = currentFilename(for: currentPlayer) else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastAccumulationTick ?? now)
        lastAccumulationTick = now
        if delta > 0 {
            // Only accumulate once this video has been marked as boring.
            guard boredomStore.isDeclared(for: filename) else { return }

            boredomStore.accumulateTime(for: filename, delta: delta)
            stats.addBoredomTime(for: filename, delta: delta)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(StatsStore())
}

// MARK: - LiquidGlassIfAvailable Modifier
private struct LiquidGlassIfAvailable<S: Shape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            // No glass available on older iOS targets.
            content
        }
    }
}

