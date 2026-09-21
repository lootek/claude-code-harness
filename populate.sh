#!/usr/bin/env bash
# populate.sh — capture the live machine's public Claude Code artifacts back
# INTO this repo. Exact inverse of install.sh (which deploys repo -> ~/.claude).
#
# This box (~/.claude, ~/.zsh-aliases) is the source of truth for the PUBLIC
# layer: the ccc/ccr wrapper, the provider catalog, and the hooks. Run this,
# review `git diff`, then commit and push.
#
# Personal config is owned by the dotfiles repo and is NEVER captured here:
#     CLAUDE.md   settings.json   settings.local.json   statusline-command.sh
#     .zsh-aliases/{basic,fzf-utils,git,go,kubernetes,vault,creative,terraform}
#
# Policy (explicit allowlists; nothing is auto-discovered):
#   tools/        cc.py + providers.yaml
#   hooks/        7 hook files (safe_command.py + payload_guard.py + 5) and
#                 tests/ incl. the payload-guard fixtures
#   sh-aliases/   ai  (from ~/.zsh-aliases/ai)
#   plugins/      NOT captured — this repo is the source of truth. The live
#                 copies under ~/.claude/plugins/ are a marketplace clone OF
#                 this repo, so capturing them back would be circular.
# Excluded explicitly: .cc-venv/ (recreate via install.sh), backups/,
# safe_command_audit.jsonl, __pycache__/, .pytest_cache/, and ~/.secrets/.
#
# Because this repo is PUBLIC, the leak check below is stricter than the
# dotfiles one: it scans for secret values AND employer/internal identifiers.
#
# The internal-identifier patterns are NOT baked into this script — writing an
# employer name into a public repo is the very leak we are trying to prevent.
# They are read from a gitignored patterns file (one extended-regex per line,
# `#` comments allowed), by default `.leak-patterns.local` beside this script;
# override with CC_LEAK_PATTERNS_FILE. Same spirit as CC_CURL_POST_ALLOW: no
# site-specific values ship in the repo. A fresh clone has no such file and
# still runs the secret-value half of the check.
#
# Usage:
#   ./populate.sh            # capture, run hook tests, leak-check, show git status
#   ./populate.sh --dry-run  # print planned actions, copy nothing

set -euo pipefail

