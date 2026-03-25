# lil agents

![lil agents](hero-thumbnail.png)

Tiny AI companions that live on your macOS dock.

**AXO** and **Mudbug** cruise back and forth above your dock on skateboards. Click one to open a dockside AI terminal. They skate, they think, they vibe.

## features

- Animated characters rendered from transparent video loops
- Click a character to chat with Claude Code or OpenAI (Codex) in a themed popover terminal
- Four visual themes: Peach, Midnight, Cloud, Moss
- Thinking bubbles with playful phrases while your assistant works
- Sound effects on completion
- First-run onboarding with a friendly welcome
- Auto-updates via Sparkle

## requirements

- macOS Sonoma (14.0+)
- [Claude Code CLI](https://claude.ai/download) or a local `codex` CLI install

## building

Open `lil-agents.xcodeproj` in Xcode and hit run.

## privacy

lil agents runs entirely on your Mac and sends no personal data anywhere.

- **Your data stays local.** The app plays bundled animations and calculates your dock size to position the characters. No project data, file paths, or personal information is collected or transmitted.
- **AI providers.** Conversations are handled by the local CLI you select from the menu bar. lil agents does not intercept, store, or transmit your chat content beyond handing it to the provider CLI you choose. Any data sent upstream is governed by that provider's terms and privacy policy.
- **No accounts.** No login, no user database, no analytics in the app.
- **Updates.** lil agents uses Sparkle to check for updates, which sends your app version and macOS version. Nothing else.

## license

MIT License. See [LICENSE](LICENSE) for details.
