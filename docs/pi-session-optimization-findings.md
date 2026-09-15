# Pi Session Optimization Findings

Audit of the previous Pi session (`01a0a508-8fb2-72d3-9e05-8525cf3f2b4b`).

## Findings

1. **Routine work uses an expensive model.** The session made 53 assistant invocations and 63 tool-result calls across 8 user messages. It processed 4.86M tokens and cost approximately $4.12 with `gpt-5.6-sol` at medium thinking. Consider routing documentation, configuration, and repository chores to Luna or Terra, reserving Sol for difficult work.

2. **Broad built-in reads and searches bypass context-mode.** Tool results contributed roughly 359 KB to context: `read` contributed about 160 KB and `grep` about 118 KB, with individual results up to 50 KB. Context-mode itself achieved about 97% reduction when used. Consider routing or warning on broad built-in `read`/`grep` operations, not merely lowering MCP output limits.

3. **Context-mode and Pi permission-mode have a boundary mismatch.** Pi permission rules allowed configuration reads, but `ctx_execute_file` rejected the permission-mode JSON because context-mode confines file processing to the project root. The context-mode Pi adapter should honor Pi permission policy, or provide a safe tool specifically for ingesting previous Pi session logs.

4. **Default and Plan extension-tool policies may still prompt unnecessarily.** They use a wildcard `tool: ask` policy while explicitly allowing only a small set of tools. Trusted read-only tools such as `ctx_search`, `ctx_execute_file`, codebase search/context, and LSP could be explicitly allowed while keeping execution and mutation tools gated.

5. **SuPi-context does not appear to be a significant source of overhead.** It mainly caches prompt metadata and provides a human-facing report; its agent tool is disabled. Keep it unless the report is unused.

6. **The Git workflow caused avoidable retries.** The session attempted to push before checking remote divergence, then encountered a non-fast-forward and a README rebase conflict. Use `fetch`, compare divergence, rebase or merge, run checks, then push.

7. **The session reached about 135K tokens without compaction.** `keepRecentTokens` only controls the retained tail after compaction. For long research-to-implementation sessions, use phase-boundary `/compact` or an adaptive context-pressure reminder.

## Implementation notes

### 1. Integrate context-mode with Pi permissions

The failure occurred while processing `~/.pi/agent/permission-mode/permission-mode.json`: the host policy allowed the path, but `ctx_execute_file` independently rejected every path outside the workspace. Context-mode's README documents a separate Claude-style `permissions.allow` mechanism, so the Pi adapter does not currently understand the active `pi-permission-modes` rules.

Recommended implementation:

- Add a Pi-specific permission resolver in the context-mode adapter, or expose the host's resolved permission decision to the adapter.
- Before `ctx_execute_file` rejects an external path, check whether the active Pi mode permits a `read` of that path and whether the path is not denied by the credential backstop.
- Preserve the project-root guard by default; only permit explicitly allowed paths. Never broaden `ctx_execute` or `ctx_batch_execute`, since those execute arbitrary code and are a different security surface.
- Add tests for: allowed Pi config read, denied `auth.json`, denied unlisted external path, traversal/symlink escape, and all four permission modes.
- As a lower-risk alternative, add a dedicated Pi session-log ingestion command that accepts only session files under `~/.pi/agent/sessions/**`, parses JSONL, and returns bounded summaries rather than arbitrary file contents.

### 2. Reduce broad built-in `read`/`grep` output

The previous session produced about 359 KB of tool results. `read` contributed about 160 KB and `grep` about 118 KB; one grep result reached 50 KB. MCP output guards do not constrain Pi's built-in tools.

Recommended implementation:

- Add a warning or result truncation policy around built-in `read`, `grep`, `find`, and `ls`, based on bytes and lines.
- Preserve the full result on disk and show a short message containing the path, byte/line counts, and spill-file location, matching the existing MCP output-guard behavior.
- Prefer targeted reads: require or suggest `offset`/`limit` for large files and cap grep matches by default while retaining an explicit “show more” path.
- Do not silently discard data needed by an edit; provide a follow-up mechanism to retrieve a selected range.
- Instrument bytes processed/returned by tool and compare before/after in session stats.

