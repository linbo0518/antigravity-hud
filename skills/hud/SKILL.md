---
name: hud
description: >-
  Initialize, configure, validate, preview, modify, uninstall, and troubleshoot
  Statusline HUD (statusline-hud) for Antigravity CLI. Use when the user invokes
  /hud or asks in natural language to set up, check, customize, toggle, reset,
  or fix the Antigravity CLI statusline HUD.
license: MIT
compatibility: Antigravity CLI with bash 3.2+, jq 1.6+, and optional git
---

# Statusline HUD Setup, Validation & Configuration (`/hud`)

Serve as the primary entry point for initializing, validating, previewing, modifying, uninstalling, and troubleshooting **Statusline HUD** (`statusline-hud`).

Note: This HUD targets **Antigravity CLI (`agy`)** TUI status lines on Linux, macOS, and WSL. Antigravity App desktop sessions and IDE extensions do not render a custom TUI statusline.

## Bundled Helper Script

Always use the bundled deterministic helper script [`scripts/hud.sh`](./scripts/hud.sh) (resolved relative to this `SKILL.md` directory) instead of hand-crafting ad-hoc `jq` or `sed` commands:

| Command | Purpose |
| --- | --- |
| `scripts/hud.sh doctor` | Read-only environment check (`bash`, `jq`, `git`), script path & executable check, `settings.json` status (`command`, `enabled`, `stack_with_default`), `config.json` syntax/key/type validation, effective config listing (`[ON]`/`[OFF]`), and smoke check |
| `scripts/hud.sh preview [width]` | Render a representative cross-platform plain-text preview (default width `120`; pass `80` for split-pane preview) |
| `scripts/hud.sh set <k>=<v> [...]` | Validate keys/values and atomically update `${XDG_CONFIG_HOME:-~/.config}/statusline-hud/config.json` (preserves unrelated valid keys; refuses to overwrite malformed JSON silently) |
| `scripts/hud.sh toggle <key> [...]` | Atomically flip one or more boolean keys based on current effective values—ideal for multi-select interactive menus |
| `scripts/hud.sh reset` | Remove `config.json` and restore all defaults |
| `scripts/hud.sh apply-settings` | Atomically write `statusLine` into `~/.gemini/antigravity-cli/settings.json` preserving existing keys and `0600` permissions (only run after explicit user confirmation) |

## Supported `config.json` Fields

Location: `${XDG_CONFIG_HOME:-~/.config}/statusline-hud/config.json` (hot-reloads on the next CLI status refresh; no restart needed).

| Key | Type / Values | Default | Effect |
| --- | --- | --- | --- |
| `preset` | `"standard"` \| `"compact"` \| `"minimal"` | `"standard"` | `"standard"`: adaptive multi-line HUD; `"compact"`: always hide progress bars while keeping adaptive metrics; `"minimal"`: Line 1 only |
| `showTitle` | boolean | `false` | Show the conversation title row above Line 1 when a title exists (hidden in `"minimal"` preset) |
| `showMode` | boolean | `true` | Show `cycle_mode` (`PLAN`/`EDITS`/`AUTO`) and Vim mode |
| `showPath` | boolean | `true` | Show current working directory path on Line 1 |
| `showGit` | boolean | `true` | Show Git branch and dirty/change indicators on Line 1 |
| `showQuota` | boolean | `true` | Show Line 2 quota row |
| `show3pQuota` | boolean | `true` | Show 3P quota pair alongside Gemini quota |
| `showActivity` | boolean | `true` | Show Line 3 activity counters (`artifacts`, `subagents`, `tasks`) |
| `showSandboxOff` | boolean | `false` | Show `sandbox off` when sandbox is disabled (`sandbox ON` always shows when active) |
| `showTokens` | boolean | `true` | Show session token count and input/output breakdown |
| `showCache` | boolean | `true` | Show cache hit rate |
| `showDuration` | boolean | `true` | Show session elapsed time |
| `showCost` | boolean | `true` | Show estimated USD cost |

## Workflow

### Step 1: Always start with `doctor`

Run `<skill-dir>/scripts/hud.sh doctor` first so you have ground-truth status for `jq`, script permissions, `settings.json`, `config.json` validity, and every effective `[ON]`/`[OFF]` setting.

### Step 2: Handle user intent

