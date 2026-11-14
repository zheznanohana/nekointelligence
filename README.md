<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="NekoIntelligence icon">
</p>

<h1 align="center">NekoIntelligence</h1>

<p align="center">
  Apple's native <b>Writing Tools</b> on Intel Macs, powered by <b>your own</b> OpenAI-compatible API.
</p>

<p align="center">
  <a href="https://github.com/zheznanohana/nekointelligence/releases/latest"><img src="https://img.shields.io/github/v/release/zheznanohana/nekointelligence?style=flat-square" alt="Release"></a>
  <a href="https://github.com/zheznanohana/nekointelligence/releases"><img src="https://img.shields.io/github/downloads/zheznanohana/nekointelligence/total?style=flat-square" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20(Intel)-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/tested-macOS%2026.7.3-fa4e49?style=flat-square" alt="Tested on macOS 26.7.3">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/zheznanohana/nekointelligence?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/panel.png" width="300" alt="Apple's Writing Tools panel running on an Intel Mac">
</p>

> [!WARNING]
> NekoIntelligence requires **SIP and AMFI to be disabled**. It loads a patched copy of a system XPC service with private entitlements, which a stock, fully protected macOS will refuse to run. Only use it on a machine where you understand and accept that trade-off.

> [!NOTE]
> This is an unofficial project and is not affiliated with Apple. It modifies **no system files**: everything lives in one app in `/Applications` and in `~/Library/Application Support/AppleIntel`.

## Features

- **The real panel, not a look-alike.** Uses the system's own `WritingToolsViewService` (an in-app copy with three byte patches), so it looks and behaves exactly like Apple Intelligence.
- **All 10 actions.** Proofread and Rewrite go through Apple's native path. Friendly, Professional, Concise, Summary, Key Points, List, Table and Compose normally need Apple's on-device models; here they are turned into instructions for your API.
- **Describe your change.** Type any instruction at the top of the panel, such as "translate to English", and press Return.
- **Works in every app.** Select text anywhere and press **⌘9**. The panel appears in place and the result is written back.
- **Services menu.** Right-click → Services → rewrite, summarize, translate or proofread in place in about a second, without opening the panel.
- **Bring your own model.** Any OpenAI-compatible endpoint works. Presets: Qwen Token Plan, OpenAI, OpenRouter, DeepSeek, Ollama, LiteLLM, new-api / one-api.
- **A native Mac app.** One window with an App Store-style sidebar (Writing Tools, Shortcuts, Providers, General, Diagnostics), built against Apple's Human Interface Guidelines, in light and dark mode.
- **Undo and transparency.** Undo the last rewrite (up to 5 steps). The app always shows which provider and model produced the text.
- **Self-check.** The Diagnostics pane checks patches, injection, Services registration and your API in one click.

<p align="center">
  <img src="docs/providers.png" width="49%" alt="Providers pane">
  <img src="docs/shortcuts.png" width="49%" alt="Shortcuts pane">
</p>

## Requirements

| | |
| --- | --- |
| Mac | Intel (x86_64). Hackintoshes and older Intel Macs both work. |
| macOS | Tested on macOS 26.7.3 (25G342). Other versions may need new patch offsets. |
| Security | SIP disabled (`csrutil disable`) and AMFI disabled (`amfi_get_out_of_my_way=0x1` in boot-args) |
| API | Any OpenAI-compatible chat completions endpoint and its API key |

## Installation

