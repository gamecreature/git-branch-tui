# git-branch-tui

Interactive `git` branch browser + cleanup TUI for local branches, powered by `fzf`.

## What It Does

- Lists all local branches.
- Shows:
  - current branch marker (`*`)
  - merge state vs base branch (`base`, `yes`, `no`)
  - age in days (`AGE(d)`)
- Lets you delete branches from the TUI:
  - `x` safe workflow (merged-into-base check)
  - `X` force delete with confirmation
- Supports Vim-style navigation keys.
- Supports sort modes: `alpha`, `age`, `merged`.

Base branch is auto-detected as:
1. `main`
2. `master`
3. `origin/HEAD` target (if local branch exists)
4. current checked out branch (fallback)

## Requirements

- POSIX `sh`
- `git`
- `fzf`
- Standard Unix tools: `sort`, `awk`, `cut`, `sed`, `date`

This script is written to run on FreeBSD (and other Unix-like systems).

## Usage

```sh
./git-branch-tui.sh
```

Options:

- `-y` auto-confirm `x` safe deletes
- `-s alpha|age|merged` set initial sort mode
- `--sort=alpha|age|merged` same as above
- `-h` or `--help` show help

Examples:

```sh
./git-branch-tui.sh -s age
./git-branch-tui.sh --sort=merged -y
```

## TUI Keys

- `j` / `k`: move down/up
- `Ctrl-D` / `Ctrl-U`: half-page down/up
- `s`: toggle sort (`alpha -> age -> merged -> alpha`)
- `r`: refresh list
- `x`: delete selected branch if merged into base (confirm, unless `-y`)
- `X`: force delete selected branch (always confirms)
- `Enter`: exit and print selected branch name

## Merge Semantics

`x` uses merge ancestry against the detected base branch:
- branch is safe for `x` when `git merge-base --is-ancestor <branch> <base>` succeeds.

This avoids upstream-related false negatives from `git branch -d` in some branch tracking setups.

## Attribution

This script and repository structure were created by Codex (GPT-5) for @gamecreature.

## License

MIT. See [LICENSE](./LICENSE).
