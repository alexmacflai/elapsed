
You are an expert iOS engineer. Generate COMPLETE SwiftUI code for an iPhone app. The app is called “Elapsed” (working title). Implement exactly the spec below. Do not add features not listed. Keep UI minimal and dry. Use SwiftUI + AVFoundation only (no 3rd party libs). Persist state across launches using UserDefaults (Codable JSON stored in UserDefaults is fine; or Codable to file if needed). Videos are local bundled mp4 assets.

OUTPUT FORMAT:
- Return the full SwiftUI project code in one response.
- Organize with clear file headers like: // File: ElapsedApp.swift
- Include brief setup comments for adding mp4 files and editing the filename list.

========================================================
APP EXPLANATION (CONTEXT)
Elapsed is a silent video app that plays a continuous shuffled sequence of pointless 9:16 videos. Users cannot control playback or browse. The only interaction is an “I’m bored” button that (1) marks the current video as boring forever, (2) accumulates “bored time” for that video while it plays, and (3) can trigger a 5-second skip countdown (once per playback) that transitions instantly to the next video. The app also shows a Stats bottom drawer with live-updating totals.
========================================================

# VIDEO SYSTEM

## Assets
- Local `.mp4` bundled in app.
- Each video ID = filename string (stable key for persistence).
- Videos are 9:16. Fit full screen; crop if needed.

## Playback order
- Play videos from a shuffled list of filenames.
- Avoid immediate repeats (current != previous).
- When list exhausted: reshuffle with a new random seed and continue.
- On each app launch: shuffle seed is different.

## Playback lifecycle
- On app launch: show optional splash/loading view while preloading the first video.
- When a video starts playing (post-transition, first frame visible): `totalVideoPlays += 1` (counts every playback, even repeats and even if quickly skipped).
- When the video ends: automatically transition to next with a swipe-up animation.
- A video can skip earlier than ending when `boredSkip` triggers (see bored button logic):
  - Skip is instant and uses same swipe-up animation.

## Audio / controls
- No audio (mute playback).
- No user controls or interaction with the video.

## Preloading
- Preload next video to avoid blank frames during transitions.

# UI LAYERS / TRANSITIONS

## Persistent layer (does NOT transition with swipe)
- Stats icon button at top-right in its own container.
- This stays fixed while videos transition.

## Transitioning layer (DOES transition with swipe)
- Video
- Bottom gradient overlay (black low opacity at bottom -> transparent upward)
- Social controls column (right side, bottom aligned) containing only:
  - Bored button container (icon) + counter below

Swipe-up transition animates ONLY the transitioning layer to the next video.

# STATS DRAWER

## Open/close
- Tap stats icon opens bottom drawer.
- Close via swipe down OR tap outside.

## Interaction lock
- While drawer is open: social controls are not interactive.

## Playback + visibility rule
- While drawer is open:
  - If video is “not visible”, then stop playback and pause timers.
  - If visible, video keeps playing and can still transition/skip; stats update live.

## Visibility threshold (hard rule)
- Treat video as “not visible” if drawer covers more than 60% of screen height.
- Implement drawer with a single expanded detent that is >60% of height.
- When drawer is presented at that height: stop playback + pause timers.
- When dismissed: resume.

## Stats cards (in drawer)
Show 3 small cards:
1) Elapsed: `totalElapsedTime` = sum of all `boredomTimeAccumulated` across videos (format dynamically as s / m s / h m)
2) Plays: `totalVideoPlays`
3) Bored acknowledgements: `boredomInstancesTotal` = sum of all per-video `boredomInstance`

Stats update live while timers are running.

# SOCIAL CONTROLS (BORED BUTTON)

## Layout
- Right column, bottom aligned.
- One container: bored icon + counter label below (shows `boredomInstance` for current video).

## Progress border (determinate)
- Container border is a determinate progress indicator.
- Hidden by default.
- When skip countdown active, show border filling 0% -> 100% over 5 seconds.
- After completion: fade border opacity to 0 and reset to hidden.
- Tapping triggers the loader only once per playback.

