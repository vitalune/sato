# Sato - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon or conventional main window). Ctrl+Option captures a selected screen region, then the user can type a question or dictate one with Sato Local before sending it to the selected AI provider. Sato Local uses WhisperKit entirely on-device and inserts an editable transcript into the current composer. A blue cursor overlay can fly to and point at UI elements the assistant references on any connected monitor. Users can choose a bundled companion or discover community sprites through Petdex, and Auto Sleep suspends the visual runtime after prolonged inactivity.

Remote-provider API keys are stored in the user's macOS Keychain. Sato calls the selected provider directly; Ollama Local remains entirely on the user's Mac.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Direct streaming integrations for Anthropic, OpenAI, Ollama Local, and Ollama Cloud through a shared provider abstraction
- **Speech-to-Text**: Sato Local via WhisperKit. Users choose Fast (Whisper large-v3-turbo) or Accurate (Whisper large-v3); converted Core ML models download on demand and remain under `~/Library/Application Support/Sato/SpeechModels/`
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Click-to-record microphone controls in the initial screenshot composer and follow-up chat composer, with Cmd+Shift+M as the composer-scoped start/stop shortcut. Audio remains in memory, is transcribed locally, is never uploaded, and is inserted as editable text rather than sent automatically.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### AI Providers

`ProviderManager` selects a common `AIProvider` implementation for Anthropic, OpenAI, Ollama Local, or Ollama Cloud. Remote-provider credentials remain in the macOS Keychain and are attached only to direct requests to that provider. Ollama Local discovers models through the user's local daemon. Petdex browsing and user-selected sprite downloads call Petdex's public, credential-free API and asset host directly.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Sprite Overlay**: A full-screen transparent `NSPanel` hosts the animated pixel-art companion. It's non-activating, joins all Spaces, and never steals focus. The sprite rests at the bottom center of the screen and flies to the cursor on hotkey press. `SpriteAnimationManager` loads the selected bundled GIF set or one cached Petdex atlas, uses an adaptive ~10/30/60 Hz cadence for stationary animation, patrol, and short high-motion states, and manages the state machine (resting → flying → assisting → pointing → flying back). Cursor tracking runs only while cursor-attached UI is visible rather than once per display continuously. The waveform, spinner, speech bubbles, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Petdex Custom Sprites**: The compact companion panel keeps the five bundled sprites immediately available and opens a dedicated picker for Petdex. `PetdexSpriteCatalog` searches the public catalog with query, type, mood, and sort filters. The grid lazy-loads static idle previews rather than animating every result. Selecting a pet validates and caches its atlas and metadata under `~/Library/Application Support/Sato/CustomSprites/<slug>/`, removing older custom-sprite caches; `SpriteAnimationManager` decodes the active atlas into the existing animation state machine. Petdex assets are downloaded at runtime and retain creator attribution and a per-pet source link in the picker.

**Auto Sleep**: Auto Sleep is enabled by default and has three visual power levels. Active interactions use adaptive animation cadence. After 60 seconds without a meaningful Sato interaction, an otherwise-idle companion dozes in its stationary south-facing animation at ~10 FPS with patrol and cursor tracking stopped. After 15 minutes of combined-session input inactivity, and only when no assist, chat, recording, onboarding, capture, or menu-panel work is active, Sato fully removes its overlays and stops animation, permission polling, and its idle timers. Mouse, keyboard, scroll, hotkey, and menu-panel activity wake full sleep; only meaningful Sato activity exits dozing. System sleep, screen sleep, and inactive-session notifications immediately apply a non-destructive lifecycle pause that orders visual windows out, preserves in-progress UI state, and resumes only after the last stacked lifecycle reason clears. Permission polling runs only while the visible setup panel is waiting for a grant.

**Global Screenshot Shortcut**: Ctrl+Option uses a listen-only `CGEvent` tap instead of an AppKit global monitor so the screenshot-selection shortcut is detected reliably while Sato runs in the background. Voice input remains scoped to the visible composer and can be started or stopped with its microphone button or Cmd+Shift+M.

**Sato Local Speech**: `LocalSpeechTranscriptionManager` owns WhisperKit model lifecycle, on-demand download progress, microphone permission, in-memory recording, and transcription. After a model downloads, its Core ML preparation continues independently in the background through visible verification, optimization, and loading stages. Preparation supports cancellation, retry, elapsed-time feedback, and a ten-minute timeout; successful device optimization is remembered so later launches skip the expensive first pass. Fast and Accurate have separate download roots so either model can be removed without affecting the other. Context Profile text is used only as a local Whisper prompt to improve domain vocabulary.

**Transient Cursor Mode**: When stealth mode is on, pressing the hotkey fades in the cursor overlay for the duration of the screenshot question and response flow, then fades it out automatically after 1 second of inactivity.

**Context Profiles**: Users create named context profiles via the config panel that customize Sato's behavior. Each profile contains plain-English instructions injected into the Claude system prompt. Profiles are stored as JSON in `~/Library/Application Support/Sato/profiles.json` and persist across app restarts. Only one profile can be active at a time. Managed by `ContextManager.swift`.

