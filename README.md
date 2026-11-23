<p align="center">
  <img src="./assets/logo.svg" alt="Statusline HUD logo" width="84" />
</p>

<h1 align="center">Statusline HUD</h1>

<p align="center">
  English | <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  An adaptive multi-line terminal HUD (<code>scripts/statusline.sh</code>) and interactive <code>/hud</code> setup &amp; configuration plugin for <a href="https://antigravity.google/docs/cli/statusline">Antigravity CLI (<code>agy</code>)</a>.<br />
  Pure Bash + <code>jq</code> · Zero build step · ~20ms warm render · Full JSON customization.
</p>

> [!NOTE]
> Targets **Antigravity CLI (`agy`)** on Linux, macOS, and Windows (WSL). Antigravity App desktop sessions and IDE extensions do not render custom TUI status lines.

## Preview

![Statusline HUD preview](./assets/example.png)

**Default wide working session (3 lines — optional title row can be enabled with `showTitle: true`)**

```text
  ⚙ WORKING │ EDITS │ Gemini 4 Neon (XHigh) │ ctx ██░░░░░░░░ 19.7% │ ~/projects/antigravity-hud │ main* !1 ?7
  Gemini 5h █░░░░░░░░░ 7.3% 2h44m / week ██░░░░░░░░ 20.3% 5d4h │ 3P 5h ░░░░░░░░░░ 0.0% 5h0m / week █████░░░░░ 52.0% 2d23h
  artifacts 2 │ subagents 1/2 │ tasks 1 │ token 4.6M (4.5M↑ 122k↓) │ cache 95.1% │ 58m │ ~$0.42
```

**Approval pending + mid-width terminal (auto-drops bars to prevent wrapping)**

```text
  ⚠ CONFIRM (+1) │ EDITS [N] │ Gemini 4 Neon (XHigh) │ ctx ██░░░░░░░░ 24.5% │ …/antigravity-hud │ main*
  Gemini 5h 18.0% (1h0m) / week 7.0% (6d11h) │ 3P 5h 30.0% (2h0m) / week 15.0% (4d15h)
  subagents 0/2 │ sandbox ON │ token 268k (261k↑ 7k↓) │ cache 76.7% │ 14m │ ~$0.42
```

**Fresh session (empty quota row and zero counters auto-collapse to 1 clean line)**

```text
  ● READY │ Gemini 4 Neon (XHigh) │ ctx ░░░░░░░░░░ 0.0% │ ~/projects/antigravity-hud │ main*
```

## Quick Start

1. **Install the plugin**

   ```bash
   agy plugin install https://github.com/linbo0518/antigravity-hud
   ```

2. **Initialize and customize via `/hud`**

   Launch `agy` and run **`/hud`** (or simply ask *"initialize my statusline HUD"*). It checks dependencies, previews your layout, and walks you through enabling the status line—or skip straight to activation with:

   ```text
   /statusline ~/.gemini/config/plugins/statusline-hud/scripts/statusline.sh
   ```

> **Upgrading**: Re-run `agy plugin install https://github.com/linbo0518/antigravity-hud` anytime. All preferences live in `~/.config/statusline-hud/config.json` and are never overwritten.

<details>
<summary>Alternative: Standalone single-script install (without the <code>/hud</code> skill)</summary>

```bash
cp scripts/statusline.sh ~/.gemini/antigravity-cli/statusline.sh
chmod +x ~/.gemini/antigravity-cli/statusline.sh
```

Enable inside Antigravity CLI with `/statusline ~/.gemini/antigravity-cli/statusline.sh`, or add to `~/.gemini/antigravity-cli/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.gemini/antigravity-cli/statusline.sh"
  }
}
```

</details>

## Interactive Entry Point (`/hud`)

`/hud` is the single entry point for initializing, validating, customizing, previewing, resetting, and troubleshooting the HUD—usable via **`/hud` slash commands** or **plain natural language** (e.g., *"initialize my HUD"*, *"hide cost and 3P quota"*, *"check my statusline config"*):

| Command / Prompt | What it does |
| --- | --- |
| `/hud` | Validates `jq`, script permissions, `settings.json`, and `config.json`, renders a live preview, and walks through interactive questions to choose a preset or toggle modules without overwriting unrelated settings |
| `/hud setup` *(or "initialize HUD")* | Checks dependencies and `settings.json` (`enabled`, `stack_with_default`, existing command), then guides instant activation via `/statusline` or optional atomic `settings.json` update |
| `/hud check` *(or "validate HUD config")* | Checks `config.json` syntax, unknown keys, wrong types, script permissions, and runs a smoke test |
| `/hud switch to compact layout` *(or natural language)* | Validates and updates `config.json` (e.g., *"enable title and hide path"*, *"hide 3P quota and cost"*) and immediately previews the result |
| `/hud reset` | Removes user overrides and restores default settings |
| `/hud uninstall` | Walks through safe deactivation (`/statusline delete`) before uninstalling the plugin |

## Configuration (`config.json`)

`${XDG_CONFIG_HOME:-~/.config}/statusline-hud/config.json` is the single source of truth for all HUD preferences. Works out of the box with zero configuration; edits (whether via `/hud` or by hand) hot-reload on the next status refresh without restarting `agy`. All keys are optional; missing fields or invalid JSON safely fall back to defaults:

