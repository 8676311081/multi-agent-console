# open-vibe-island

> 我不想在自己的电脑上运行一个闭源、付费的软件来监视我所有的生产过程。<br>
> 所以我 build 了这个开源的版本。<br>
>
> To all vibe coders: 我们自己构建自己的产品。

The open-source macOS companion for terminal-native AI coding.

`open-vibe-island` puts a lightweight control surface in your notch or top bar so you can keep an eye on live coding agents, handle approvals, answer questions, and jump back to the right terminal without breaking flow.

## Why This Product Exists

AI coding is becoming part of the daily development loop, but the surrounding control layer still too often means handing your machine over to a closed-source paid app.

`open-vibe-island` takes the opposite approach:

- open source
- local first
- native on macOS
- built to support the terminal workflow, not replace it

## Who It Is For

This is for developers who already live in the terminal and want a better way to work with coding agents on macOS without losing context.

## What You Get

- a small native island for live agent activity
- fast visibility into approvals and questions
- quicker return to the active terminal context
- a companion experience that stays out of the way until it matters

## Current Product Shape

Right now `open-vibe-island` is focused on one thing: making the Codex-on-macOS workflow feel more native.

Current scope:

- macOS only
- Codex first
- live session visibility
- approval flow
- jump-back behavior

## Available Today

Today the project can already:

- receive Codex hook events locally
- surface session and approval state in the app
- install and uninstall managed Codex hooks from `~/.codex`
- use terminal hints for best-effort jump back behavior

## Quick Start

Build and run locally:

```bash
swift test
swift build
open Package.swift
```

Connect Codex:

```toml
[features]
codex_hooks = true
```

```bash
swift build -c release --product VibeIslandHooks
swift run VibeIslandSetup install --hooks-binary "$(pwd)/.build/release/VibeIslandHooks"
```

Check or remove the setup later:

```bash
swift run VibeIslandSetup status --hooks-binary "$(pwd)/.build/release/VibeIslandHooks"
swift run VibeIslandSetup uninstall
```

## Product Direction

The goal is simple: make AI coding feel native on macOS.

That means:

- less context switching
- less tab hunting
- less friction around approvals
- a faster path back to the active agent session

## Roadmap

1. Ship a solid single-agent macOS MVP
2. Harden approvals and jump-back behavior
3. Improve multi-session handling
4. Expand to more agent integrations over time

## Contributing

Issues and pull requests are welcome. Small focused changes are preferred.
