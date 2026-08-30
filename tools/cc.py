#!/usr/bin/env python3
"""ccc/ccr — fzf-driven Claude Code provider+model wrapper.

Reads ~/.claude/providers.yaml, lets you pick a provider and a model (fzf),
exports the right ANTHROPIC_* env, and execs `claude`.

Usage (source sh-aliases/ai from your shell rc, then):
    ccc [claude-args...]            fresh session
    ccr [claude-args...]            resume most-recent session (--continue)
    ccc --provider ollama --model glm-5.2:cloud -p "hi"

Flags (consumed by this script, not forwarded):
    --continue          pass --continue to claude (resume latest session)
    --provider NAME     skip the provider fzf
    --model ID          skip the model fzf
    --                  everything after is passed to claude verbatim
"""
import os
import sys
import subprocess

try:
    import yaml
except ImportError:
    sys.exit("pyyaml missing — run: ~/.claude/.cc-venv/bin/pip install pyyaml")

# providers.yaml lives next to this script (tools/providers.yaml). Fall back
# to ~/.claude/providers.yaml for legacy installs. First existing file wins.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CFG_CANDIDATES = [
    os.path.join(SCRIPT_DIR, "providers.yaml"),
    os.path.expanduser("~/.claude/providers.yaml"),
]
CFG = next((p for p in CFG_CANDIDATES if os.path.isfile(p)), CFG_CANDIDATES[0])
OUR_FLAGS = {"--continue", "--provider", "--model"}


def load():
    with open(CFG) as f:
        return yaml.safe_load(f)["providers"]


def resolve_token(v):
    if not v:
        return ""
    if v.startswith("~") or v.startswith("/"):
        path = os.path.expanduser(v)
        try:
            with open(path) as f:
                return f.read().strip()
        except FileNotFoundError:
            sys.exit(f"token file not found: {path}")
    return v


def fzf_pick(lines, prompt):
    if not lines:
        return ""
    r = subprocess.run(
        ["fzf", "--prompt", prompt, "--height=40%"],
        input="\n".join(sorted(set(lines))) + "\n",
        text=True,
        capture_output=True,
    )
    return r.stdout.strip() if r.returncode == 0 else ""


def list_model_ids(cfg):
    out = subprocess.run(cfg["listcmd"], shell=True, capture_output=True, text=True)
    return [l for l in out.stdout.splitlines() if l.strip()]


# claude code fills several internal slots (background title generation, the
# subagent model, and the opus/sonnet/haiku aliases) with *Anthropic* model
# names. On a BYO provider those names don't resolve, so the calls fail. A
# provider can either pin the slots itself via `env:` (z.ai does), or set
# route_slots_to_model: true to aim every slot at whatever model was picked —
# the right default when the catalogue is huge and no single model is special
# (the HF router). Explicit `env:` entries always win.
SLOT_VARS = (
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
)


def route_slots(cfg, model):
    if not cfg.get("route_slots_to_model"):
        return
    declared = cfg.get("env") or {}
    for var in SLOT_VARS:
        if var not in declared:
            os.environ[var] = model


def apply_env(p, cfg, providers=None):
    # Clear ANTHROPIC_* + CLAUDE_CODE_MAX_OUTPUT_TOKENS so switching providers
    # doesn't leak env from a previous launch.
    #
    # claude code 2.1.212 honors the [1m] suffix for any provider (NPc()'s ub()
    # branch), not just api.anthropic.com. A model id like "glm-5.2:cloud[1m]"
    # gets a 1M context window; the suffix is stripped before the API call.
    # CLAUDE_CODE_MAX_CONTEXT_TOKENS is also read (NPc fallback) for non-
    # claude- model names, but the [1m] suffix is the cleaner lever. See
    # ~/.claude/providers.yaml for which models emit [1m] variants.
    # The clear covers every key any provider can set, not just ANTHROPIC_*:
    # otherwise a CLAUDE_CODE_* var declared by one provider (z.ai's
    # DISABLE_NONESSENTIAL_TRAFFIC, or a slot var) survives into the next
    # launch and silently points at a model the new provider doesn't serve.
    volatile = {"CLAUDE_CODE_MAX_OUTPUT_TOKENS", *SLOT_VARS}
    for pcfg in (providers or {}).values():
        volatile.update((pcfg.get("env") or {}).keys())
    for k in list(os.environ):
        if k.startswith("ANTHROPIC_") or k in volatile:
            del os.environ[k]
    if not cfg.get("native"):
        os.environ["ANTHROPIC_BASE_URL"] = cfg.get("base_url", "")
        os.environ["ANTHROPIC_AUTH_TOKEN"] = resolve_token(cfg.get("auth_token", ""))
        # Most gateways authenticate off ANTHROPIC_AUTH_TOKEN alone and want
        # ANTHROPIC_API_KEY empty. Some (the HF router) document setting both,
        # so a provider may declare api_key — same literal-or-path resolution
        # as auth_token. "auth_token" is a shorthand for "reuse that value".
        api_key = cfg.get("api_key", "")
        if api_key == "auth_token":
            api_key = os.environ["ANTHROPIC_AUTH_TOKEN"]
        else:
            api_key = resolve_token(api_key)
        os.environ["ANTHROPIC_API_KEY"] = api_key
    mot = cfg.get("max_output_tokens")
    if mot:
        os.environ["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = str(mot)
    # Provider-declared extra env (BYO providers like z.ai that need
    # ANTHROPIC_DEFAULT_*_MODEL for claude code's background haiku calls,
    # API_TIMEOUT_MS, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, etc.).
    # Values are literal strings — no file-path resolution (only auth_token
    # does that). Exported after the ANTHROPIC_* clear above, so keys
    # starting with ANTHROPIC_ survive. ANTHROPIC_MODEL is set later in
    # main() from the fzf pick, overriding anything here.
    for k, v in (cfg.get("env") or {}).items():
        os.environ[k] = str(v)


def parse_args(argv):
    resume = False
    provider = None
    model = None
    rest = []
    i = 0
    while i < len(argv):
        t = argv[i]
        if t == "--continue":
            resume = True
            i += 1
        elif t == "--provider" and i + 1 < len(argv):
            provider = argv[i + 1]
            i += 2
        elif t == "--model" and i + 1 < len(argv):
            model = argv[i + 1]
            i += 2
        elif t == "--":
            rest = argv[i + 1:]
            break
        else:
            rest = argv[i:]
            break
    return resume, provider, model, rest


def main():
    resume, provider, model, rest = parse_args(sys.argv[1:])
    providers = load()
    if not provider:
        provider = fzf_pick(list(providers), "provider> ")
        if not provider:
            sys.exit(130)
    if provider not in providers:
        sys.exit(f"unknown provider: {provider}")
    cfg = providers[provider]
    apply_env(provider, cfg, providers)
    if not model:
        model = fzf_pick(list_model_ids(cfg), f"{provider}> ")
        if not model:
            sys.exit(130)
    os.environ["ANTHROPIC_MODEL"] = model
    route_slots(cfg, model)
    args = rest if not resume else ["--continue", *rest]
    sys.stderr.write(f"→ provider={provider} model={model}\n")
    os.execvpe("claude", ["claude", "--model", model, *args], os.environ)


if __name__ == "__main__":
    main()