| Key | Type / Values | Default | Description |
| --- | --- | --- | --- |
| `preset` | `"standard"` \| `"compact"` \| `"minimal"` | `"standard"` | `"standard"`: adaptive multi-line HUD; `"compact"`: always hide progress bars while keeping adaptive metrics; `"minimal"`: Line 1 only |
| `showTitle` | boolean | `false` | Show the conversation title row (`▸ Title`) above Line 1 when available (hidden in `"minimal"` preset) |
| `showMode` | boolean | `true` | Show `cycle_mode` (`PLAN` / `EDITS` / `AUTO`) and Vim mode |
| `showPath` | boolean | `true` | Show current working directory path on Line 1 |
| `showGit` | boolean | `true` | Show Git branch and working-tree change indicators on Line 1 |
| `showQuota` | boolean | `true` | Show Line 2 quota row |
| `show3pQuota` | boolean | `true` | Show 3P quota alongside Gemini quota |
| `showActivity` | boolean | `true` | Show Line 3 activity counters (`artifacts`, `subagents`, `tasks`) |
| `showSandboxOff` | boolean | `false` | Show `sandbox off` when sandbox is disabled (`sandbox ON` always shows when active) |
| `showTokens` | boolean | `true` | Show session token total and input/output breakdown |
| `showCache` | boolean | `true` | Show cache hit rate |
| `showDuration` | boolean | `true` | Show session elapsed time |
| `showCost` | boolean | `true` | Show estimated USD cost |

Example (`~/.config/statusline-hud/config.json`):

```json
{
  "preset": "standard",
  "showTitle": true,
  "show3pQuota": false,
  "showCost": false
}
```

## Features

- **Full Antigravity CLI state coverage**: Maps `idle`, `working`, `tool_use`, `reviewing`, `error`, `authenticating`, and `initializing`; surfaces `tool_confirmation_pending` (`⚠ CONFIRM`) and queued user messages `(+N)` with top priority; shows `cycle_mode` (`PLAN` / `EDITS` / `AUTO`), optional Vim mode, and optional conversation title.
- **Width-aware anti-wrap layout**: Computes exact Unicode cell widths (including CJK and wide emoji) against `terminal_width` across every row and degrades gracefully—shortening paths/models before hiding permission modes, dropping progress bars, tightening dual quotas, and collapsing empty rows—so split panes never wrap and break the TUI.
- **Accurate session telemetry**:
  - `subagents` tracks `running/total` so completed subagents stay muted while active ones stand out.
  - Accumulates full-session tokens (handling rewinds that reuse `step_index`), cache hit rate, and elapsed duration from `transcript.jsonl`, cached by `mtime + size`, falling back to `context_window.current_usage` before the transcript is written.
- **Fast, safe, cross-platform**: Single `jq` pass (reading stdin and `config.json` together), ANSI/control-character sanitization on untrusted titles and branch names, locale-safe progress bars (`LC_ALL=C` compatible), Bash outvar helpers avoiding subshell forks, 2-second TTL cache + timeout guard for `git status --no-optional-locks`, automatic cleanup of stale cache files (>7 days), and Linux + macOS compatibility (Bash 3.2 + BSD `stat`).

## Symbol Legend

- **Git indicators**: `*` dirty working tree, `↑N` / `↓N` commits ahead / behind upstream, `!N` modified / conflicted, `+N` added, `✘N` deleted, `?N` untracked.
- **Quota**: Percentage shows **used** share (green `<60%`, yellow `60–89%`, red `>=90%`) followed by time until reset; buckets reporting only remaining count display `<N> left`.
- **Tokens**: `token <total> (<input>↑ <output>↓)` across the full session.

## Requirements

- Antigravity CLI (`agy`)
- `bash` (3.2+)
- `jq` (1.6+)
- `git` (optional, for branch and working tree status)

## Uninstall

Revert the statusline command **before** uninstalling the plugin (otherwise Antigravity CLI will fail invoking the removed script):

1. Inside Antigravity CLI, run `/statusline delete`.
2. In your shell, run:

```bash
agy plugin uninstall statusline-hud
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/statusline-hud" "${XDG_CACHE_HOME:-$HOME/.cache}/statusline-hud"  # optional
```

## Cache, Testing & Validation

- Runtime cache lives under `${XDG_CACHE_HOME:-~/.cache}/statusline-hud/` (`git/` and `transcript/`), with automatic low-frequency cleanup for files older than 7 days.
- Run the regression test suite and strict plugin validation:

```bash
./tests/test.sh
agy plugin validate --strict .
```

## Acknowledgments

This project is inspired by and builds upon the work of the following projects—sincere thanks to their authors and maintainers:

- **[claude-hud](https://github.com/jarrodwatts/claude-hud)** by Jarrod Watts (MIT License) — for inspiring the multi-line HUD information hierarchy, scannable visual design, and interactive `/hud` configuration workflow.
- **[Google Antigravity CLI official `statusline` example](https://github.com/google-antigravity/antigravity-cli/tree/main/examples/statusline)** — for the standard 16-color palette, single-pass `jq` pattern, and reference implementation of the Antigravity CLI status payload.

## License

[MIT](./LICENSE)
