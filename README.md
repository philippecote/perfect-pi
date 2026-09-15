# Perfect Pi

**Your terminal, tuned.** An opinionated installer for [Pi](https://github.com/badlogic/pi-mono) on macOS and Linux: **Sol medium**, professional tools, sandboxed autonomy, and bounded usage. One setup for serious projects—not three cost tiers.

Accept the recommended toolkit (or toggle exceptions with **Space**), review the plan, and install. Commands run behind a live spinner with elapsed time; failures show the command's output and a log path. Small terminals get numbered menus. `NO_COLOR`, `TERM=dumb`, and `--plain` are supported. No TUI dependency is needed.

## Run it

```bash
git clone https://github.com/philippecote/perfect-pi.git
cd perfect-pi
bash install-perfect-pi.sh --dry-run
bash install-perfect-pi.sh
```

Or use the self-contained installer:

```bash
curl -fsSL https://raw.githubusercontent.com/philippecote/perfect-pi/main/install-perfect-pi.sh | bash
```

Prompts read `/dev/tty`, so piping the script does not consume your answers as shell code.

For unattended installation:

```bash
# Recommended fleet default
bash install-perfect-pi.sh --yes

# Explicit reasoning escalation, without global language servers
bash install-perfect-pi.sh --yes --thinking high --without servers

# A different provider/model; use an ID available in your Pi catalogue
bash install-perfect-pi.sh --dry-run --provider YOUR_PROVIDER --model YOUR_MODEL
```

`--with` and `--without` accept comma-separated features and can be repeated. Professional defaults are applied first, then explicit feature overrides. `--thinking high` increases reasoning without increasing fan-out or output budgets. The old `--profile` flag is rejected with migration guidance. See `--help` for all flags. Without a controlling terminal, or in CI, the installer uses the supplied selections without prompting. Dry runs never install packages or write configuration.

Requires **Node.js ≥22.19.0**, npm, Git, and Bash ≥3.2. Homebrew can install/upgrade Node on macOS. Ripgrep is installed through Homebrew or apt when available. On other platforms, install those prerequisites first.

## Professional defaults

| Setting | Default |
|---|---:|
| Main model / thinking | Sol / medium |
| Recent tokens retained after compaction | 20,000 |
| MCP inline output limit | 24 KiB / 400 lines |
| Child concurrency | 2 |
| Child spawns per run / session | 6 / 12 |
| Agent-level transient retries | 2 |
| Context retrieval / subagents / monitoring / language servers | On |
| Semantic indexing | Opt-in; choose embeddings deliberately |
| Startup permission mode | Build (sandboxed when available) |

The default is **`openai-codex/gpt-5.6-sol`**. GPT-5.6 and GPT-6 patterns scope **Ctrl+P cycling**; this is not an authorization boundary or removal of other models from Pi's catalogue. Custom `--provider` / `--model` selections are added to the cycling list. The chosen model's per-model thinking preference is updated too, so a stale per-model override cannot defeat the selected reasoning level.

### What these controls actually save

- **Thinking:** medium is the fleet starting point, not a measured optimum. Escalate with Shift+Tab for difficult debugging, architecture, or repeated failed attempts; use `--thinking high` for teams whose workload warrants it. Preserve quality by keeping 20k recent tokens rather than forcing tiny context. Before rolling out to 100 developers, compare medium/high on representative hard tasks: accepted fixes, rework, elapsed time, and quota per completed task—not tokens per call.
- **MCP results:** the adapter truncates oversized text and saves the full result to disk for targeted retrieval. The budget affects model-facing output, not just how many lines the terminal displays. Individual server/project overrides can supersede global adapter policy.
- **Compaction:** Pi's built-in summarizer stays enabled. `keepRecentTokens` changes the retained tail **after** compaction; it does **not** trigger compaction at 20k. The normal trigger remains `contextWindow - reserveTokens`, with a 16,384-token base reserve. Existing explicit per-model reserves are preserved. Compaction itself uses a model call and changes the cached prefix; compacting after every turn can increase cost.
- **Subagents:** fresh context avoids copying the entire parent conversation. Compact tool descriptions reduce fixed overhead. Spawn/concurrency defaults bound fan-out, and built-in roles use the selected thinking level (`scout` stays low) with priority/fast mode off. Per-run, project, provider-role, and environment overrides may take precedence. These are usage controls, **not a hard dollar cap**.
- **Subscription billing:** the default Codex provider uses subscription authentication. Lower token consumption helps quota and latency; Pi's dollar estimates are not necessarily your subscription bill. API billing and optional embedding/search services are separate.

## Toolkit

Always installed:

- Pi coding agent
- **pi-mcp-adapter** — on-demand MCP search/describe/invoke, proxy mode by default
- **lsp-pi** — one multiplexed language-intelligence tool
- **pi-rules** — Cursor / Claude / Copilot / `AGENTS.md` compatibility
- **pi-permission-modes** — permission modes and platform-dependent sandbox support
- Jina search/read MCP definition, using `${JINA_API_KEY}` from the environment

Selectable features:

| Flag name | Package / action | Default |
|---|---|---|
| `monitor` | **@mrclrchtr/supi-context 6.4.0** | On |
| `context-mode` | **context-mode 1.0.169** | On |
| `subagents` | **pi-subagents**, including managed worktrees | On |
| `index` | **open-codebase-index** | Opt-in |
| `servers` | TypeScript, Vue, Python; Go/Rust when toolchains exist | On |

### Context-management recommendations

**Keep the MCP adapter.** It already addresses tool-schema overhead through discovery. Making every MCP tool direct adds those schemas back to the prompt. The installer sets the global proxy default; existing server-specific choices remain authoritative.

**Add SuPi Context for measurement.** `/supi-context` breaks down instruction, skill, tool, and message overhead. Its human-facing report does not enter model context or require an LLM request. Its optional agent-callable tool is disabled by the package by default. Pi already shows basic token/cache/cost totals in the footer; this adds attribution.

**Context Mode is enabled for output-heavy professional work.** It indexes large logs/docs and retrieves relevant excerpts, with session-continuity hooks. Its native Pi integration adds `ctx_*` tools and a local SQLite dependency, so the extra footprint is most worthwhile for large-output tasks. The published Pi extension contains its own MCP bridge: this installer installs only the Pi package, avoiding a second global install or duplicate MCP server entry. Verify `/ctx-doctor`, then exercise `ctx_fetch_and_index` / `ctx_search` and inspect `ctx_stats` in a real session. The installer's offline startup check does not exercise that lazily started bridge.

**Use built-in compaction first.** A separate model for summarization is possible through Pi's official custom-compaction example, but it needs explicit provider/model selection and should preserve recent tool-call/result pairs. The installer uses native compaction rather than adding a second summarizer with an assumed provider.

Practical habits:

1. Keep always-loaded `AGENTS.md` instructions short; put specialist procedures in on-demand skills. Avoid importing duplicate rules through multiple paths.
2. Search for symbols or relevant lines before reading whole files. Use the LSP and index to narrow retrieval.
3. Keep raw build logs, API responses, and generated files on disk; ask for focused excerpts or computed summaries.
4. Use `/new` for unrelated tasks. Use `/compact` with explicit preservation instructions when continuing a long task.
5. Keep tool definitions and system instructions stable within a task to preserve prefix-cache reuse. Cache-miss notices are enabled by the installer. Extended cache retention is provider-specific, not a universal cost switch.
6. Use subagents for bounded, distinct tasks with concise results; avoid automatic scout/worker/reviewer loops for trivial changes.
7. Choose embeddings deliberately before `/index`. The installer neither selects a paid embedding provider nor starts indexing.

### Sources reviewed

Checked September 15, 2026 against upstream documentation and the installed MCP/subagent packages:

- [Pi settings](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/settings.md)
- [Pi compaction](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/compaction.md)
- [Custom compaction example](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/examples/extensions/custom-compaction.ts)
- [MCP adapter: proxy discovery and output guard](https://github.com/nicobailon/pi-mcp-adapter)
- [Subagent configuration](https://github.com/nicobailon/pi-subagents/blob/main/docs/configuration.md) and [model/thinking precedence](https://github.com/nicobailon/pi-subagents/blob/main/docs/models.md)
- [SuPi Context](https://github.com/mrclrchtr/supi/tree/main/packages/supi-context)
- [Context Mode's Pi integration](https://github.com/mksglu/context-mode/blob/main/src/adapters/pi/extension.ts)

Upstream claims such as “98% savings” are workload-specific, not measured savings for this setup. The two new context packages are version-pinned; existing core packages retain their update-on-install behavior.

## Permissions without approval fatigue

The installer sets `defaultMode: "build"` in the permission extension's global config. Previously it installed the extension without configuring it, leaving its confirm-every-edit/command Default mode active.

- **Build:** routine in-project Bash and file edits proceed without confirmations. Bash is OS-sandboxed when available; protected file-tool paths remain blocked.
- **Boundaries:** outside-project access, privilege escalation, and new network domains still prompt. Pi's own agent directory and installed README/docs/examples are readable without boundary prompts so developers can inspect their setup. `auth.json` is explicitly denied in every mode, including YOLO; writes to the agent directory still prompt in Build, and installed Pi documentation is read-only.
- **Network:** use session domain grants (`/net`) rather than opening all network access. Approving a boundary escape can run the command unsandboxed: read those prompts carefully.
- **Plan:** `/perm plan` for planning; `/perm build` to implement. Resumed sessions retain their previous mode, so changing the installer default does not switch an existing session.
- **Existing policy:** custom modes, rules, and network grants are preserved. Project overlays can tighten policy, and custom Build rules can change the stock behavior. Verify the effective setup with `/sandbox`.
- **Linux:** install `bubblewrap`, `socat`, and `ripgrep`. Missing sandbox dependencies cause fallback approval prompts; the installer warns rather than silently disabling protection.
- **Worktrees/submodules:** the currently installed permission extension cannot sandbox these and falls back to prompts. This also affects managed subagent worktrees. Use a regular clone for its fully sandboxed workflow.
- **Scope:** only Bash is OS-sandboxed. File tools use policy checks; Build allows extension/MCP tools and skills without prompts. Their code and remote actions must be trusted separately. This is not a universal destructive-action detector, a centrally enforced enterprise boundary, or a guarantee of Codex/Claude Code parity. YOLO is not the default.

## Configuration and recovery

```text
~/.pi/agent/settings.json                   model, thinking, compaction, package selection
~/.pi/agent/mcp.json                        Pi-specific MCP output/proxy policy
~/.pi/agent/extensions/subagent/config.json  child-session budgets
~/.pi/agent/npm/package.json                LSP protocol compatibility override
~/.pi/agent/permission-mode/permission-mode.json  startup permission mode
~/.config/mcp/mcp.json                      portable Jina server definition
```

`PI_CODING_AGENT_DIR` relocates Pi configuration. `XDG_CONFIG_HOME` relocates the shared MCP configuration. Existing custom servers, unrelated settings, custom role model choices, and package entries are preserved. The installer manages the listed cost fields, feature selections, and Pi self-inspection permission rules; existing specific permission patterns remain in place, while the `auth.json` denial and managed write protections take precedence. Deselecting a managed extension removes its settings entry without deleting its installed files. Local project settings can still enable packages or tighten policy.

Existing files are validated before package installation and copied byte-for-byte to:

```text
~/.pi/agent/backups/perfect-pi-TIMESTAMP-PID/
```

`restore-map.json` maps each backup to its original path. To restore configuration, stop Pi and copy the desired backup to the corresponding original path. Files that did not exist before the run are absent from the map. Package downloads/global installations are not rolled back by restoring configuration.

Config updates use atomic replacement and private file permissions. The Jina key is referenced, never interpolated into generated config. Existing Jina definitions are kept. The LSP protocol pin at **3.17.5** is retained to address `lsp-pi`'s incompatible transitive import.

The final health check loads enabled global extensions in an empty temporary directory, in offline RPC mode, without a session or model prompt. It has a 60-second deadline. Logs live in the temporary directory printed at the end or on failure; retain them before OS temp cleanup if needed.

## Verification

```bash
bash -n install-perfect-pi.sh
python3 -B -m unittest discover -s tests -v
```

Tests use isolated homes and mocked package managers. They exercise configuration merging, backups, reruns, failures, pipe execution, opinionated defaults, overrides, permission configuration, and interactive terminal input without installing anything into your actual Pi setup.

## License

Use and adapt freely. Individual installed packages retain their own licenses.
