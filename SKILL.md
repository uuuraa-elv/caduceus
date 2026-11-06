---
name: caduceus
description: Delegate a routine coding task to Hermes Agent in an isolated git worktree, then review its work. Use when the user says "use Hermes", "send this to Hermes", "delegate to Hermes", or when Claude usage is running low and the task is routine coding that has tests. Do not use for design work, debugging across many files, repos without tests, or HyperFrames videos.
---

# Caduceus: Claude plans and reviews, Hermes does the work

Script: `caduceus.ps1` next to this file (PowerShell 7, Windows). There is no live link between the two agents. You write a task file, the script runs `hermes chat` inside a git worktree at `<repo parent>\_hermes-wt\<repo>-<name>` on branch `hermes/<name>`, and the work comes back as commits, `RESULT.md` and a JSONL log.

## Good fit or not

| Task | Choice |
|---|---|
| Routine coding with tests (write tests, patterned CRUD, mechanical refactors) | Hermes |
| Remotion video draft when Claude usage is low | Hermes with `-Toolset video` |
| HyperFrames video, UI design, debugging across many files, repo without tests, anything needing browser/MCP/judgment | Do it yourself |

## Steps

1. **Write TASK.md** outside the repo: goal, context (Hermes cannot see this conversation, memory or CLAUDE.md), which files it may touch, and "done when" with the exact check command. 15 to 30 lines is plenty.
2. **Run it in the background** and wait for the completion notice only. Do not watch it step by step: every notification you answer is a full turn of your own context, and a dozen of them cost more than the work you delegated.
   ```powershell
   pwsh -NoProfile -File "<skill dir>\caduceus.ps1" -Repo <repo> -Task <TASK.md> -Name <slug> -Test "<test command>" [-Toolset coding|video|full] [-Model "a,b"] [-TimeoutMin 30]
   ```
   Several tasks at once: wrap them in ONE background command (Start-Process each, then Wait-Process) so you get one notification.
3. **Review**: read the report (commits, diff stat, test result, RESULT.md), then read the diff yourself and run the tests. Do not trust "done" without the diff.
4. **Revise** (two rounds at most):
   - Small fixes (comments, names, typos): do them yourself, it is cheaper.
   - Logic fixes: `-Name <slug> -Revise "<what is wrong>"` without `-Resume`. This starts a fresh session with the original task, recent commits, changed files and your notes.
   - `-Resume <session_id>` only when the old session's context truly matters: it resends the whole history.
5. **Finish**: drop `RESULT.md` before merging, merge the way the repo expects (ask the user before pushing), then `git worktree remove` and `git branch -d hermes/<slug>`.

## What the script handles

- Tries each model in `-Model` (or the config list) with a short ping first and skips the ones that fail. If the provider fails mid-task (credits, auth, connection), it continues once on the next model in the same worktree.
- `-Toolset coding` loads only terminal, file and todo tools, which roughly halves input tokens per step.
- Waits for free RAM before starting and cleans up orphaned headless browsers and Hermes helper processes.
- Commits anything Hermes left uncommitted, so nothing is lost.
- Prints a fit warning when the task text matches a rule in the config.
- Enforces the time limit and kills the whole process tree.
