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

## Recommended priority

1. Fix context-mode and Pi permission integration.
2. Reduce oversized built-in `read`/`grep` results through bounded retrieval.
3. Add model routing for routine work.
4. Expand the trusted read-only tool allowlist in Default and Plan modes.
5. Adopt a pre-push divergence check.

No changes were made to plugin configuration during this audit.
