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

    // We keep a reference to the queue which handles shuffle + preloading
    @State private var queue = VideoQueue()

    // Transition timing
    private let transitionDuration: TimeInterval = 1.2 // keep in sync with the .animation duration
    private var transitionLeadTime: TimeInterval { transitionDuration } // start transition this many seconds before A ends

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
                    transitioningLayer(player: currentPlayer, viewID: currentPlayerViewID)
                        .frame(width: W, height: H)
                        .offset(y: -H * p)
                        .opacity(1 - p) // keep your linear opacity rule

                    // Video B: y = +H -> 0
                    transitioningLayer(player: nextPlayer, viewID: nextPlayerViewID)
                        .frame(width: W, height: H)
                        .offset(y: H * (1 - p))
                }
                .frame(width: W, height: H)
                .clipped()
                .allowsHitTesting(!isStatsPresented)
            }
            .ignoresSafeArea()

            // Persistent top-right stats icon (no action yet)
            Button(action: { isStatsPresented = true }) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.25))
                    .clipShape(Capsule())
            }
            .padding(.top, 18)
            .padding(.trailing, 16)

            // Persistent bottom-right "I'm bored" button
            Button(action: { boredButtonTapped() }) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("I’m bored")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.black.opacity(0.35))
                .clipShape(Capsule())
            }
            .padding(.trailing, 16)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .onAppear {
            prepareInitialPlayers()
            installPreEndObserverIfNeeded()
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
        .sheet(isPresented: $isStatsPresented, onDismiss: {
            // Resume playback + timers when drawer closes
            stats.resumeAfterInvisibility()
            currentPlayer?.play()
        }) {
            StatsDrawer()
                .presentationDetents([.fraction(0.7)])
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(20)
                .interactiveDismissDisabled(false)
                .environmentObject(stats)
                .onAppear {
                    // Pause playback + timers when drawer opens
                    stats.pauseForInvisibility()
                    currentPlayer?.pause()
                    stats.flushNow()
                }
        }
        .onDisappear {
            readyTimer?.invalidate(); readyTimer = nil
            removePreEndObserver()
        }
        // Optional debug advance: enable for testing only
        // .contentShape(Rectangle())
        // .onTapGesture { advanceToNextVideo() }
    }

    // MARK: - Transitioning Layer
    @ViewBuilder
    private func transitioningLayer(player: AVPlayer?, viewID: UUID) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // Video fills the screen (aspect fill / crop)
            PlayerView(player: player)
                .id(viewID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom gradient overlay for subtle contrast
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.35), Color.clear]),
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 220)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            // Right-side column placeholder (aligned bottom)
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.0))
                    .frame(width: 48, height: 48)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.0))
                    .frame(width: 48, height: 48)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 28)
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true) // No interactive controls in Split 1
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
        guard scenePhase == .active, !isTransitioning, !isStatsPresented else { return }
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
            if !isStatsPresented {
                currentPlayer?.play()
                currentPlayer?.isMuted = true
            }
            stats.resumeAfterInvisibility()
        case .inactive, .background:
            currentPlayer?.pause()
            stats.pauseForInvisibility()
            stats.flushNow()
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
            if !isStatsPresented && scenePhase == .active {
                currentPlayer?.play()
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
                if !isStatsPresented && scenePhase == .active {
                    currentPlayer?.play()
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
        // Split 1: UI hook. Actual behavior (mark boring, bored time, skip countdown) lives in later splits.
        // For now, do nothing except ensure the control is visible and tappable.
        // (Optional for testing: uncomment to advance)
        // advanceToNextVideo()
    }

    // MARK: - Advance logic with animation
    private func advanceToNextVideo() {
        guard scenePhase == .active, !isTransitioning, !isStatsPresented else { return }

        stats.flushNow()

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
        if !isStatsPresented && scenePhase == .active {
            nextPlayer?.play()
        }

        // Begin swipe-up transition (both layers move together via the SAME progress value)
        isTransitioning = true
        withAnimation(.easeInOut(duration: transitionDuration)) {
            transitionProgress = 1
        }

        // Swap players after the visual motion completes
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) {
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
                // Carry over the incoming layer identity to current, so the old frame can't flash.
                currentPlayerViewID = nextPlayerViewID
                installPreEndObserverIfNeeded()
                // IMPORTANT: do NOT seek here. B is already playing during the transition.
                currentPlayer?.isMuted = true
                if !isStatsPresented && scenePhase == .active { currentPlayer?.play() }

                // Reset instantly for the next cycle (no animation).
                transitionProgress = 0
                isTransitioning = false
            }

            // Now that the transition has ended (next layer is off-screen), refresh the preloaded next.
            nextPlayer = upcomingNext
            nextPlayerViewID = UUID()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(StatsStore())
}
