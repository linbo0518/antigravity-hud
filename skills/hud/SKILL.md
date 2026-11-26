---
name: hud
description: >-
  Initialize, configure, validate, preview, modify, migrate, extend, uninstall,
  and troubleshoot Statusline HUD (statusline-hud) for Antigravity CLI. Use when
  the user invokes /hud or asks in natural language to set up, check, customize,
  toggle, reset, debug, or fix the Antigravity CLI statusline HUD.
license: MIT
compatibility: Antigravity CLI with bash 3.2+, jq 1.6+, and optional git
---

# Statusline HUD Setup, Validation & Configuration (`/hud`)

Serve as the primary entry point for initializing, validating, previewing, modifying, migrating, debugging, extending, and uninstalling **Statusline HUD** (`statusline-hud`).

Note: This HUD targets **Antigravity CLI (`agy`)** TUI status lines on Linux, macOS, and WSL. Antigravity App desktop sessions and IDE extensions do not render a custom TUI statusline.

## Bundled Helper Script

Always use the bundled deterministic helper script [`scripts/hud.sh`](./scripts/hud.sh) (resolved relative to this `SKILL.md` directory) instead of hand-crafting ad-hoc `jq` or `sed` commands:

| Command | Purpose |
| --- | --- |
| `scripts/hud.sh doctor` | Read-only environment check (`bash`, `jq`, `git`), script path & executable check, `settings.json` status (`command`, `enabled`, `stack_with_default`), `config.json` syntax/key/type validation, effective config listing (`[ON]`/`[OFF]`, `narrow=inherit` or override), and smoke check |
| `scripts/hud.sh config` | Show config path and effective `[ON]`/`[OFF]` + `narrow` states |
| `scripts/hud.sh preview [width]` | Preview the saved layout without writing (default `120`; use `80` for split panes) |
| `scripts/hud.sh set <k>=<v> [...]` | Validate keys/values and atomically update `${XDG_CONFIG_HOME:-~/.config}/statusline-hud/config.json` (preserves unrelated valid keys; refuses to overwrite malformed JSON silently) |
| `scripts/hud.sh toggle <key> [...]` | Atomically flip one or more boolean keys based on current effective values—ideal for multi-select interactive menus |
| `scripts/hud.sh unset <key> [...]` | Atomically remove overrides (`showX`, `narrow.showX`, or `narrow`) to restore defaults or narrow inheritance |
| `scripts/hud.sh reset` | Remove `config.json` and restore all defaults |
| `scripts/hud.sh apply-settings` | Atomically write `statusLine` into `~/.gemini/antigravity-cli/settings.json` preserving existing keys and `0600` permissions (only run after explicit user confirmation) |

## Supported `config.json` Fields & Symbols

Location: `${XDG_CONFIG_HOME:-~/.config}/statusline-hud/config.json` (hot-reloads on the next CLI status refresh; no restart needed).

| Row | Switches in display order | Notes |
| --- | --- | --- |
| 1 | `showMode`, `showModel`, `showContext`, `showPath`, `showGit` | Core status (`● READY`, `⚙ WORKING`, `⚠ CONFIRM (+N)`, etc.) always starts row 1; `showMode` covers `PLAN`/`EDITS`/`AUTO` + Vim `[N]`/`[I]`/`[V]`/`[VL]` |
| 2 | `showGeminiQuota`, `show3pQuota` | Gemini and third-party 5h / weekly quota buckets |
| 3 | `showArtifacts`, `showSubagents`, `showTasks`, `showSandbox`, `showTokens`, `showTokenSpeed`, `showCache`, `showDuration`, `showCost`, `showTitle` | `showSubagents` shows `running/total`; `showTokens`, `showCache`, and `showCost` cover the full session including subagents; `showTokenSpeed` shows `<N> tok/s` for the main agent's current turn; `showDuration` shows elapsed time from transcript; `showTitle` appends `▸ <title>` |

