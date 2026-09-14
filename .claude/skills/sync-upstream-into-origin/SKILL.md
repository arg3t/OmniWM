---
name: sync-upstream-into-origin
description: Syncs an upstream Git branch into the matching origin branch while it keeps local and remote commits. Use when a fork diverges, when origin must match upstream, or when a user asks to merge upstream into origin.
user-invocable: true
---

# Sync Upstream Into Origin

Use this skill to merge the upstream branch into the origin branch without loss of commits.

## Capabilities

- Preserve commits from the local branch, origin, and upstream.
- Merge divergent histories without rebase or force-push.
- Verify that origin contains every upstream commit.

## Workflow

1. Run `git status --short --branch` and `git remote -v`.
2. Stop if the worktree has changes or an operation is in progress.
3. Ask the user to commit or stash worktree changes. Do not stash, reset, clean, or discard changes.
4. Fetch both remotes with `git fetch --prune origin` and `git fetch --prune upstream`.
5. Select the current local branch as the target branch.
6. Confirm that `origin/<branch>` and `upstream/<branch>` exist.
7. Compare each remote with the local branch by using `git rev-list --left-right --count <branch>...origin/<branch>` and `git rev-list --left-right --count <branch>...upstream/<branch>`.
8. Merge `origin/<branch>` into the local branch when it differs.
9. Merge `upstream/<branch>` into the local branch when it differs.
10. Resolve each conflict by keeping the behavior from both parents. Do not use a one-side checkout unless the other side has an equivalent replacement.
11. Run the smallest project check that covers the changed code.
12. Push the merged branch with `git push origin HEAD:refs/heads/<branch>`.
13. Confirm that `git merge-base --is-ancestor upstream/<branch> origin/<branch>` succeeds.

## Rules

- Use merge commits. Do not rebase or force-push.
- Preserve local commits, origin-only commits, and upstream-only commits.
- Stop on a merge conflict until the conflict has a semantic resolution.
- Stop if the push fails because the branch has protection or the remote changes again.
- Report the branch, merge commits, conflicts, check result, and final ancestry check.

## Examples

### Merge a fork main branch

User says: "Sync upstream into origin and keep both histories."

Fetch both remotes, merge `origin/main` and `upstream/main` into the local `main` branch as needed, run the focused check, then push to `origin/main`.

### Handle a remote-only origin commit

User says: "Bring upstream main into my fork."

Merge `origin/main` before `upstream/main`. This keeps a commit that exists only in the fork before the final push.