## Expansion
- On bored button press (if not already expanded):
  - Expand container for 2 seconds, showing:
    - "Bored on this video for: [time]" where time = `boredomTimeAccumulated` for this video (formatted)
  - While expanded: bored button cannot be pressed.
  - After 2 seconds: collapse.
  - Border (if active) continues showing on collapsed state for remaining 3 seconds (timer lasts 5s total).

# DATA MODEL + PERSISTENCE

## Per-video (unique, persisted; keyed by filename)
- `boredomDeclared: Bool = false`
- `boredomInstance: Int = 0`
- `boredomTimeAccumulated: Double = 0` seconds

## Per-playback instance (ephemeral; resets on each new playback start)
- `boredSkipActive: Bool = false`
- `boredSkipTimerRemaining: Double = 5.0`
- `boredSkipTriggeredThisPlay: Bool = false`
- `expandedBoredom: Bool = false` (UI state)

## Global (persisted or derived)
- `totalVideoPlays: Int = 0` (persisted)
- `boredomInstancesTotal: Int = sum(all videos’ boredomInstance)` (derived or cached)
- `totalElapsedTime: Double = sum(all videos’ boredomTimeAccumulated)` (derived; do not store separately unless caching)

Persist everything so boredom flags and counters survive relaunch.

# BEHAVIOR RULES

## On each video start (post-transition)
- Increment `totalVideoPlays` immediately.
- Reset per-playback state:
  - `boredSkipActive = false`
  - `boredSkipTimerRemaining = 5.0`
  - `boredSkipTriggeredThisPlay = false`
  - `expandedBoredom = false`

## On bored button tap (only if not expanded and stats drawer not open)
- For current video (by filename):
  - `boredomInstance += 1`
  - If `boredomDeclared == false`: set to true
- Update totals accordingly (recompute sums is fine).
- Trigger expansion for 2 seconds.
- If `boredSkipTriggeredThisPlay == false`:
  - Set `boredSkipActive = true`
  - Start countdown from 5.0 to 0.0 (do NOT reset on subsequent taps)
  - Show progress border filling over 5 seconds
  - Set `boredSkipTriggeredThisPlay = true`
- If user taps again during same playback after it collapses:
  - Only increments `boredomInstance`
  - Does NOT restart countdown
  - Border opacity may snap back to 1 if it had started fading, but progress must continue from remaining time.

## Countdown completion
- When `boredSkipTimerRemaining` reaches 0:
  - Instantly transition to next video with swipe-up animation (transitioning layer only)

# BOREDOM TIME ACCUMULATION

- `boredomTimeAccumulated` increments only when:
  - current video’s `boredomDeclared == true`
  - that specific video is currently playing
  - app is active/foreground
  - stats drawer is NOT open (since it uses >60% detent and makes video “not visible” by rule)
- Pauses when:
  - video changes
  - app goes inactive (background, lock, notification overlay)
  - stats drawer is open
- Resumes when conditions are met again.
- Accumulates forever across sessions.

# IMPLEMENTATION NOTES (REQUIRED)
- Use an AVPlayer wrapped in SwiftUI (UIViewRepresentable) for full-screen video with no controls.
- Ensure mute is enforced on player.
- Use a single Timer (e.g., 60fps or 10fps) or CADisplayLink-style ticking to:
  - decrement boredSkipTimerRemaining when active
  - increment boredomTimeAccumulated when active
  - update progress border
- Ensure timer stops when app inactive or stats drawer open.
- Implement swipe-up transition as a vertical slide of the transitioning layer. On transition, swap the current video to next and animate.
- Preload next AVPlayerItem (or AVAsset) to reduce hitching.
- Provide a simple filename list constant:
  let videoFilenames = ["video01.mp4","video02.mp4","video03.mp4"]
  (Developer will replace with real names.)
- Provide basic error handling if a filename is missing: skip to next.

Now generate the code / files, but keep things clean, not unecessarily complex, and code readable (comments per main blocks)
