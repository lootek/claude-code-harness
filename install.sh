#!/usr/bin/env bash
# install.sh — deploy claude-code-harness public artifacts into ~/.claude.
#
# Copies tools/cc.py, tools/providers.yaml, hooks/*, sh-aliases/ai from this
# repo into ~/.claude (and ~/.zsh-aliases), with timestamped backups of
# existing targets. Registers the `lootek` plugin marketplace from github and
# installs the 4 public plugins. Idempotent.
#
# Personal config (CLAUDE.md, settings.json, statusline, tech-doc-assist) is
# owned by the dotfiles repo — not touched here.
#
# Files protected with the macOS `uchg` (user-immutable) flag are handled with
# a tight clear -> copy -> re-apply pair so they're never left writable. Files
# without the flag are copied plainly (the script stays generic).

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.claude"
ALIAS_DST="$HOME/.zsh-aliases"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DST/backups/$TS"

mkdir -p "$DST/tools" "$DST/hooks/tests" "$ALIAS_DST" "$BACKUP"

backup_if_exists() {
  local path="$1"
  if [ -e "$path" ]; then
    local rel="${path#$HOME/}"
    local dest="$BACKUP/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
  fi
}

has_uchg() { ls -lO "$1" 2>/dev/null | awk '{print $5}' | grep -qx uchg; }

# copy a file, clearing+re-applying uchg if the destination has it
install_file() {
  local src="$1" dst="$2" mode="${3:-}"
  backup_if_exists "$dst"
  if has_uchg "$dst"; then
    chflags nouchg "$dst"
    cp "$src" "$dst"
    chflags uchg "$dst"
  else
    cp "$src" "$dst"
  fi
  [ -n "$mode" ] && chmod "$mode" "$dst"
  echo "  -> $dst"
}

echo "Installing claude-code-harness public artifacts from $SRC"
echo "Backups (if any) -> $BACKUP"

# ccc/ccr wrapper + provider catalog
install_file "$SRC/tools/cc.py"          "$DST/tools/cc.py" 755
install_file "$SRC/tools/providers.yaml" "$DST/tools/providers.yaml" 600

# hooks (7 hook files + tests); runtime artifacts (audit log, pycache) are left alone
for f in log_commands.py prompt_history.py export_session.py \
         flush_stale_dumps.py safe_command.py payload_guard.py session-env-check.sh; do
  install_file "$SRC/hooks/$f" "$DST/hooks/$f"
  [ "${f##*.}" = "sh" ] || chmod +x "$DST/hooks/$f"
done
install_file "$SRC/hooks/tests/test_safe_command.py" "$DST/hooks/tests/test_safe_command.py"
install_file "$SRC/hooks/tests/test_payload_guard.py" "$DST/hooks/tests/test_payload_guard.py"
# synthetic fixtures for the payload-guard suite (inert: read as text, never run)
mkdir -p "$DST/hooks/tests/fixtures"
for f in "$SRC"/hooks/tests/fixtures/*; do
  install_file "$f" "$DST/hooks/tests/fixtures/$(basename "$f")"
done
# safe_command.py imports payload_guard.py, so both halves of the boundary need
# the immutable flag — locking only one leaves the other writable.
echo "  NOTE: re-apply the lock:  chflags uchg $DST/hooks/safe_command.py $DST/hooks/payload_guard.py"

# shell alias (ccc / ccr / ccprov)
install_file "$SRC/sh-aliases/ai" "$ALIAS_DST/ai"

# ── plugins: register the lootek marketplace from github + install the 4 public ones ──
PUBLIC_PLUGINS=(imagine mr-monitor mr-review review-board)
if command -v claude >/dev/null 2>&1; then
  echo "Registering lootek marketplace (github: lootek/claude-code-harness)"
  if ! claude plugin marketplace list 2>/dev/null | grep -q 'lootek/claude-code-harness'; then
    # remove a stale local-dir lootek marketplace if present, then add the github source
    claude plugin marketplace remove lootek >/dev/null 2>&1 || true
    claude plugin marketplace add lootek/claude-code-harness
  fi
  for p in "${PUBLIC_PLUGINS[@]}"; do
    claude plugin install "$p@lootek" >/dev/null 2>&1 || claude plugin update "$p@lootek" >/dev/null 2>&1 || true
    echo "  -> $p@lootek"
  done
else
  echo "  (claude CLI not on PATH — skipping marketplace register/install; run manually)"
fi

# ccc/ccr needs pyyaml in an isolated venv (system python on macOS is PEP-668)
VENV="$DST/.cc-venv"
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c 'import yaml' 2>/dev/null; then
  echo "Bootstrapping ccc/ccr venv at $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q pyyaml
fi

echo "done. Restart Claude Code if hooks/plugins changed."