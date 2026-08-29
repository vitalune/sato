# Sato

An AI desktop companion with a pixel art pet.

<!-- TODO: add demo.gif -->

## What it is

Sato is a macOS menu bar app that pairs a screen-aware AI assistant with an animated pixel art companion. Select a region of your screen, type or privately dictate a question, and get a response in a speech bubble -- or open the chat sidebar for longer conversations. Choose from five built-in sprites or search thousands of community pets from Petdex, then customize Sato's behavior with context profiles.

## Features

- **Screenshot + question workflow** -- select a screen region, ask anything about it, and stream a response from your selected AI provider
- **Chat sidebar** -- follow-up conversations with full context from the original screenshot
- **Sato Local voice input** -- dictate questions on-device with WhisperKit using Fast or Accurate transcription; recordings are never uploaded
- **Customizable sprite** -- choose Max, Sky, Lexi, Rover, or Paris, or search and filter the Petdex community catalog; selected Petdex sprites are cached for offline use
- **Context profiles** -- create named profiles with plain-English instructions to customize Sato's behavior per task
- **Stealth mode** -- hide the sprite but keep the AI assistant accessible via hotkey
- **Auto Sleep** -- dozes in a low-power stationary animation after a minute without using Sato, fully suspends after 15 minutes of Mac inactivity, and wakes instantly when you return
- **Choose your AI** -- Anthropic, OpenAI, Ollama Local, and Ollama Cloud share one direct provider interface; remote API keys stay in Keychain

## Download

Download the latest release from the [GitHub Releases page](https://github.com/vitalune/sato/releases).

## Requirements

- macOS 14.2+
- An Anthropic, OpenAI, or Ollama Cloud API key, or a local Ollama installation
- An internet connection for the one-time speech model download; voice input works offline afterward

## Install

1. Download the `.dmg` from the releases page
2. Drag Sato to your Applications folder
3. Launch Sato -- it appears in your menu bar (not the dock)
4. Grant the permissions it requests (Accessibility, Screen Recording, Screen Content). Microphone access is optional and requested only when you use Sato Local.
5. Open the menu bar panel and configure your preferred AI provider
6. Press **Ctrl + Option** to start your first interaction

## Build from source

```bash
git clone https://github.com/vitalune/sato.git
cd sato
open leanring-buddy.xcodeproj
```

In Xcode: select the Sato scheme, set your signing team under Signing & Capabilities, and press Cmd+R. The `leanring-buddy/` directory name is a legacy artifact -- ignore it.

## How it works

See [AGENTS.md](AGENTS.md) for the full architecture documentation.

## Credits

Sato is a fork of [Clicky](https://github.com/farzaa/clicky) by [Farza Majeed](https://x.com/farzatv). The original project laid the foundation for the menu bar app, overlay system, and AI pipeline. Sato builds on that with direct multi-provider AI integration, context profiles, multiple sprites, a chat sidebar, and stealth mode. Community sprite discovery is powered by [Petdex](https://petdex.dev); each pet remains credited to its creator in the picker.

## License

MIT -- see [LICENSE](LICENSE) for details.
