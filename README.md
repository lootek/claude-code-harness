# claude-code-harness

fzf-driven provider/model switching for [Claude Code](https://claude.com/claude-code). Pick a backend (Anthropic, Ollama, OpenRouter, Poe, Z.AI), pick a model, and `claude` launches with the right `ANTHROPIC_*` env exported.

## What's in here

- `tools/cc.py` — the wrapper (`ccc` / `ccr`). Reads a YAML config, runs `fzf`, exports env, execs `claude`.
- `tools/providers.yaml` — provider definitions: base URLs, auth-token file paths, per-provider env, and a `listcmd` that enumerates each provider's model IDs.

`cc.py` finds `providers.yaml` **next to itself** (`tools/providers.yaml`), falling back to `~/.claude/providers.yaml`.

## Install

```sh
# 1. Put the two files together somewhere (e.g. ~/.claude/tools/)
cp tools/cc.py tools/providers.yaml ~/.claude/tools/

# 2. Make cc.py executable
chmod +x ~/.claude/tools/cc.py

# 3. Wire up shell functions (ccc = fresh, ccr = resume)
ccc() { python3 ~/.claude/tools/cc.py "$@"; }
ccr() { python3 ~/.claude/tools/cc.py --continue "$@"; }

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

None yet — all rights reserved. Add one before depending on this.