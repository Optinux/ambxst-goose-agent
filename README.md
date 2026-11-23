# Goose Agent for Ambxst

Run the [Goose](https://github.com/block/goose) autonomous agent straight from the [Ambxst](https://github.com/Axenide/Ambxst) AI sidebar. Goose sees which windows and folders you have open, shows every command it runs as a live card, and can look at your screen.

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Ambxst](https://img.shields.io/badge/Ambxst-%E2%89%A51.4.1%20%3C2.0.0-informational)
![Mod ID](https://img.shields.io/badge/mod%20id-community.goose.agent-lightgrey)

> Unofficial community mod. It is not affiliated with or endorsed by the Ambxst or Goose projects.

## Features

- **Goose as a model in the AI sidebar.** A "Goose Agent" entry is added at the top of the model list. By default it is selected whenever you open the sidebar (`SUPER+A`).
- **Desktop context without copy-pasting paths.** The focused app, window title, working folder and the other open windows are passed to Goose as system context. Folders are resolved from terminals (child process cwd via `/proc`), file managers (Dolphin over D-Bus, window title, cwd) and other apps (title, cwd).
- **Live progress.** A strip above the chat shows the current status and command, a progress bar, a step counter and one expandable card per tool call (first 400 characters of output). A **Stop** button interrupts the run.
- **Persistent sessions.** Follow-up prompts resume the same Goose session; starting a new chat starts a new session.
- **Vision.** Take a screenshot with the **Shot** button (focused monitor, active window or all monitors), attach images in the sidebar, or let Goose capture the screen itself. Optionally route images through a separate vision model so text-only Goose models still get vision.
- **Native configuration.** All options live in **Settings → Mods** (no config files to edit).

## Requirements

| Requirement | Notes |
| --- | --- |
| [Ambxst](https://github.com/Axenide/Ambxst) | `>=1.4.1 <2.0.0`. Composes cleanly onto commit `730f0f7` (the tested base). |
| [Goose CLI](https://github.com/block/goose) | `goose` on your `PATH` (or set **Goose Binary Path**). Run `goose configure` once to pick a provider and model. Must support `goose run --output-format stream-json`. |
| `axctl` | Installed by the Ambxst installer. Used for window, workspace and monitor data. |
| Python 3.8+ | For the helper scripts (standard library only). |
| `grim` *(optional)* | Screenshots. `spectacle` is used as a fallback. |
| `qdbus6` / `qdbus` *(optional)* | Lets the mod read the current folder of Dolphin. |

Window context is implemented for Hyprland (`hyprctl`), and for Niri and Mango through `axctl` and `niri msg`. Active-window screenshots use `hyprctl` geometry; on other compositors that mode falls back to the focused monitor.

## Installation

```sh
ambxst mods install https://github.com/Optinux/ambxst-goose-agent.git
ambxst mods enable community.goose.agent
ambxst reload
```

The manager shows the author, declared permissions and affected files before anything is installed, and new packages always start disabled. You can do the same in **Settings → Mods**, or use the one-click link:

```text
ambxst://mods/install?source=https%3A%2F%2Fgithub.com%2FOptinux%2Fambxst-goose-agent.git
```

From a local checkout:

```sh
git clone https://github.com/Optinux/ambxst-goose-agent.git
ambxst mods install ./ambxst-goose-agent
```

## Usage

1. Make sure `goose` works in a terminal (`goose configure` if you have not set a provider yet).
2. Press `SUPER+A`. **Goose Agent** is preselected (see *Default to Goose on SUPER+A* below).
3. Ask something that uses what is on your screen:
   - *"Why did this build fail?"* with a terminal in focus
   - *"Summarize the files in this folder"* with a file manager open
   - *"Look at my screen and explain this error"*
4. Watch the cards fill in. Click a card to expand its output, **Stop** to cancel.
5. Open a new chat to start a fresh Goose session.

The small badge in the strip shows *windows on this workspace / windows in total*; click it to refresh the context.

## Configuration

Open **Settings → Mods → Goose Agent Integration**.

| Setting | Key | Default | Description |
| --- | --- | --- | --- |
| Default to Goose on SUPER+A | `defaultToGooseOnOpen` | on | Automatically select the Goose agent model whenever the AI Sidebar opens. |
| Context Refresh Interval (seconds) | `contextPollIntervalSec` | `2` | How often open windows and active folder context refresh while the AI Sidebar is open. Range 1–60. |
| Screenshot Capture Area | `screenshotMode` | `monitor` | Default target when taking a screenshot for Goose vision analysis. Options: `monitor`, `window`, `all`. |
| Auto-Attach Screenshot on Every Prompt | `autoScreenshotOnPrompt` | off | Automatically capture and attach a screenshot whenever you send a message to Goose. |
| Dedicated Vision Model (Optional) | `visionModel` | *(empty)* | If set (e.g. gemma-4-26b-a4b-vision), screenshots/uploads are analyzed by this model first so text-only Goose models still get vision. |
| Vision API Base URL | `visionApiBase` | `http://127.0.0.1:4000/v1` | OpenAI-compatible /v1 endpoint for the dedicated vision model (e.g. http://localhost:4000/v1 or http://&lt;host&gt;:4000/v1). |
| Vision API Key (Optional) | `visionApiKey` | *(empty)* | Bearer token for your LiteLLM / vision endpoint (leave empty if using OPENAI_API_KEY). |
| Goose Execution Mode | `gooseMode` | `auto` | Controls GOOSE_MODE passed to the agent (auto executes tools immediately). Options: `auto`, `smart_approve`, `chat`. |
| Built-in Extensions | `builtinExtensions` | `developer` | Comma-separated Goose built-in extensions passed to --with-builtin. |
| Share All Open Windows | `includeAllWindows` | on | Include every open window across workspaces, not just the focused window. |
| Max Agent Turns | `maxTurns` | `25` | Safety limit for tool-call loops per prompt (--max-turns). Range 1–100. |
| Goose Binary Path | `gooseBinary` | `goose` | Executable name or absolute path to the goose CLI. |

### Vision model (optional)

If **Dedicated Vision Model** is set, every screenshot or uploaded image is first sent to that model through an OpenAI-compatible `POST {base}/chat/completions` request. The text analysis is prepended to your prompt, so Goose can use a text-only model. If the request fails, the mod falls back to handing the image paths to Goose directly.

The API key is taken from **Vision API Key**, else the `OPENAI_API_KEY` environment variable of the Ambxst process, else a placeholder token (fine for unauthenticated local servers such as a LiteLLM or llama.cpp proxy).

## Privacy and security

This mod gives an autonomous agent access to your desktop. Please read this before enabling it.

**What leaves your machine.** Whatever model Goose is configured with receives your prompt plus a system context containing application names, **window titles** and folder paths. With *Share All Open Windows* enabled (the default) that covers every window on every workspace. Window titles can contain private information such as mail subjects, document names or URLs. Turn the setting off to share only the current workspace. Screenshots and attached images go to the Goose model or, if configured, to your vision endpoint.

**What the agent can do.** The default **Goose Execution Mode** is `auto`: tool calls (shell commands, file edits) run immediately, without asking, in the focused window's folder or in `$HOME`. Use *Smart Approve* or *Chat Only* if you want more oversight, and keep **Max Agent Turns** low.

**Secrets.** **Vision API Key** is stored as a plain string in Ambxst's mod settings. If you can, leave it empty and export `OPENAI_API_KEY` in the environment that starts Ambxst. For the duration of a vision request the key is also written to a temporary file (see below).

**Temporary files.** The helpers use fixed names in `/tmp`; permissions follow your `umask`, so on a multi-user machine other users may be able to read them.

| Path | Content | Cleanup |
| --- | --- | --- |
| `/tmp/ambxst-goose-screenshots/` | Screenshots (`shot-*.png`) and decoded uploads (`upload-*`) | Newest 10 screenshots are kept; uploads are not removed automatically |
| `/tmp/ambxst-goose-pending-attachments.json` | Attachments handed to the decoder | Deleted after decoding |
| `/tmp/ambxst-goose-vision-req.json` | Vision request, including the API key if set | Deleted when the helper has read it |

Consider `chmod 700 /tmp/ambxst-goose-screenshots` and clearing it now and then.

The manifest lists these capabilities under `permissions`, which the mod manager shows before you enable the package. Permissions are review metadata, not a sandbox: installed QML and scripts run with your user's rights.

## What this mod changes

Files added (overlays):

| Source | Target in Ambxst |
| --- | --- |
| `payload/modules/services/GooseAgentService.qml` | `modules/services/GooseAgentService.qml` – runs `goose run`, parses its stream, manages screenshots/vision |
| `payload/modules/services/GooseContextService.qml` | `modules/services/GooseContextService.qml` – refreshes window/folder context, builds the system prompt |
| `payload/modules/widgets/dashboard/assistant/GooseActivityView.qml` | same path – the activity strip |
| `payload/scripts/goose_context.py` | `scripts/goose_context.py` – window and folder detection |
| `payload/scripts/goose_screenshot.py` | `scripts/goose_screenshot.py` – screenshot capture |
| `payload/scripts/goose_save_attachments.py` | `scripts/goose_save_attachments.py` – decodes sidebar attachments |
| `payload/scripts/goose_vision.py` | `scripts/goose_vision.py` – calls the vision endpoint |
| `payload/assets/icons/goose.svg` | `assets/icons/goose.svg` |

Files patched:

| Patch | File | Change |
| --- | --- | --- |
| `patches/ai-service-goose.patch` | `modules/services/Ai.qml` | Registers the Goose model, routes requests to `GooseAgentService`, streams output into the chat, selects Goose on open, resets the session on new chat |
| `patches/assistant-sidebar-goose.patch` | `modules/sidebar/AssistantSidebar.qml` | Shows the Goose icon and the activity strip for the Goose model |

## Compatibility and updates

`compatibility.ambxst` is a hard requirement of the mod manager; `testedBaseCommits` is advisory. If Ambxst moves the lines a patch was written against, the manager retries it as a three-way merge. If that fails, the build stops and Ambxst keeps running on the last good generation. After an Ambxst update, run `ambxst mods rebuild` if Settings asks for it.

A weekly GitHub Actions run checks that the package still composes onto the current Ambxst source.

## Troubleshooting

| Symptom | What to try |
| --- | --- |
| Goose Agent is not in the model list | `ambxst mods list` should show the mod as enabled; then `ambxst reload`. Copy `ambxst mods diagnostics` into a bug report if it still fails. |
| `Goose Error:` with `command not found` | Set **Goose Binary Path** to the absolute path of `goose`. |
| Goose rejects a flag | Update Goose. The mod calls `goose run` with `--name`, `--output-format stream-json`, `--max-turns`, `--system`, `--text`, `--resume` and `--with-builtin`. |
| *No Wayland screenshot tool found* | Install `grim` (or `spectacle`). |
| *Goose is still finishing the previous request* | Wait or press **Stop**. Only one run is active at a time. |
| *Vision HTTP …* or *Vision request failed* | Check **Vision API Base URL**, model name and key. The image is still passed to Goose directly. |
| Wrong folder detected | Folder detection is best-effort. Name the path in your prompt. |
| Shell will not start after enabling | `ambxst mods rollback`, or start once with `AMBXST_MODS_DISABLED=1 ambxst`. |

## Uninstall

```sh
ambxst mods disable community.goose.agent
ambxst mods remove community.goose.agent
ambxst reload
```

## Development

```text
ambxst.mod.json   manifest (id, version, compatibility, permissions, operations)
settings.json     settings schema shown in Settings -> Mods
CHANGELOG.md      shown in the update preview (keep the newest release first)
payload/          files added to Ambxst as overlays
patches/          unified diffs applied to existing Ambxst files
tools/            validate_package.py
```

Validate before every release (needs `pip install jsonschema` and a clone of Ambxst):

```sh
git clone https://github.com/Axenide/Ambxst.git ../Ambxst
python3 tools/validate_package.py --schemas ../Ambxst/docs/mods --ambxst ../Ambxst
```

The script checks the manifest and settings against Ambxst's schemas, the referenced files and changelog, that the patches compose onto the tested commit and the current Ambxst `HEAD`, and scans the package for private IP addresses, API keys, e-mail addresses and personal home paths.

To publish a change: bump `version` in `ambxst.mod.json`, add a heading and notes to `CHANGELOG.md`, update `compatibility.testedBaseCommits`, and run the validator. Regenerate a patch from an Ambxst checkout with `git diff`; do not let your editor strip trailing whitespace in `.patch` files.

Bug reports and pull requests are welcome. Please remove API keys, hostnames, usernames and window titles from anything you paste.

## Acknowledgements

Built for [Ambxst](https://github.com/Axenide/Ambxst) by Axenide and powered by [Goose](https://github.com/block/goose).

## License

[MIT](LICENSE). Ambxst itself is licensed separately (AGPL-3.0); see its repository.