### 3. Add routine-task model routing

The session used `gpt-5.6-sol` for nearly every turn, including documentation lookup, permission inspection, and Git housekeeping. The installed models include Luna, Terra, and Sol with materially different prices.

Recommended implementation:

- Implement this as an advisory router extension, not a hard gate.
- Classify requests using cheap signals: documentation/config inspection, formatting, tests, and simple Git operations are routine; architecture, security decisions, ambiguous debugging, and final synthesis are complex.
- Select Luna for routine low-risk work, Terra for moderate work, and Sol for complex work or final review.
- Keep the routing hint stable in `before_agent_start` so provider prompt caching remains effective.
- For delegated tasks, include the required routing metadata header and retain the parent model as the final evaluator.
- Record selected model, reason, and outcome for later tuning; never retry expensive models automatically after a provider failure without a bounded policy.

### 4. Expand trusted read-only tool permissions

The active Default/Plan policy has `tool: "ask"` as the wildcard and only explicitly allows a few tools (`mcp`, `index_status`, `subagent`, and `ctx_execute`). This can cause prompts for trusted read-only tools such as `ctx_search`, `ctx_execute_file`, `codebase_context`, `codebase_search`, `lsp`, and `index_health_check`.

Recommended implementation:

- Add exact allow rules for read-only retrieval and diagnostics tools in Default and Plan.
- Keep `ctx_execute`, `ctx_batch_execute`, mutation tools, network tools, and arbitrary MCP tools explicitly gated unless their risk is understood; `ctx_execute` is arbitrary code despite being useful for analysis.
- Keep `auth.json` denied through the cross-cutting path policy in every mode, including YOLO, as the current installer does.
- Test a matrix of tool names against each mode and verify that project writes remain unchanged.

### 5. Preserve or remove SuPi-context based on usage

The installed `@mrclrchtr/supi-context` extension registers context-monitoring hooks and a human `/supi-context` report. Its agent-callable report is disabled, and the previous session showed no evidence that it caused significant context growth.

No implementation change is currently recommended. If the report is never used, disable it through the installer's existing feature toggle and compare startup/tool latency rather than removing it speculatively.

### 6. Add a safe pre-push workflow

The previous push failed because the remote had advanced; rebasing then caused a README conflict. This is operational waste rather than a plugin defect.

Recommended implementation:

- Before pushing, run `git fetch origin` and `git rev-list --left-right --count HEAD...origin/main`.
- If the remote is ahead, inspect the short graph and rebase or merge before committing/pushing.
- Run `git diff --check` and the focused installer tests after conflict resolution.
- Push only after confirming the working tree, branch, and intended commit.
- Add this sequence to the agent's project guidance or installer documentation, not as an automatic extension that mutates Git state.

### 7. Manage long sessions with context pressure

The session reached approximately 135K tokens without compaction. `keepRecentTokens` (currently 20,000) controls the retained tail after compaction; it does not trigger compaction earlier.

Recommended implementation:

- Add a token-free UI/status reminder when context usage crosses configurable thresholds, for example 50% and 70% of the active compaction limit.
- Remind only at turn boundaries with exponential backoff, avoiding an extra model call.
- Encourage `/compact` at phase boundaries: after research, before implementation, and before final review.
- Measure whether earlier compaction reduces input cost without losing relevant task state; do not lower the retained tail blindly.

## Recommended priority

1. Fix context-mode and Pi permission integration, especially the external session-log workflow.
2. Reduce oversized built-in `read`/`grep` results through bounded retrieval and spill files.
3. Add advisory model routing for routine work.
4. Expand the trusted read-only tool allowlist in Default and Plan modes.
5. Add the pre-push divergence check and context-pressure reminders.

No changes were made to plugin configuration during this audit.