**Conversation History**: Each initial screenshot question creates a separate persisted thread. `ConversationStore` keeps JSON message metadata and separate JPEG screenshot files under `~/Library/Application Support/Sato/`, retaining the five most recent unpinned conversations plus all pinned conversations. While a conversation is open in the sidebar, Ctrl+Option captures another screenshot for the next follow-up turn (shown in chat and sent with that reply). The chat window can detach into a movable, resizable compact panel and dock to either display edge.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~2850 | Central state machine. Owns shortcut monitoring, screen capture, provider routing, overlay management, sprite selection, doze/Auto Sleep lifecycle, context profiles, conversation persistence, and active chat state. Coordinates screenshot questions, streaming responses, and persisted follow-up threads. While the sidebar is open, Ctrl+Option attaches a new screenshot to the next follow-up turn. |
| `MenuBarPanelManager.swift` | ~465 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the compact companion panel and custom sprite picker, installs click-outside-to-dismiss monitors, and reports panel visibility for Auto Sleep. |
| `CompanionPanelView.swift` | ~1940 | SwiftUI panel content for the menu bar dropdown, including provider/model settings, bundled and Petdex sprite controls, Auto Sleep, context profiles, previous conversations with pin controls, permissions, feedback, updates, and quit controls. |
| `CustomSpritePickerView.swift` | ~625 | Dedicated Petdex picker with debounced search, progressive type/mood/sort filters, lazy static previews, creator attribution, pagination, loading/error/empty states, and active-sprite selection. |
| `PetdexSpriteCatalog.swift` | ~1030 | Petdex search client, response models, trusted-host and redirect validation, hard-capped temporary-file asset downloads, atlas geometry validation, preview loading, and atomic metadata/spritesheet cache under Application Support. |
| `PetdexSpriteCatalogTests.swift` | ~165 | Focused tests for current response decoding, trusted asset hosts, declared/streamed byte limits, and supported atlas geometry. |
| `ContextManager.swift` | ~180 | Manages persistent Context Profiles for customizing Sato's behavior. Stores profiles as JSON in `~/Library/Application Support/Sato/profiles.json`. Provides CRUD operations, active profile switching, and starter profile creation on first launch. |
| `ConversationStore.swift` | ~390 | Persists conversation metadata and per-message screenshot files. Retains five recent unpinned threads plus all pinned threads and protects the active thread from pruning. |
| `OverlayWindow.swift` | ~1880 | Full-screen transparent overlays plus the dedicated chat panel controller. Manages cursor-tracking power gates, non-destructive lifecycle window suspension, resizable left/right docking, floating movement, edge snapping, multi-monitor clamping, and assist flow transitions. |
| `ChatSidebarView.swift` | ~680 | Responsive docked/floating chat UI with compact latest-response mode, typed or Sato Local follow-up input, full-thread expansion, adaptive Markdown/screenshot wrapping, pending follow-up screenshot previews, and persisted sidebar text-color controls. |
| `MarkdownRenderer.swift` | ~510 | Parses completed assistant responses into display-safe Markdown blocks and inline attributes. Preserves visible headings, paragraphs, list markers, code blocks, quotes, and readable LaTeX-style math. |
| `MarkdownResponseView.swift` | ~110 | SwiftUI renderer for completed Markdown response blocks. Gives headers, paragraphs, lists, quotes, and code blocks explicit visual spacing because `Text` does not reliably render Foundation block intents. |
| `SpeechBubbleView.swift` | ~140 | Speech bubble displaying Claude's response above the sprite. Shows active context profile name as header. Detects content overflow and shows a "Show more" button that opens the chat sidebar. |
| `SpriteDirection.swift` | ~100 | Eight compass directions for the sprite. Maps angles to directions and resolves which GIF asset to load (with horizontal mirroring for missing directions). |
| `SpriteAnimationManager.swift` | ~1615 | Manages the companion sprite state machine (resting/flying/assisting/pointing), bundled GIF extraction, off-main Petdex atlas preparation, adaptive 10/30/60 Hz animation power modes, source switching, and direction-based animation selection. |
| `SamoyedSpriteView.swift` | ~25 | Minimal SwiftUI view that renders the current sprite frame from `SpriteAnimationManager` at 136x136pt with nearest-neighbor interpolation. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `LocalSpeechTranscriptionManager.swift` | ~840 | Sato Local engine. Manages Fast/Accurate WhisperKit downloads, staged background preparation, preparation timeout/recovery, model loading, microphone permission, in-memory capture, Context Profile prompting, local transcription, cancellation, and deletion. |
| `LocalSpeechInputView.swift` | ~735 | Shared SwiftUI mic button, Cmd+Shift+M handling, live preparation status, and Sato Local setup popover used by both composers and the menu panel. |
| `LocalSpeechPreparationPresentationTests.swift` | ~55 | Focused tests for preparation-stage ordering, elapsed-time presentation, and the setup timeout. |
| `CompanionSleepPolicyTests.swift` | ~270 | Focused tests for Auto Sleep thresholds, doze and full-suspension eligibility, permission-grant restoration, and lifecycle-resume safety. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide Ctrl+Option monitor. Owns the listen-only `CGEvent` tap and publishes screenshot-shortcut press/release transitions. |
| `AIProviders/ProviderManager.swift` | ~185 | Selects the active Anthropic, OpenAI, Ollama Local, or Ollama Cloud provider and model, including context-profile overrides and local Ollama model discovery. |
| `AIProviders/AnthropicProvider.swift` | ~175 | Direct Anthropic vision and SSE streaming implementation. |
| `AIProviders/OpenAIProvider.swift` | ~195 | Direct OpenAI vision and streaming implementation. |
| `AIProviders/OllamaLocalProvider.swift` | ~210 | Local Ollama discovery and streaming implementation. |
| `AIProviders/OllamaCloudProvider.swift` | ~150 | Authenticated Ollama Cloud streaming implementation. |
| `KeychainHelper.swift` | ~90 | Stores remote-provider API keys in the macOS Keychain. |
| `ClaudeAPI.swift` | ~130 | Legacy direct Anthropic request helper retained for compatibility. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

Release candidates are archived and Developer ID-exported through Xcode Organizer, then passed to `./scripts/release.sh <version> <path-to-Sato.app>` for app/DMG notarization, stapling, Sparkle signing, and staged appcast generation. The script never publishes automatically.

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