- All switches are booleans defaulting to `true`.
- Enabled count and state items (`showContext`, `showArtifacts`, `showSubagents`, `showTasks`, `showSandbox`, `showTokens`, `showTokenSpeed`, `showDuration`) show `0`, `0.0%`, `0 tok/s`, `0m`, or `OFF` even when omitted by the CLI; disabled items, items with no value (such as an untitled session, non-Git path, or unreported quota/cache/cost), and empty rows are omitted.
- Below 100 columns (`terminal_width < 100`), explicit `narrow` booleans override ordinary switches; missing keys inherit. Short forms (no progress bars or reset times, `wk`, 1-level path, branch without git details, token total only) save space without dropping selected items. The full model name (`model.display_name`, falling back to `model.id`) is preserved at every width. Long rows may wrap.
- **Symbols**: Git `[...]` status flags (`=` conflicted, `+` staged, `!` modified, `✘` deleted, `»` renamed, `?` untracked, `$` stashed, `↑N`/`↓N` ahead/behind) + `(+N −M)` tracked diff lines (`*` on narrow panes); Quota shows used % (green `<60%`, yellow `60–89%`, red `>=90%`) or `<N> left`; Tokens show `tok <total> (<in>↑ <out>↓)` followed by `<N> tok/s`; Model in Orchestrator mode shows `Orchestrator: <planner> → <executor>` from `~/.gemini/antigravity-cli/settings.json` (last saved selection, falling back to the payload model name).

## Workflow

### Step 1: Always start with `doctor`

Run `<skill-dir>/scripts/hud.sh doctor` first so you have ground-truth status for `jq`, script permissions, `settings.json`, `config.json` validity, and every effective setting.

Note: In sandboxed modes (including default `Auto` on `agy >= 1.5.10` and `--sandbox`), reading or writing `~/.config/statusline-hud/config.json` and `~/.gemini/antigravity-cli/settings.json` may be blocked or hidden even while `statusline.sh` itself reads them normally on the host. Whenever a `hud.sh` command is blocked, `doctor` reports `inaccessible`, or `doctor` shows `not found` / `not present` despite the user expecting existing config, explain that terminal sandbox isolation may be hiding host files and output the exact ready-to-run `<skill-dir>/scripts/hud.sh ...` command for the user to paste.

### Step 2: Handle user intent

#### A. Open-ended `/hud` or "help me configure HUD"
1. Lead with activation status in the user's language: if the environment is ready but HUD is not enabled, put the exact activation command from `doctor` on the next line. If another command is configured, warn before suggesting a switch. If HUD is enabled, say so without setup instructions; if checks failed, explain the blocker first.
2. Show the current sample from `scripts/hud.sh preview <width>` (120 by default, 80 for split panes). Ask one question: **Keep current layout / Adjust modules**. Use `ask_question` if available, otherwise ask in chat.
   - **Keep, skip or cancel**: stop without writing anything.
   - **Adjust modules**: show ordinary and narrow states from `doctor`; ask which to **toggle** (or **unset** narrow overrides back to `inherit`), not which should be enabled. Use plain keys for ordinary changes and `narrow.showX` for split-pane overrides. Selecting none makes no change. Preview at the corresponding width.

#### B. Initialize / Setup (`/hud setup`, "initialize HUD", "enable statusline")
1. From `doctor` output, verify `jq` is installed and `statusline.sh` is executable. If `jq` is missing, give the install command first. If `statusline.sh` is missing `+x`, run `chmod +x` (or provide the command if read-only).
2. Check `settings.json`:
   - If already active and enabled, confirm it is ready and offer to preview or customize.
   - If HUD is the configured command but `statusLine.enabled` is `false`, tell the user to run `/statusline enable`.
   - If `statusLine` points to another custom script, point it out clearly before switching.
   - If not active yet, present the two clean options (using `ask_question` if helpful):
     1. **(Recommended — instant hot reload)**: User runs `/statusline <tilde-path>` directly inside Antigravity CLI.
     2. **Auto-write `settings.json`**: If the user confirms, run `<skill-dir>/scripts/hud.sh apply-settings` (preserves other settings and `0600` permissions) and remind them to run `/statusline enable` or restart `agy` if it does not refresh immediately.
3. Offer to run a quick interactive configuration or keep defaults.

