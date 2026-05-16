# Git Safety

## Rule
**Never** run git commands that modify repository history or remote state.

## Blocked Commands
These git operations are **prohibited** — do not attempt them:
- `git add` — staging changes
- `git commit` — creating commits
- `git push` — pushing to remote
- `git merge` — merging branches
- `git rebase` — rebasing branches
- `git reset` — resetting HEAD
- `git stash` — stashing changes
- `git checkout -b` — creating branches
- `git branch -d` / `git branch -D` — deleting branches
- `git tag` — creating or deleting tags
- `git cherry-pick` — applying commits from other branches
- `git revert` — creating revert commits

## Allowed Commands
These read-only git operations are safe and encouraged:
- `git status` — check working tree state
- `git diff` — view changes
- `git log` — view commit history
- `git show` — inspect commits
- `git blame` — view line-level attribution
- `git branch` (no flags) — list branches
- `git remote -v` — list remotes
- `git stash list` — list stashes (read-only)
- `git checkout <file>` — restore a file to HEAD state (safe — only undoes local edits)

## Why
The human controls all version control operations. AI assistants analyze code and suggest
changes but never push, commit, or modify git history. This prevents:
- Accidental commits of incomplete or incorrect code
- Force-pushes that could lose work
- Branch/tag operations that affect team collaboration
- Merge conflicts created without human review
