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
                .allowsHitTesting(!isStatsPresented)
            }
            .ignoresSafeArea()

            // Persistent top-right stats button (styled to match the bottom bored button)
            Button(action: { isStatsPresented = true }) {
                Image(systemName: "lines.measurement.horizontal.aligned.bottom", variableValue: 0.4)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white, .white.opacity(0.6))
                    .shadow(color: buttonShadowColor, radius: buttonShadowRadius, x: buttonShadowX, y: buttonShadowY)
            }
            .frame(width: 48, height: 48)
            .buttonStyle(.plain)
            .disabled(isStatsPresented)
            .allowsHitTesting(!isTransitioning && !isStatsPresented)
            .padding(.top, 18)
            .padding(.trailing, 12)

            // Removed persistent bottom-right "I'm bored" button per instructions
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
        .overlay {
            if showInitialLoading {
                loadingView
            } else if encounteredNoValidVideos {
                errorView
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
        .onDisappear {
            stats.stopRealElapsedTimer()
            readyTimer?.invalidate(); readyTimer = nil
            removePreEndObserver()
            boredCountdownTimer?.invalidate(); boredCountdownTimer = nil
            boredAccumulationTimer?.invalidate(); boredAccumulationTimer = nil
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
                        // Scale in from 0 -> 1 after pressing the button
                        .transition(AnyTransition.scale(scale: 0.0, anchor: UnitPoint.trailing).combined(with: .opacity))
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
            currentPlayer?.isMuted = true
            stats.startRealElapsedTimer()
            // Resume timers when app becomes active
            if boredSkipActive && boredSkipTimerRemaining > 0 {
                startBoredCountdown()
            }
            startAccumulation()
        case .inactive:
            break

        case .background:
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
            currentPlayer?.isMuted = true
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
                currentPlayer?.isMuted = true
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
        nextPlayer?.isMuted = true
        if scenePhase == .active {
            nextPlayer?.play()
        }

        // Begin swipe-up transition (both layers move together via the SAME progress value)
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
                currentPlayer?.pause()

                // Promote the incoming player to become current
                currentPlayer = newPlayer
                // Keep the incoming layer identity so the swap doesn't flash.
                currentPlayerViewID = nextPlayerViewID

                // IMPORTANT:
                // During the swap, both layers would otherwise briefly reference the same player/ID
                // (currentPlayer == nextPlayer), which can cause a one-frame "blink".
                // Clear the off-screen layer immediately; we'll restore it right after.
                nextPlayer = nil
                nextPlayerViewID = UUID()

                installPreEndObserverIfNeeded()

                // IMPORTANT: do NOT seek here. B is already playing during the transition.
                currentPlayer?.isMuted = true
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