#### C. Modify config via natural language (e.g. "hide/show cost in split panes")
1. Map hide/show requests to `set` (`<skill-dir>/scripts/hud.sh set narrow.showCost=false` or `set narrow.showCost=true`). Use ordinary keys for all widths unless the user specifies a narrow override; use `toggle` for an explicit flip, and `unset` to remove overrides and restore defaults or narrow `inherit` (e.g. `unset narrow.showCost` or `unset narrow`).
2. Because `~/.config/statusline-hud/config.json` is outside the workspace, follow the sandbox fallback in Step 1 if blocked.
3. Re-run `<skill-dir>/scripts/hud.sh preview <width>` (80 for narrow changes, otherwise 120) to show the updated layout and confirm it hot-reloads automatically without restarting `agy`.

#### D. Validate, Debug & Troubleshoot (`/hud check`, `/hud doctor`, "statusline not working")
1. Present all findings from `scripts/hud.sh doctor` (missing `jq`, non-executable script, `settings.json` mismatch / `enabled: false` / `stack_with_default: true` / `inaccessible`, invalid JSON or unknown keys/types in `config.json`, failed smoke test).
2. Fix config issues after confirmation: `set` fixes wrong boolean types, `unset narrow` fixes a non-object `narrow`, and `reset` recovers invalid JSON or clears legacy unknown keys.
3. Remind the user that Antigravity CLI disables a statusline after 30 consecutive failures (`⚠ Statusline disabled after 30 consecutive failures.`), recoverable via `/statusline enable` (or `/statusline delete` to revert).
4. For deeper debugging:
   - Run the script directly with a sample payload to inspect raw output and exit status: `printf '{"agent_state":"working","terminal_width":120}' | <statusline-path>`.
   - Runtime caches live under `${XDG_CACHE_HOME:-~/.cache}/statusline-hud/` (`git/` has a 2-second TTL; `transcript/` is keyed by `mtime + size`). If Git status or session token/duration stats look stale, clearing that cache directory forces a fresh read.

#### E. Migrate from v0.1.x Config
If `doctor` warns about removed keys from v0.1.x (`preset`, `showQuota`, `showActivity`, `showSandboxOff`), explain the v0.2.0 equivalents and offer to migrate (note: `set` preserves unknown keys and `unset` only accepts current keys, so migrating cleanly means `reset` followed by `set ...`, or manually deleting the legacy keys from `config.json`):
- `showQuota: false` → `showGeminiQuota=false show3pQuota=false`
- `showActivity: false` → `showArtifacts=false showSubagents=false showTasks=false`
- `preset: "minimal"` → disable row 2 and row 3 switches (`showGeminiQuota=false show3pQuota=false showArtifacts=false showSubagents=false showTasks=false showSandbox=false showTokens=false showTokenSpeed=false showCache=false showDuration=false showCost=false showTitle=false`)
- `preset: "compact"` → no separate wide no-bars preset in v0.2.0; compact forms apply automatically below 100 columns
- `showSandboxOff: false` → `OFF` is shown whenever `showSandbox` is on; set `showSandbox=false` (or `narrow.showSandbox=false`) to hide it

#### F. Extend / Customize Beyond `config.json`
- Prefer `config.json` for all visibility and narrow-pane overrides so plugin upgrades remain conflict-free.
- If the user wants script-level customization (custom colors, changing the 100-column breakpoint, custom labels, or displaying extra Antigravity CLI payload fields such as `plan_tier`, `email`, or `agent.name`), advise **against** editing `scripts/statusline.sh` inside the plugin directory (future `agy plugin install` updates overwrite it). Instead, copy `scripts/statusline.sh` to a standalone path such as `~/.gemini/antigravity-cli/statusline.sh`, switch with `/statusline ~/.gemini/antigravity-cli/statusline.sh`, and modify that copy.

#### G. Reset (`/hud reset`)
1. Run `<skill-dir>/scripts/hud.sh reset` (or provide the command if outside-workspace deletion is blocked).
2. Re-run `<skill-dir>/scripts/hud.sh preview 120` to verify default output.

#### H. Uninstall (`/hud uninstall`)
Remind the user to revert `statusLine` **before** removing the plugin files, otherwise Antigravity CLI will fail running the missing script until disabled after 30 failures:
1. Run `/statusline delete` inside Antigravity CLI.
2. Run `agy plugin uninstall statusline-hud` in the shell (and optionally remove `~/.config/statusline-hud/` and `~/.cache/statusline-hud/`).
