#!/bin/sh
set -eu

AUTO_YES=0
SORT_MODE="alpha"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

usage() {
  cat <<'EOF'
git-branch-tui.sh - interactive local branch manager (git + fzf)

Usage:
  git-branch-tui.sh [-y] [-s alpha|age|merged] [-h]

Options:
  -y        Auto-confirm safe delete for key 'x' (merged into base branch).
  -s MODE   Initial sort mode: alpha (default), age (oldest first), or merged.
  --sort=MODE
  -h        Show this help text and exit.

Keys inside TUI:
  j / k     Move down/up
  Ctrl-D/U  Half-page down/up
  x         Delete selected branch if merged into base (asks confirmation unless -y)
  X         Force delete selected branch (always asks confirmation)
  s         Toggle sorting: alpha -> age -> merged -> alpha
  r         Refresh list
  Enter     Exit and print selected branch name

Merge status is computed against base branch (main/master auto-detected).
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y) AUTO_YES=1 ;;
      -s)
        [ $# -ge 2 ] || die "Missing value for -s (use alpha or age)"
        case "$2" in
          alpha | age | merged) SORT_MODE=$2 ;;
          *) die "Invalid sort mode: $2 (use alpha, age, or merged)" ;;
        esac
        shift
        ;;
      --sort=*)
        mode=${1#--sort=}
        case "$mode" in
          alpha | age | merged) SORT_MODE=$mode ;;
          *) die "Invalid sort mode: $mode (use alpha, age, or merged)" ;;
        esac
        ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (use -h for help)" ;;
    esac
    shift
  done
}

pick_base_branch() {
  if git show-ref --verify --quiet refs/heads/main; then
    printf '%s\n' "main"
    return 0
  fi

  if git show-ref --verify --quiet refs/heads/master; then
    printf '%s\n' "master"
    return 0
  fi

  remote_head=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  remote_head=${remote_head#origin/}
  if [ -n "$remote_head" ] && git show-ref --verify --quiet "refs/heads/$remote_head"; then
    printf '%s\n' "$remote_head"
    return 0
  fi

  current=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
  [ -n "$current" ] || die "Could not determine base branch (main/master not found)."
  printf '%s\n' "$current"
}

build_rows() {
  base_branch=$1
  sort_mode=$2
  now_epoch=$(date +%s 2>/dev/null || printf '%s\n' 0)
  current_branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || printf '%s\n' "(detached)")
  rows_tmp=$(mktemp "${TMPDIR:-/tmp}/git-branch-tui.rows.XXXXXX")
  trap 'rm -f "$rows_tmp"' EXIT INT HUP TERM

  printf 'CUR\tMERGED\tAGE(d)\tBRANCH\n'
  git for-each-ref --format='%(refname:short)%09%(committerdate:unix)' refs/heads | while IFS='	' read -r b ts; do
    [ -n "$b" ] || continue

    cur_mark=" "
    [ "$b" = "$current_branch" ] && cur_mark="*"

    merged="no"
    if git merge-base --is-ancestor "$b" "$base_branch" >/dev/null 2>&1; then
      merged="yes"
    fi

    if [ "$b" = "$base_branch" ]; then
      merged="base"
    fi

    [ -n "${ts:-}" ] || ts=0
    age_days=0
    if [ "$now_epoch" -ge "$ts" ] 2>/dev/null; then
      age_days=$(( (now_epoch - ts) / 86400 ))
    fi

    printf '%s\t%s\t%s\t%s\n' "$cur_mark" "$merged" "$age_days" "$b" >>"$rows_tmp"
  done

  case "$sort_mode" in
    alpha)
      LC_ALL=C sort -t '	' -k4,4 "$rows_tmp"
      ;;
    age)
      LC_ALL=C sort -t '	' -k3,3n -k4,4 "$rows_tmp"
      ;;
    merged)
      awk -F '	' 'BEGIN{OFS="\t"}{
        rank=2
        if ($2=="base") rank=0
        else if ($2=="yes") rank=1
        print rank, $0
      }' "$rows_tmp" | LC_ALL=C sort -t '	' -k1,1n -k5,5 | cut -f2-
      ;;
    *)
      LC_ALL=C sort -t '	' -k4,4 "$rows_tmp"
      ;;
  esac
}

fzf_select() {
  base_branch=$1
  sort_mode=$2
  build_rows "$base_branch" "$sort_mode" | fzf \
    --header "Base: $base_branch | Sort: $sort_mode | Enter: exit | x: delete if merged into base | X: force delete | s: toggle sort | r: refresh | j/k, Ctrl-U/Ctrl-D: vim navigation" \
    --header-lines=1 \
    --delimiter='\t' \
    --with-nth=1,2,3,4 \
    --expect=enter,x,X,s,r \
    --preview 'branch=$(printf "%s" {} | cut -f4); [ -n "$branch" ] && git log --color=always --graph --decorate --oneline -n 20 "$branch"' \
    --preview-window='right,65%,wrap' \
    --bind 'j:down,k:up,ctrl-u:half-page-up,ctrl-d:half-page-down,home:first,end:last'
}

confirm() {
  prompt=$1
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

delete_branch() {
  branch=$1
  mode=$2
  merged_state=$3
  base_branch=$4

  current_branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)

  [ "$branch" != "$base_branch" ] || {
    printf 'Refusing to delete base branch: %s\n' "$branch"
    return 0
  }

  [ "$branch" != "$current_branch" ] || {
    printf 'Refusing to delete checked out branch: %s\n' "$branch"
    return 0
  }

  if [ "$mode" = "force" ]; then
    if confirm "Force delete '$branch' (-D)? [y/N] "; then
      git branch -D -- "$branch"
    fi
    return 0
  fi

  if [ "$merged_state" = "yes" ]; then
    if [ "$AUTO_YES" -ne 1 ]; then
      if ! confirm "Delete '$branch' (merged into '$base_branch')? [y/N] "; then
        return 0
      fi
    fi
    # Safe by this tool's rule: branch tip is ancestor of base branch.
    git branch -D -- "$branch"
    return 0
  fi

  printf "Branch '%s' is not merged into '%s'.\n" "$branch" "$base_branch"
  if confirm "Delete anyway with -D? [y/N] "; then
    git branch -D -- "$branch"
  fi
}

main() {
  parse_args "$@"

  need_cmd git
  need_cmd fzf

  git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside a git repository."
  base_branch=$(pick_base_branch)

  while :; do
    selection=$(fzf_select "$base_branch" "$SORT_MODE") || exit 0
    key=$(printf '%s\n' "$selection" | sed -n '1p')
    line=$(printf '%s\n' "$selection" | sed -n '2p')

    [ -n "$line" ] || continue

    branch=$(printf '%s\n' "$line" | cut -f4)
    merged_state=$(printf '%s\n' "$line" | cut -f2)

    case "$key" in
      x) delete_branch "$branch" safe "$merged_state" "$base_branch" ;;
      X) delete_branch "$branch" force "$merged_state" "$base_branch" ;;
      s)
        if [ "$SORT_MODE" = "alpha" ]; then
          SORT_MODE="age"
        elif [ "$SORT_MODE" = "age" ]; then
          SORT_MODE="merged"
        else
          SORT_MODE="alpha"
        fi
        continue
        ;;
      r) continue ;;
      enter) printf '%s\n' "$branch"; exit 0 ;;
      *) continue ;;
    esac
  done
}

main "$@"
