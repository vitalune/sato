# Sato - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion controls. Uses ctrl+option hotkey to trigger a text-based assist flow: screenshot selection → text question → Claude streaming response in a speech bubble. A Samoyed dog sprite companion lives on screen and flies to the cursor during interactions. The user provides their own Anthropic API key — all API calls go directly to Anthropic (no proxy).

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) direct to Anthropic API with SSE streaming. User provides their own API key stored in Keychain.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Sprite Overlay**: A full-screen transparent `NSPanel` hosts the animated dog sprite companion. It's non-activating, joins all Spaces, and never steals focus. The sprite rests at the bottom center of the screen and flies to the cursor on hotkey press. `SpriteAnimationManager` preloads GIF frames from the active sprite directory (max-animations/, sky-animations/, lexi-animations/, rover-animations/, or paris-animations/) at launch, runs a 60fps timer for position interpolation and ~8-10 FPS frame stepping, and manages the state machine (resting → flying → assisting → pointing → flying back). Speech bubbles and pointing animations render in this overlay via SwiftUI through `NSHostingView`.

**Global Hotkey**: Background Ctrl+Option detection uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts are detected reliably system-wide.

**Transient Cursor Mode**: When stealth mode is on, pressing the hotkey fades in the cursor overlay for the duration of the interaction (screenshot → question → response → optional pointing), then fades it out automatically after 1 second of inactivity.

**Context Profiles**: Users create named context profiles via the config panel that customize Sato's behavior. Each profile contains plain-English instructions injected into the Claude system prompt. Profiles are stored as JSON in `~/Library/Application Support/Sato/profiles.json` and persist across app restarts. Only one profile can be active at a time. Managed by `ContextManager.swift`.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1280 | Central state machine. Owns shortcut monitoring, screen capture, Claude API, overlay management, sprite animation manager, context manager, and chat sidebar state. Tracks conversation history (configurable 5-50, default 30), model selection, and cursor visibility. Coordinates hotkey → screenshot selection → text question → Claude streaming → speech bubble pipeline, plus chat sidebar follow-up conversations. Injects active context profile into system prompts. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1170 | SwiftUI panel content for the menu bar dropdown. Shows companion status, model picker (Sonnet/Opus), sprite picker, API key input, context profiles UI, conversation history controls, "Always Open Chat" toggle, permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `ContextManager.swift` | ~180 | Manages persistent Context Profiles for customizing Sato's behavior. Stores profiles as JSON in `~/Library/Application Support/Sato/profiles.json`. Provides CRUD operations, active profile switching, and starter profile creation on first launch. |
| `OverlayWindow.swift` | ~930 | Full-screen transparent overlay hosting the sprite, speech bubbles, and chat sidebar. Contains OverlayWindowManager which manages per-screen overlays, interactive overlays for screenshot/text input, and the chat sidebar window with slide-in/out animation. Handles element-pointing, multi-monitor coordinate mapping, and assist flow phase transitions. |
| `ChatSidebarView.swift` | ~270 | Slide-in chat sidebar for reading full responses and sending follow-up messages. Anchored to right screen edge with blur background. Shows conversation with screenshot thumbnail, user/assistant message bubbles with timestamps, and auto-focused text input for follow-ups. |
| `SpeechBubbleView.swift` | ~130 | Speech bubble displaying Claude's response above the sprite. Shows active context profile name as header. Detects content overflow and shows a "Show more" button that opens the chat sidebar. |
| `SpriteDirection.swift` | ~100 | Eight compass directions for the sprite. Maps angles to directions and resolves which GIF asset to load (with horizontal mirroring for missing directions). |
| `SpriteAnimationManager.swift` | ~430 | Manages the sprite state machine (resting/flying/assisting/pointing), GIF frame extraction via `CGImageSource`, 60fps animation timer for frame stepping and position interpolation, direction-based animation selection, and multi-sprite support (Max, Sky, Lexi, Rover, Paris). |
| `SamoyedSpriteView.swift` | ~25 | Minimal SwiftUI view that renders the current sprite frame from `SpriteAnimationManager` at 136x136pt with nearest-neighbor interpolation. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~160 | System-wide Ctrl+Option hotkey monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions for the assist flow. |
| `ClaudeAPI.swift` | ~130 | Claude vision API client. Static method for direct Anthropic API streaming with SSE, image MIME detection, conversation history support. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~870 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~90 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `KeychainHelper.swift` | ~50 | Saves/loads the user's Anthropic API key in the macOS Keychain. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
