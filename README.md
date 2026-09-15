# Perfect Pi

A polished, repeatable installer for [Pi](https://github.com/badlogic/pi-mono), configured as a capable coding-agent environment for macOS and Linux.

## What it installs

- Pi coding agent
- MCP discovery and management
- Jina web search and URL fetching
- Subagents with managed Git worktree isolation
- LSP support for TypeScript, JavaScript, Vue, Python, and optionally Go/Rust
- Cursor, Claude, Copilot, and `AGENTS.md` rules compatibility
- Semantic codebase indexing and call graphs
- Permission modes and OS-level sandboxing

## Model policy

The installer configures Pi with:

- Default model: `gpt-5.6-luna`
- Default thinking level: `high`
- Enabled model families: `gpt-5.6-*` and `gpt-6-*`
- GPT-5.5 excluded from the model picker/cycling list

Pi’s model catalogue is not deleted; `enabledModels` controls the models exposed for normal selection.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/philippecote/perfect-pi/main/install-perfect-pi.sh \
  | bash
```

Or clone and inspect it first:

```bash
git clone https://github.com/philippecote/perfect-pi.git
cd perfect-pi
less install-perfect-pi.sh
bash install-perfect-pi.sh
```

The installer requires Node.js `>= 22.19.0`, npm, and Git. On macOS, Homebrew can install or upgrade Node; on Debian-based Linux, it can install ripgrep when needed.

## After installation

```bash
cd /path/to/your/repo
pi
```

Inside Pi:

- `/login` — authenticate a model provider
- `/mcp` — inspect MCP servers and tools
- `/index` — index the current repository
- `/rules` — inspect loaded project rules

Set `JINA_API_KEY` in the environment that launches Pi to enable web search and URL fetching.

## Configuration

The installer preserves existing Pi settings and updates:

```text
~/.pi/agent/settings.json
```

It also adds the Jina server to:

```text
~/.config/mcp/mcp.json
```

Secrets are referenced through environment variables and are never written into the repository.

## License

Use and adapt freely. Review third-party packages before enterprise deployment.
