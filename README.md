# claude-code-harness

fzf-driven provider/model switching for [Claude Code](https://claude.com/claude-code). Pick a backend (Anthropic, Ollama, OpenRouter, Poe, Z.AI), pick a model, and `claude` launches with the right `ANTHROPIC_*` env exported.

## What's in here

- `tools/cc.py` — the wrapper (`ccc` / `ccr`). Reads a YAML config, runs `fzf`, exports env, execs `claude`.
- `tools/providers.yaml` — provider definitions: base URLs, auth-token file paths, per-provider env, and a `listcmd` that enumerates each provider's model IDs.
- `sh-aliases/ai` — `ccc` / `ccr` / `ccprov` shell functions and the `CCC_PY` / `CCC_WRAPPER` paths. Source this from your shell rc.
- `hooks/` — Claude Code hooks: `safe_command.py` (PreToolUse guard for destructive/shell-injection commands), `log_commands.py` / `prompt_history.py` / `export_session.py` / `flush_stale_dumps.py` (audit + session dump helpers), `session-env-check.sh`. See `hooks/README` if present; tests under `hooks/tests/`.
- `plugins/` — the 4 public plugins (`imagine`, `mr-monitor`, `mr-review`, `review-board`), declared by the root `.claude-plugin/marketplace.json` as the `lootek` marketplace. `imagine` = OpenRouter image generation; `mr-monitor` + `mr-review` = GitLab MR pipeline/inline-comment workflows; `review-board` = multi-persona review with ~18 reviewer subagents. Install via `/plugin marketplace add lootek/claude-code-harness`.

`cc.py` finds `providers.yaml` **next to itself** (`tools/providers.yaml`), falling back to `~/.claude/providers.yaml`.

> **Note:** `safe_command.py`'s `CURL_POST_ALLOW_PREFIXES` (read-only API endpoints pre-approved for `curl` POST) is **empty by default**. No endpoints ship built-in. It is populated from two unioned sources: the `CC_CURL_POST_ALLOW` env var, and a gitignored `.curl-post-allow.local` beside the hook (override the path with `CC_CURL_POST_ALLOW_FILE`) — one URL prefix per line, `#` starts a comment. Same arrangement as `populate.sh`'s `.leak-patterns.local`. The `review-board` plugin ships 18 reviewer subagents; a few additional personas are kept in a private config and not published here. The `tech-doc-assist` plugin is likewise withheld (private/personal config).

## Install

```sh
# 1. Put the two files together somewhere (e.g. ~/.claude/tools/)
cp tools/cc.py tools/providers.yaml ~/.claude/tools/

# 2. Make cc.py executable
chmod +x ~/.claude/tools/cc.py

# 3. Wire up shell functions — source sh-aliases/ai from your shell rc
#    (e.g. in ~/.zshrc):
echo 'source ~/path/to/claude-code-harness/sh-aliases/ai' >> ~/.zshrc
#    or, if you keep an aliases dir:
cp sh-aliases/ai ~/.zsh-aliases/ai   # then ensure ~/.zsh-aliases/* is sourced

# 4. Install deps (pyyaml) — a dedicated venv keeps it isolated
python3 -m venv ~/.claude/.cc-venv
~/.claude/.cc-venv/bin/pip install pyyaml
# then point the functions at the venv python:
#   ccc() { ~/.claude/.cc-venv/bin/python3 ~/.claude/tools/cc.py "$@"; }
```

## Usage

```sh
ccc                              # fzf: provider → model → fresh session
ccr                              # resume latest session (--continue)
ccc --provider ollama --model glm-5.2:cloud -p "hi"
ccc --provider zai --model glm-5.2[1m]
```

Flags consumed by the wrapper (not forwarded to `claude`): `--continue`, `--provider NAME`, `--model ID`, `--` (everything after is passed verbatim).

## Secrets

`providers.yaml` holds **paths** to secret files, never the secrets. Put each provider's key in its own file:

```
~/.secrets/anthropic     # x-api-key for api.anthropic.com
~/.secrets/openrouter    # Bearer token
~/.secrets/poe
~/.secrets/z.ai
```

`ollama` uses the literal `ollama` token (no file). The wrapper reads the file and strips whitespace.

## The `[1m]` suffix

Claude Code 2.1.212+ honors a `[1m]` suffix on **any** model id (not just `api.anthropic.com`) — it grants a 1M-token context window and is stripped before the API call. `providers.yaml` emits `[1m]` variants for known 1M-capable models (e.g. `glm-5.2[1m]`, `kimi-k3:cloud[1m]`). See the comments in `providers.yaml`.

## Provider `env` map

A provider can declare extra env vars (`env:` block) that the wrapper exports — used by BYO providers like Z.AI that need `ANTHROPIC_DEFAULT_*_MODEL` (so Claude Code's background haiku calls route to the BYO backend) plus `API_TIMEOUT_MS`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, etc.

## License

MIT — see [LICENSE](LICENSE).