# --- destination (this repo) ---
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- live sources (this machine) ---
LIVE_CLAUDE="$HOME/.claude"
LIVE_ALIASES="$HOME/.zsh-aliases"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
skip() { printf '    \033[1;33mskip\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

run() { if $DRY_RUN; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# Copy a file into the repo, creating parent dirs. An existing destination
# keeps its current mode (cp does not reset the mode of a file that exists),
# so the repo's executable bits survive a capture.
cp_file() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || { skip "missing source: $src"; return 0; }
  if cmp -s "$src" "$dst" 2>/dev/null; then
    printf '    --   %s (unchanged)\n' "${dst#$REPO/}"
    return 0
  fi
  run "mkdir -p '$(dirname "$dst")'"
  run "cp '$src' '$dst'"
  printf '    ok   %s\n' "${dst#$REPO/}"
}

[[ -d "$REPO/.git" ]] || die "not a git repo: $REPO"
[[ -d "$LIVE_CLAUDE" ]] || die "no live ~/.claude at $LIVE_CLAUDE"

say "capturing public artifacts: $LIVE_CLAUDE -> $REPO"

# ── tools: ccc/ccr wrapper + provider catalog ─────────────────────────────
say "tools/  (cc.py, providers.yaml)"
cp_file "$LIVE_CLAUDE/tools/cc.py"          "$REPO/tools/cc.py"
cp_file "$LIVE_CLAUDE/tools/providers.yaml" "$REPO/tools/providers.yaml"

# ── hooks ─────────────────────────────────────────────────────────────────
# Same 6 files install.sh deploys, plus the test. Runtime artifacts
# (safe_command_audit.jsonl, __pycache__/) are deliberately left behind.
say "hooks/  (7 hooks + tests/)"
for f in log_commands.py prompt_history.py export_session.py \
         flush_stale_dumps.py safe_command.py payload_guard.py session-env-check.sh; do
  cp_file "$LIVE_CLAUDE/hooks/$f" "$REPO/hooks/$f"
done
cp_file "$LIVE_CLAUDE/hooks/tests/test_safe_command.py" "$REPO/hooks/tests/test_safe_command.py"
cp_file "$LIVE_CLAUDE/hooks/tests/test_payload_guard.py" "$REPO/hooks/tests/test_payload_guard.py"
mkdir -p "$REPO/hooks/tests/fixtures"
for f in "$LIVE_CLAUDE"/hooks/tests/fixtures/*; do
  cp_file "$f" "$REPO/hooks/tests/fixtures/$(basename "$f")"
done
skip "safe_command_audit.jsonl, __pycache__/, .pytest_cache/ (runtime artifacts)"

# ── shell alias ───────────────────────────────────────────────────────────
say "sh-aliases/  (ai -> ccc / ccr / ccprov)"
cp_file "$LIVE_ALIASES/ai" "$REPO/sh-aliases/ai"

# ── not captured, for the record ──────────────────────────────────────────
say "plugins/  (this repo is the source of truth; live copies are a marketplace clone of it)"
for p in imagine mr-monitor mr-review review-board; do skip "plugins/$p (edit in-repo)"; done
say "personal layer  (owned by the dotfiles repo)"
for f in CLAUDE.md settings.json settings.local.json statusline-command.sh; do
  skip "$f (dotfiles repo)"
done
skip ".cc-venv/ (recreate via install.sh)"
skip "backups/ (local only)"
skip "~/.secrets/ (tokens — never in a repo)"

# ── hook test suites: never publish a broken safe_command.py or guard ─────
if ! $DRY_RUN; then
  say "hook tests (tests/)"
  PY="$LIVE_CLAUDE/.cc-venv/bin/python"
  if [[ -x "$PY" ]] && "$PY" -c 'import pytest' 2>/dev/null; then
    if ( cd "$REPO/hooks" && "$PY" -m pytest -q -p no:cacheprovider tests/ 2>&1 | tail -3 | sed 's/^/    /' ; exit "${PIPESTATUS[0]}" ); then
      printf '    ok   hook tests pass\n'
    else
      die "hook tests FAILED against the captured files — do not commit"
    fi
  else
    skip "pytest not in $LIVE_CLAUDE/.cc-venv — run the suite manually before pushing"
  fi
fi

# ── safety net: this repo is PUBLIC ───────────────────────────────────────
# Two classes of leak, both fatal:
#   1. secret VALUES — session cookie, csrf token, ARN with a real account id,
#      live provider token. Bare paths like ~/.secrets/openrouter are fine.
#   2. employer / internal IDENTIFIERS — from the gitignored patterns file, so
#      no site-specific string lives in this public repo. Generic vendor words
#      ("acli jira", "Atlassian acli") are intentionally NOT flagged.
# The scan covers the repo's own tooling too (this script, install.sh, README),
# not just the captured artifacts — the tooling is published as well.
PATTERNS_FILE="${CC_LEAK_PATTERNS_FILE:-$REPO/.leak-patterns.local}"

if ! $DRY_RUN; then
  say "leak check (secret values + internal identifiers — public repo)"
  SCAN=("$REPO/tools" "$REPO/hooks" "$REPO/sh-aliases" "$REPO/plugins"
        "$REPO/populate.sh" "$REPO/install.sh" "$REPO/README.md")
  EXCL=(--exclude-dir __pycache__ --exclude-dir .pytest_cache)

  secrets="$(grep -rInE '_gitlab_session=[0-9a-f]{16}|x-csrf-token: ?[A-Za-z0-9._-]{20}|arn:aws:bedrock:[a-z0-9-]+:[0-9]{12}:|sk-or-v1-[A-Za-z0-9]{20}|sk-poe-[A-Za-z0-9_-]{20}|sk-ant-[A-Za-z0-9_-]{20}' \
    "${SCAN[@]}" "${EXCL[@]}" 2>/dev/null || true)"

  internal=""
  if [[ -f "$PATTERNS_FILE" ]]; then
    # strip comments/blank lines, join to one alternation
    alt="$(sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$PATTERNS_FILE" \
           | grep -v '^$' | paste -sd '|' -)"
    if [[ -n "$alt" ]]; then
      internal="$(grep -rInE "$alt" "${SCAN[@]}" "${EXCL[@]}" 2>/dev/null \
                  | grep -vF "$PATTERNS_FILE" || true)"
    fi
  else
    skip "no $PATTERNS_FILE — internal-identifier check SKIPPED (secret-value check still ran)"
  fi

  if [[ -n "$secrets" || -n "$internal" ]]; then
    [[ -n "$secrets"  ]] && { printf '  -- secret values --\n'; printf '%s\n' "$secrets"; }
    [[ -n "$internal" ]] && { printf '  -- internal identifiers --\n'; printf '%s\n' "$internal"; }
    die "leak check failed (see above) — this repo is PUBLIC; sanitize before committing"
  fi
  printf '    ok   no secret values or internal identifiers detected\n'
fi

# ── summary ───────────────────────────────────────────────────────────────
if $DRY_RUN; then
  say "dry-run complete — nothing written"
else
  say "done. Review and commit:"
  ( cd "$REPO" && git status --short -- tools hooks sh-aliases 2>/dev/null | sed 's/^/    /' )
  printf '    (from %s: git add -A && git commit && git push)\n' "$REPO"
fi
