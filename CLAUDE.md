# CLAUDE.md

## What is this project?

Open Island is a native macOS companion app for AI coding agents. It sits in the notch/top-bar area and monitors local agent sessions, surfaces permission requests, answers questions, and provides "jump back" to the correct terminal context. Local-first, no server dependency.

## References

- **Target product**: https://vibeisland.app/ — the commercial product we are building toward feature parity with
- **Reference OSS repo**: https://github.com/farouqaldori/claude-island — open-source implementation we can study for design patterns and ideas

## Architecture

Four targets in one Swift package (`OpenIsland`):

1. **OpenIslandApp** — SwiftUI + AppKit shell. Menu bar extra, overlay panel (notch/top-bar), and control center window. Entry point: `OpenIslandApp.swift` with `AppModel` as the central `@Observable` state owner.
2. **OpenIslandCore** — Shared library. Models (`AgentSession`, `AgentEvent`, `SessionState`), bridge transport (Unix socket IPC with JSON line protocol), hook models/installers for both Codex and Claude Code, transcript discovery, session persistence/registry.
3. **OpenIslandHooks** — Lightweight CLI executable invoked by agent hooks. Reads hook payload from stdin, forwards to app bridge via Unix socket, writes blocking JSON to stdout only when island denies a `PreToolUse`.
4. **OpenIslandSetup** — Installer CLI for managing `~/.codex/config.toml` and `hooks.json`.

## Key data flow

### Codex path
Codex → hooks.json → OpenIslandHooks (stdin/stdout) → Unix socket → DemoBridgeServer → AppModel → UI

### Claude Code path
Claude Code → settings.json hooks → OpenIslandHooks (stdin/stdout) → Unix socket → DemoBridgeServer.handleClaudeHook → AppModel → UI

### Session discovery (on launch)
Restore cached sessions from registry → discover recent JSONL transcripts (`~/.claude/projects/`) → reconcile with active terminal processes → start live bridge.

## Supported scope (narrow by design)

- **Agents**: Codex (fully wired), Claude Code (hook-based integration)
- **Terminals**: Terminal.app, Ghostty
- Do NOT expand scope unless explicitly asked

## Build & test

```bash
swift build
swift test
swift run OpenIslandApp                            # run the app
swift build -c release --product OpenIslandHooks   # build hook binary
```

Open `Package.swift` in Xcode for the app target. Requires macOS 14+, Swift 6.2.

## Required Workflow — MANDATORY

> **⚠️ CRITICAL: NEVER edit files directly in the main worktree. ALL code changes MUST be made inside a worktree-isolated Agent.**

When the user requests any task that involves file modifications, **the very first step** MUST be spawning an isolated Agent:

```
Agent(
  subagent_type: "general-purpose",
  isolation: "worktree",
  prompt: "task description...",
  description: "short summary"
)
```

### Allowed in main conversation (main worktree):
- Read files (Read, Grep, Glob)
- Run read-only git commands (git status, git log, git diff)
- Research and planning (no file mutations)
- Spawn Agent sub-tasks

### FORBIDDEN in main conversation:
- Using Edit / Write tools to modify any source file
- Running `git commit`, `git checkout -b`, or any write operations
- Creating branches or commits directly in the main worktree

### Workflow inside the worktree Agent:
1. Check repository state with `git status -sb`
2. Confirm you are on the correct feature branch (worktree Agent auto-creates a branch)
3. Read relevant files before editing — do not guess
4. Keep each round focused on a single coherent change
5. Run the most relevant verification after changes (`swift build`, `swift test`, etc.)
6. Summarize what changed
7. Commit and push to remote

### After Agent completes:
Create a PR from the main conversation to merge the branch into main.

## Commit Policy

- Every round that modifies files must end with a commit.
- Do not batch unrelated changes into one commit.
- Use conventional-style commit messages: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
- Do not amend existing commits unless explicitly requested.
- Create a feature branch (e.g. `fix/<topic>`, `feat/<topic>`) for every independent change. Do not commit directly to `main`.

## Safety Rules

