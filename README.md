# Sato

An AI desktop companion with a pixel art pet.

<!-- TODO: add demo.gif -->

## What it is

Sato is a macOS menu bar app that pairs a screen-aware AI assistant with an animated pixel art companion. Select a region of your screen, type a question, and get a response in a speech bubble -- or open the chat sidebar for longer conversations. Choose from five sprites (Max, Sky, Lexi, Rover, Paris) and customize Sato's behavior with context profiles.

## Features

- **Screenshot + question workflow** -- select a screen region, ask anything about it, get a streaming response from Claude
- **Chat sidebar** -- follow-up conversations with full context from the original screenshot
- **Customizable sprite** -- pick your companion: Max (Samoyed), Sky (cat), Lexi, Rover, or Paris
- **Context profiles** -- create named profiles with plain-English instructions to customize Sato's behavior per task
- **Stealth mode** -- hide the sprite but keep the AI assistant accessible via hotkey
- **Direct API** -- your Anthropic API key, stored in Keychain. No proxy, no middleman

## Download

Download the latest release from the [GitHub Releases page](https://github.com/vitalune/sato/releases).

## Requirements

- macOS 14.2+
- An [Anthropic API key](https://console.anthropic.com/)

## Install

1. Download the `.dmg` from the releases page
2. Drag Sato to your Applications folder
3. Launch Sato -- it appears in your menu bar (not the dock)
4. Grant the permissions it requests (Accessibility, Screen Recording, Screen Content)
5. Open the menu bar panel and paste your Anthropic API key
6. Press **Ctrl + Option** to start your first interaction

## Build from source

```bash
git clone https://github.com/vitalune/sato.git
cd sato
open leanring-buddy.xcodeproj
```

In Xcode: select the Sato scheme, set your signing team under Signing & Capabilities, and press Cmd+R. The `leanring-buddy/` directory name is a legacy artifact -- ignore it.

## How it works

See [CLAUDE.md](CLAUDE.md) for the full architecture documentation.

## Credits

Sato is a fork of [Clicky](https://github.com/farzaa/clicky) by [Farza Majeed](https://x.com/farzatv). The original project laid the foundation for the menu bar app, overlay system, and AI pipeline. Sato builds on that with direct API integration, context profiles, multiple sprites, a chat sidebar, and stealth mode.

## License

MIT -- see [LICENSE](LICENSE) for details.