#### A. Open-ended `/hud` or "help me configure HUD"
1. Run `<skill-dir>/scripts/hud.sh preview 120` (and `80` if the user cares about split panes) and show a brief status summary + fenced preview.
2. If `settings.json` does not yet activate this script (or `enabled` is `false`), highlight the exact `/statusline <tilde-path>` command (or `/statusline enable`) right at the top.
3. If the `ask_question` tool is available, ask the user cleanly without ambiguity:
   - **Important**: `ask_question` multi-select does **not** pre-check existing values. Never ask "select all modules you want enabled" (unselected defaults could be misunderstood as turning them off).
   - Instead, ask up to 2 clear questions:
     - Question 1 (single-select): Choose layout preset (`standard` / `compact` / `minimal`), marking the current preset with `(Recommended)` and `(current)`.
     - Question 2 (multi-select): **"Select modules to toggle (ON ↔ OFF)"**, labeling every option with its live state from `doctor` (e.g., `showTitle [OFF] — Conversation title row`, `showPath [ON] — Working directory`, `showGit [ON] — Git branch & changes`, `showQuota [ON] — Quota row`, `show3pQuota [ON] — 3P quota`, `showActivity [ON] — artifacts / subagents / tasks`, `showSandboxOff [OFF] — Show sandbox off`, `showTokens [ON] — Token count`, `showCache [ON] — Cache hit rate`, `showDuration [ON] — Session duration`, `showCost [ON] — Estimated cost`, `showMode [ON] — PLAN/EDITS/AUTO & Vim`). Note that skipping / selecting none keeps all module toggles unchanged.
4. Apply only the changed preset (`scripts/hud.sh set preset=...`) and toggled keys (`scripts/hud.sh toggle ...`), then re-run `scripts/hud.sh preview 120` to confirm the new layout and note that it hot-reloads on the next status refresh.

#### B. Initialize / Setup (`/hud setup`, "initialize HUD", "enable statusline")
1. From `doctor` output, verify `jq` is installed and `statusline.sh` is executable. If `jq` is missing, give the install command first. If `statusline.sh` is missing `+x`, run `chmod +x` (or provide the command if read-only).
2. Check `settings.json`:
   - If already active and enabled, confirm it is ready and offer to preview or customize.
   - If `statusLine.enabled` is `false`, tell the user to run `/statusline enable`.
   - If `statusLine` points to another custom script, point it out clearly before switching.
   - If not active yet, present the two clean options (using `ask_question` if helpful):
     1. **(Recommended — instant hot reload)**: User runs `/statusline <tilde-path>` directly inside Antigravity CLI.
     2. **Auto-write `settings.json`**: If the user confirms, run `<skill-dir>/scripts/hud.sh apply-settings` (preserves other settings and `0600` permissions) and remind them to run `/statusline enable` or restart `agy` if it does not refresh immediately.
3. Offer to run a quick interactive configuration or keep defaults.

#### C. Modify config via natural language (e.g. "enable title", "hide path and cost", "use compact preset")
1. Map the user's request to the supported camelCase keys and run `<skill-dir>/scripts/hud.sh set <k>=<v> ...` (or `toggle` if they asked to flip a setting).
2. Because `~/.config/statusline-hud/config.json` is outside the workspace, writing may prompt for approval or be blocked in sandboxed modes. If blocked, output the exact ready-to-run `<skill-dir>/scripts/hud.sh set ...` command for the user to paste.
3. Re-run `<skill-dir>/scripts/hud.sh preview 120` to show the updated layout and confirm it hot-reloads automatically without restarting `agy`.

#### D. Validate / Troubleshoot (`/hud check`, `/hud doctor`, "statusline not working")
1. Present all findings from `scripts/hud.sh doctor` (missing `jq`, non-executable script, `settings.json` mismatch / `enabled: false` / `stack_with_default: true`, invalid JSON or unknown keys/types in `config.json`, failed smoke test).
2. Fix config issues via `scripts/hud.sh set` / `reset` after confirmation, and remind the user that Antigravity CLI disables a statusline after 30 consecutive failures (`⚠ Statusline disabled after 30 consecutive failures.`), recoverable via `/statusline enable` (or `/statusline delete` to revert).

#### E. Reset (`/hud reset`)
1. Run `<skill-dir>/scripts/hud.sh reset` (or provide the command if outside-workspace deletion is blocked).
2. Re-run `<skill-dir>/scripts/hud.sh preview 120` to verify default output.

#### F. Uninstall (`/hud uninstall`)
Remind the user to revert `statusLine` **before** removing the plugin files, otherwise Antigravity CLI will fail running the missing script until disabled after 30 failures:
1. Run `/statusline delete` inside Antigravity CLI.
2. Run `agy plugin uninstall statusline-hud` in the shell (and optionally remove `~/.config/statusline-hud/` and `~/.cache/statusline-hud/`).