- Never revert or overwrite user changes unless explicitly requested.
- If unexpected changes appear, inspect them and work around them when possible.
- If a conflict makes the task ambiguous or risky, stop and ask before proceeding.
- Never use destructive Git commands such as `git reset --hard` without explicit approval.

## Branching Rules

- `main` is a protected branch (GitHub branch protection enabled). **NEVER commit or push directly to `main`.**
- All changes MUST go through a Pull Request to merge into `main`. Direct pushes are rejected.
- All feature branches must be created from the latest local `main`.
- **You MUST use the Agent tool with `isolation: "worktree"`** for all development work. This is NOT optional — it is a hard requirement.
- Each agent or workstream should work on its own branch, named to match the topic (e.g. `feat/<topic>`, `fix/<topic>`).
- Standard flow: **Agent(worktree) develop → push → create PR → review/merge**.

## App Targets And Naming

- `OpenIslandApp` (via `swift run OpenIslandApp` or the Xcode target) is the canonical development runtime.
- `~/Applications/Open Island Dev.app` is a local bundle wrapper around the repo-built binary, not a separate product.
- When launching `Open Island Dev.app`, refresh the bundle first with `zsh scripts/launch-dev-app.sh` instead of only `open -na` (avoids stale binaries).
- Use `scripts/harness.sh smoke` or `scripts/smoke-dev-app.sh` only for deterministic harness runs.
- `/Applications/Vibe Island.app` and `https://vibeisland.app/` are closed-source reference baselines only — behavior benchmarks, not the development runtime.

## Reference Baselines

- Official product reference: `https://vibeisland.app/`
- On Macs with a built-in notch, the island sits in the notch area; on external displays or non-notch Macs, it falls back to a compact top-center bar.
- Community reference: `https://github.com/farouqaldori/claude-island` — useful for design patterns, not a product spec.
- Do NOT import from `claude-island` unless explicitly asked: analytics (Mixpanel etc.), window-manager scope (`tmux`, `yabai`), Claude-only assumptions that weaken the shared agent model.

## Conventions

- Prefer small end-to-end slices over speculative scaffolding
- Native macOS APIs over cross-platform abstractions
- Hooks fail open — if app/bridge unavailable, agents keep running unchanged
- The `SessionState.apply(_:)` reducer is the single source of truth for session mutations
- Bridge protocol uses newline-delimited JSON envelopes (`BridgeCodec`)
- All models are `Sendable` and `Codable`

## Verification

- Run targeted checks that match the change (`swift build`, `swift test`, or manual verification).
- If no automated verification exists yet, state that explicitly in the summary and still commit.

## Important files

- `Sources/OpenIslandApp/AppModel.swift` — Central app state, session management, bridge lifecycle
- `Sources/OpenIslandApp/TerminalSessionAttachmentProbe.swift` — Ghostty/Terminal attachment matching
- `Sources/OpenIslandApp/ActiveAgentProcessDiscovery.swift` — Process discovery via ps/lsof
- `Sources/OpenIslandCore/SessionState.swift` — Pure state reducer for agent sessions
- `Sources/OpenIslandCore/AgentSession.swift` — Core session model and related types
- `Sources/OpenIslandCore/AgentEvent.swift` — Event enum driving all state transitions
- `Sources/OpenIslandCore/BridgeTransport.swift` — Unix socket protocol, codec, envelope types
- `Sources/OpenIslandCore/DemoBridgeServer.swift` — Bridge server handling hook payloads
- `Sources/OpenIslandCore/ClaudeHooks.swift` — Claude Code hook payload model and terminal detection
- `Sources/OpenIslandCore/ClaudeTranscriptDiscovery.swift` — Discovers sessions from `~/.claude/projects/` JSONL files
- `Sources/OpenIslandCore/ClaudeSessionRegistry.swift` — Persists/restores Claude sessions across app launches
- `Sources/OpenIslandCore/CodexHooks.swift` — Codex hook payload model
- `Sources/OpenIslandHooks/main.swift` — Hook CLI entry point
- `Sources/OpenIslandApp/OverlayPanelController.swift` — Notch/top-bar overlay window
- `docs/product.md` — Product scope and MVP boundary
- `docs/architecture.md` — System design and engineering decisions
- `AGENTS.md` — Working agreement for agent workflow