1. Download `NekoIntelligence-<version>.dmg` from the [latest release](https://github.com/zheznanohana/nekointelligence/releases/latest).
2. Open the DMG, double-click the app and choose **Install**. It copies itself to `/Applications`, relaunches from there and ejects the disk image. Dragging it to Applications also works.
3. If macOS says the developer can't be verified, right-click the app and choose **Open**. The app is ad-hoc signed, not notarized.
4. When asked, enable the app in **System Settings → Privacy & Security → Accessibility**. This is only used to read the text you select in other apps and write the result back.

## Usage

1. Open the app and go to **Providers** (⌘,). Pick a preset or add your own Base URL, API key and model, click **Test Connection**, then **Save**.
2. In any app, select some text and press **⌘9**. Choose an action in the panel, or type an instruction and press Return.
3. For one-step edits without the panel, right-click the selection → **Services** → *Rewrite / Summarize / Translate / Proofread Selected Text*.

| Shortcut | Action |
| --- | --- |
| ⌘9 | Rewrite the selection in the front app |
| ⌃⌥⌘W | Open Writing Tools with the clipboard text |
| ⌥⌘Z | Undo the last rewrite |
| ⌘, | Providers |
| ⌘1 – ⌘5 | Switch sidebar panes |
| ⌃⌘S | Show or hide the sidebar |

The app opens at login by default. Turn this off in **General**. The interface language (中文 / English) is also there. The Services menu and the app name in Finder follow your macOS language.

## FAQ

### The panel is gray, or nothing happens when I click an action

Open **Diagnostics** and click **Run Self-Check**. The first failing item tells you what broke. After a macOS update the patch offsets may have moved, and the app needs to be rebuilt for the new version.

### I enabled Accessibility, but the app still says "Not granted"

macOS ties Accessibility approval to the app's code signature, and older copies of the app share the same bundle ID. Reset the entry and grant it again:

```bash
tccutil reset Accessibility com.local.appleintelligence.intel
```

Then reopen the app and enable it again when prompted.

### Why do I need to disable SIP and AMFI?

The panel comes from a copy of Apple's `WritingToolsViewService`. That copy is ad-hoc signed but needs Apple's private entitlements, and our libraries are injected into it with `DYLD_INSERT_LIBRARIES`. AMFI blocks both. Keep in mind that disabling AMFI also removes an important protection for the rest of the system.

### Does it work on Apple Silicon?

Probably not. The three patch offsets target the x86_64 slice only. You can look for the arm64 equivalents yourself with Ghidra or a similar tool.

### Are Image Playground, the new Siri, or the Apple Intelligence settings pane supported?

No. Their UI runs in arm64e-only extensions that Intel Macs can't load.

### Where are my API keys stored?

In `~/Library/Application Support/AppleIntel/providers.json` with permissions `0600`, on your Mac only. They are not in the Keychain yet.

## Uninstall

```bash
bash ~/Library/Application\ Support/AppleIntel/uninstall.sh
```

This removes the app, the login item, the support folder, Services registration and temporary files. Pass `--keep-data` to keep your configuration and logs, or `--check` to see what is installed without removing anything.

## Building from source

Requires the Xcode Command Line Tools (`clang`), `python3` and macOS 15 or later.

```bash
git clone https://github.com/zheznanohana/nekointelligence.git && cd nekointelligence
./scripts/build.sh                                    # installs to /Applications and creates dist/*.dmg
APP_OUT=/tmp/Test.app NO_DMG=1 ./scripts/build.sh     # build only, no DMG
```

The repository contains **no Apple binaries**. At build time the script copies `WritingToolsViewService.xpc` from your own system and patches only that copy.

## How it works

1. `WritingToolsUI.framework` provides Writing Tools to every `NSTextView` app, but each process first checks whether the Mac supports generative models. On Intel that check always fails, so the panel stays gray.
2. NekoIntelligence copies the system `WritingToolsViewService.xpc` into its own bundle, so it can inject libraries through `XPCService.EnvironmentVariables.DYLD_INSERT_LIBRARIES`. Three byte patches make the availability checks pass, and `vsstub.dylib` intercepts the ViewService → `textcomposerd` XPC proxy to answer with your provider.
3. A Unix-socket relay inside the host app (`GMBridge`) turns `{system, user}` into an OpenAI-compatible HTTPS request. Switching backends only takes a new Base URL.

| Path | What it is |
| --- | --- |
| `src/host/AIHost.m` | Host app: text capture, Services, menus, hotkeys |
| `src/host/GMShell.m` | The single-window interface |
| `src/host/GMBridge.m` | The relay to your API |
| `src/host/GMSetup.m` | Self-repair, self-install, login item |
| `src/inject/` | Libraries injected into the ViewService |
| `scripts/` | Build, patch, self-check and uninstall scripts |

## Known limitations

- Patch offsets are verified only on macOS 26.7.3 (25G342).
- Instructions typed in the panel and the 8 preset actions apply only after the upstream reply (10–20 s in testing). There is no streaming.
- API keys are stored in a file, not the Keychain.
- ⌘9 can't be changed yet.

## Acknowledgements

- The interface was reviewed with [apple-design-skill](https://github.com/dickwu/apple-design-skill), a reviewer grounded in Apple's Human Interface Guidelines.

## License

[MIT](LICENSE). Apple, Apple Intelligence and Writing Tools are trademarks of Apple Inc. Use this only on your own Mac and follow your API provider's terms.
