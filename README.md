# Caduceus

**Let Claude Code hand routine coding work to [Hermes Agent](https://github.com/NousResearch/hermes-agent), then review what comes back.**

Claude writes the task and checks the result. Hermes does the typing on a much cheaper model, inside its own git worktree, so your working copy is never touched.

[Bahasa Indonesia](README.id.md)

## Results

Measured in November 2026 with Claude Opus 5.5 as the planner and reviewer, and Hermes running DeepSeek V4.1 Flash.

| What we measured | Claude alone | Claude + Caduceus + Hermes |
|---|---|---|
| Real coding tasks from a production TypeScript app passing review | 4 / 4 | **4 / 4** |
| Mutants caught by the tests written (33 non-equivalent mutants) | 32 / 33 | **33 / 33** |
| Claude usage per task (API-equivalent) | ~$1.35 | **~$0.24 (about 82% less)** |
| Model cost on the Hermes side, per task | | **~$0.06** |

What the bridge itself saves:

| Optimization | Before | After |
|---|---|---|
| Input tokens per Hermes step, coding toolset | 18,272 | **8,823 (52% less)** |
| Tokens for one revision round | 0.9 to 7 million (resuming the old session) | **~42,000 (fresh, summarized session)** |

For video, a Remotion draft made by Hermes alone scored **29 / 35** in a blind review, against 31 / 35 for Claude alone.

These come from a small set of tasks on one project. Your numbers will differ with your codebase, models and prices.

## How it works

```
Claude Code ── writes TASK.md ──> caduceus.ps1 ── runs ──> hermes chat (in a git worktree)
     ^                                                             │
     └──── reads commits, diff, test result, RESULT.md <───────────┘
```

1. Claude writes a short task file: goal, context, files allowed, and the check that proves it is done.
2. Caduceus pings your models, creates a worktree on branch `hermes/<name>`, and starts Hermes with only the tools the task needs.
3. While Hermes works, Caduceus enforces a time limit, keeps an eye on free RAM, and logs every step.
4. When Hermes stops, Caduceus commits anything left uncommitted, runs your test command, and prints a report.
5. Claude reviews the diff. If something is wrong, it sends a revision as a fresh, short session instead of replaying the whole history.

## Requirements

- Windows 10 or 11 with PowerShell 7 (`pwsh`)
- git
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) configured with a model it can call through an OpenAI-compatible endpoint
- [Claude Code](https://claude.com/claude-code), if you want Claude to drive it (the script also runs on its own)

## Install

Clone it as a Claude Code skill:

```powershell
git clone https://github.com/uuuraa-elv/caduceus "$env:USERPROFILE\.claude\skills\caduceus"
```

Optional: copy `caduceus.config.example.json` to `caduceus.config.json` in the same folder and list your models in fallback order.

## Use

From Claude Code, just ask: *"Send this to Hermes: add input validation to the signup handler, tests in tests/signup.test.ts must pass."* The skill tells Claude how to write the task, run it, and review it.

By hand:

```powershell
# new task
pwsh -File caduceus.ps1 -Repo C:\code\app -Task C:\tmp\TASK.md -Name signup-validation -Test "npm test"

# revision as a fresh short session (cheap)
pwsh -File caduceus.ps1 -Repo C:\code\app -Name signup-validation -Revise "Empty email still passes, reject it."
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Repo` | required | The git repository to work on |
| `-Name` | required | Short name, used for the branch `hermes/<name>` and the worktree folder |
| `-Task` | | Task file for a new run |
| `-Revise` | | Revision notes for an existing worktree |
| `-Resume` | | Continue an old Hermes session (sends the full history, expensive) |
| `-Test` | | Command run in the worktree at the end |
| `-Toolset` | `coding` | `coding`, `video` or `full`, defined in the config |
| `-Model` | config list | Models to try, comma separated |
| `-TimeoutMin` | 30 | Hard time limit |
| `-MaxTurns` | 200 | Step limit passed to Hermes |
| `-Base` | remote default branch | Where the new branch starts |
| `-Config` | `caduceus.config.json` | Path to a config file |

## Configuration

Every key is optional. See `caduceus.config.example.json`.

| Key | Purpose |
|---|---|
| `models` | Fallback order. Empty means Hermes's own default model |
| `preflight` | Ping each model before starting |
| `endpoint`, `apiKeyEnv`, `readKeyFromHermesConfig` | Where the ping goes and which key it uses. By default the key is read from the env var `CADUCEUS_API_KEY`, then from Hermes's `config.yaml` |
| `toolsets` | Named tool lists passed to `hermes chat -t` |
| `ram` | Free-RAM gate before starting, cleanup threshold, and which leftover processes may be stopped |
| `router` | Port and start command of a local model router, started automatically if it is down |
| `fitRules` | Regex rules that print a warning when a task looks like a poor fit |

## When to do it in Claude instead

- UI design, debugging across many files, or repos without tests: writing the task takes as much thought as doing it.
- HyperFrames videos: in our tests they came out worst through Hermes.
- Anything urgent: Hermes on a cheap model took about 2.5 times longer per coding task.

## Tests

```powershell
pwsh -File tests/run-tests.ps1
```

Runs offline against a fake `hermes`, so no model is called.

## License

MIT. Copyright (c) 2026 Fuad Nurhadi ([fuadnurhadi.my.id](https://fuadnurhadi.my.id)).
