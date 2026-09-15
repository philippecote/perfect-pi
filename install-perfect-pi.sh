#!/usr/bin/env bash
set -euo pipefail

# Philippe's "perfect slice of Pi"
# macOS + Linux
#
# Installs:
#   - Pi coding agent
#   - token-efficient MCP discovery/management
#   - subagents + managed worktree isolation
#   - compact LSP support
#   - Cursor / Claude / AGENTS.md rules compatibility
#   - semantic codebase indexing
#   - permission / sandbox modes
#   - web search + URL fetching through Jina MCP
#   - common language servers for TS/JS, Vue, Python
#
# Intentionally NOT installed:
#   - browser tooling (use MCP)
#   - persistent memory (optional; easy to add later)
#   - a second plan/worktree/LSP extension (avoid overlapping tools)

PI_PACKAGE="@earendil-works/pi-coding-agent"
MIN_NODE_VERSION="22.19.0"
DEFAULT_PROVIDER="openai-codex"
DEFAULT_MODEL="gpt-5.6-luna"
DEFAULT_THINKING_LEVEL="high"

# lsp-pi 1.0.5 imports vscode-languageserver-protocol/node.js. Protocol 3.18+
# removed that exported subpath, but lsp-pi's broad ^3.17.5 range still selects
# it. Keep the last compatible protocol release until lsp-pi publishes a fix.
LSP_PACKAGE="lsp-pi"
LSP_PROTOCOL_VERSION="3.17.5"
PI_NPM_DIR="$HOME/.pi/agent/npm"
MCP_CONFIG_DIR="$HOME/.config/mcp"
MCP_CONFIG_FILE="$MCP_CONFIG_DIR/mcp.json"

# Dependency-free TUI: works over SSH and requires no extra UI package.
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
  C_RED='\033[1;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''; C_RESET=''
fi

ui_banner() {
  printf '\n%s╭──────────────────────────────────────────────────────────────╮%s\n' "$C_CYAN" "$C_RESET"
  printf '%s│  ✦  PERFECT SLICE OF PI  ·  guided installer                 │%s\n' "$C_CYAN" "$C_RESET"
  printf '%s│     gpt-5.6 / gpt-6 models  ·  safe, searchable, extensible │%s\n' "$C_DIM" "$C_RESET"
  printf '%s╰──────────────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET"
}
ui_section() { printf '\n%s◆ %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
ui_ok() { printf '\r%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s  ⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die() { printf '\n%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

ui_run() {
  local label="$1"; shift
  local output
  output="$(mktemp)"
  printf '  %s… %s' "$C_DIM" "$label"
  if "$@" >"$output" 2>&1; then
    rm -f "$output"
    ui_ok "$label"
  else
    printf '\n'
    cat "$output" >&2
    rm -f "$output"
    die "$label failed"
  fi
}

log() { ui_section "$*"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

node_meets_minimum() {
  node - "$MIN_NODE_VERSION" <<'NODE'
const current = process.versions.node.split(".").map(Number);
const minimum = process.argv[2].split(".").map(Number);
for (let i = 0; i < 3; i++) {
  if (current[i] > minimum[i]) process.exit(0);
  if (current[i] < minimum[i]) process.exit(1);
}
NODE
}

install_or_upgrade_node() {
  if [[ "$(uname -s)" == "Darwin" ]] && command_exists brew; then
    ui_run "Installing/upgrading Node with Homebrew" bash -c 'brew upgrade node 2>/dev/null || brew install node'
    hash -r
  else
    die "Node.js >= $MIN_NODE_VERSION and npm are required. Install them, then rerun this script."
  fi
}

validate_pi_startup() {
  local output
  if ! output="$(pi --offline --mode rpc </dev/null 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Pi's startup self-test failed. Try 'pi -ne' to start without extensions."
  fi
}

# ---------- prerequisites ----------

ui_banner
log "Checking prerequisites"

command_exists git || die "git is required."

if ! command_exists node || ! command_exists npm; then
  install_or_upgrade_node
fi

if ! node_meets_minimum; then
  warn "Node.js >= $MIN_NODE_VERSION is required; found $(node -v)."
  install_or_upgrade_node
fi

command_exists node || die "Node installation completed, but 'node' is not on PATH."
command_exists npm || die "Node installation completed, but 'npm' is not on PATH."
node_meets_minimum || die "Node.js >= $MIN_NODE_VERSION is still not active; found $(node -v). Check your PATH or version manager."

log "Node $(node -v), npm $(npm -v)"

if ! command_exists rg; then
  if [[ "$(uname -s)" == "Darwin" ]] && command_exists brew; then
    ui_run "Installing ripgrep" brew install ripgrep
  elif command_exists apt-get; then
    ui_run "Updating package lists" sudo apt-get update
    ui_run "Installing ripgrep" sudo apt-get install -y ripgrep
  else
    warn "ripgrep (rg) not found. Install it manually for best search/sandbox support."
  fi
fi

# ---------- Pi ----------

ui_section "Installing core"
ui_run "Installing/updating Pi" npm install -g --ignore-scripts "$PI_PACKAGE"

command_exists pi || die "Pi installed but 'pi' is not on PATH."

printf 'Pi: %s\n' "$(pi --version 2>/dev/null || echo installed)"

# ---------- Pi extensions ----------

install_pi_package() {
  local pkg="$1"
  ui_run "Installing ${pkg#npm:}" pi install "$pkg"
}

# MCP: one small proxy tool; search/describe/invoke on demand.
install_pi_package "npm:pi-mcp-adapter"

# Subagents: scout / worker / reviewer / oracle, parallelism,
# background jobs, and managed Git worktree isolation.
install_pi_package "npm:pi-subagents"

# LSP: intentionally a single multiplexed `lsp` tool.
# Apply the transitive dependency override before installation. Keeping it in
# Pi's managed package.json also makes later package installs/reruns safe.
ui_section "Preparing language tooling"
mkdir -p "$PI_NPM_DIR"
if [[ ! -f "$PI_NPM_DIR/package.json" ]]; then
  ui_run "Creating Pi package manifest" npm init -y --prefix "$PI_NPM_DIR"
fi
ui_run "Pinning LSP protocol compatibility" npm pkg set \
  "overrides.${LSP_PACKAGE}.vscode-languageserver-protocol=$LSP_PROTOCOL_VERSION" \
  --prefix "$PI_NPM_DIR"
install_pi_package "npm:$LSP_PACKAGE"

# Cursor / Claude / Copilot / AGENTS.md rules compatibility.
# Git source is intentional: it is the safest current install path.
install_pi_package "git:github.com/code-yeongyu/pi-rules"

# Semantic + hybrid codebase index, symbol lookup, call graph.
install_pi_package "npm:open-codebase-index"

# Default / Plan / Build / YOLO permission modes with OS sandboxing.
install_pi_package "npm:pi-permission-modes"

# ---------- Language servers ----------

ui_section "Installing language intelligence"
ui_run "Installing TypeScript, Vue, and Python servers" npm install -g \
  typescript \
  typescript-language-server \
  @vue/language-server \
  pyright

if command_exists go; then
  ui_run "Installing/updating gopls" go install golang.org/x/tools/gopls@latest
fi

if command_exists rustup; then
  ui_run "Installing rust-analyzer" rustup component add rust-analyzer
fi

# Swift sourcekit-lsp normally comes with Xcode / Command Line Tools.
if [[ "$(uname -s)" == "Darwin" ]] && command_exists xcrun; then
  if xcrun --find sourcekit-lsp >/dev/null 2>&1; then
    log "Swift sourcekit-lsp detected"
  fi
fi

# ---------- Shared portable config ----------

log "Creating portable agent configuration directories"
mkdir -p \
  "$HOME/.agents/skills" \
  "$MCP_CONFIG_DIR" \
  "$HOME/.pi/agent"

# Jina provides web search and clean URL-to-Markdown reading over Streamable
# HTTP. Only expose its search/read families to keep MCP discovery compact.
# The credential is resolved from the environment when Pi connects; the key is
# never copied into this file.
log "Configuring Jina web search and URL fetching"
node - "$MCP_CONFIG_FILE" <<'NODE'
const fs = require("node:fs");

const configPath = process.argv[2];
let config = {};

if (fs.existsSync(configPath)) {
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (error) {
    console.error(`Could not parse existing MCP config ${configPath}: ${error.message}`);
    process.exit(1);
  }
}

if (!config || typeof config !== "object" || Array.isArray(config)) {
  console.error(`Existing MCP config ${configPath} must contain a JSON object.`);
  process.exit(1);
}

if (config.mcpServers === undefined) config.mcpServers = {};
if (!config.mcpServers || typeof config.mcpServers !== "object" || Array.isArray(config.mcpServers)) {
  console.error(`Existing mcpServers in ${configPath} must be a JSON object.`);
  process.exit(1);
}

const serverName = "jina-mcp-server";
if (config.mcpServers[serverName] !== undefined) {
  console.log(`Keeping existing ${serverName} entry in ${configPath}`);
  process.exit(0);
}

config.mcpServers[serverName] = {
  url: "https://mcp.jina.ai/v1?include_tags=search,read",
  headers: {
    Authorization: "Bearer ${JINA_API_KEY}",
  },
};

const temporaryPath = `${configPath}.tmp-${process.pid}`;
fs.writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporaryPath, configPath);
console.log(`Added ${serverName} to ${configPath}`);
NODE

# Keep startup and model cycling focused on GPT-5.6 and GPT-6 families.
# `enabledModels` filters Pi's model picker/cycling without deleting its catalogue.
ui_section "Applying model policy"
ui_run "Setting GPT-5.6 / GPT-6 defaults" node - "$HOME/.pi/agent/settings.json" "$DEFAULT_PROVIDER" "$DEFAULT_MODEL" "$DEFAULT_THINKING_LEVEL" <<'NODE'
const fs = require("node:fs");
const [settingsPath, provider, model, thinking] = process.argv.slice(2);
let settings = {};
if (fs.existsSync(settingsPath)) settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
settings.defaultProvider = provider;
settings.defaultModel = model;
settings.defaultThinkingLevel = thinking;
settings.enabledModels = ["gpt-5.6-*", "gpt-6-*"];
const temp = `${settingsPath}.tmp-${process.pid}`;
fs.writeFileSync(temp, `${JSON.stringify(settings, null, 2)}\\n`, { mode: 0o600 });
fs.renameSync(temp, settingsPath);
NODE

if [[ -n "${JINA_API_KEY:-}" ]]; then
  log "JINA_API_KEY detected"
else
  warn "JINA_API_KEY is not set. Add it to your shell before using Jina search."
fi

# Load every installed extension without contacting a model provider. RPC mode
# exits cleanly on EOF, making this suitable for both terminals and CI.
log "Validating Pi and all installed extensions"
validate_pi_startup

# ---------- Summary ----------

cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Pi stack installed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Core
  ✓ Pi coding agent
  ✓ read / write / edit / bash / grep / find / ls
  ✓ GPT-5.6 / GPT-6 model policy (5.5 excluded from picker)

Context & project intelligence
  ✓ LSP: TypeScript / JS / Vue / Python (+ Go/Rust when available)
  ✓ Semantic codebase index + hybrid search + call graph
  ✓ Web search + URL fetching through Jina MCP
  ✓ Cursor rules via .cursor/rules/
  ✓ AGENTS.md / CLAUDE.md compatibility
  ✓ Native Agent Skills via .agents/skills/

Agent architecture
  ✓ MCP tool search / describe / invoke (lazy, token-efficient)
  ✓ Subagents
  ✓ Parallel/background agents
  ✓ Managed Git-worktree isolation

Safety
  ✓ Permission modes
  ✓ OS-level sandboxing
  ✓ Plan / Build / YOLO modes

Recommended first launch:
  cd /path/to/your/repo
  pi

Then inside Pi:
  /login              # authenticate model providers
  /mcp                # inspect Jina and other MCP servers/tools
  /mcp setup          # discover/import Cursor/Claude/Codex MCP config
  /lsp                # inspect/configure LSP
  /rules              # inspect loaded Cursor/AGENTS rules

For semantic indexing in a repo, run:
  /index

Portable repo convention:
  AGENTS.md
  .agents/skills/
  .cursor/rules/
  .mcp.json

Notes:
  • Jina search requires JINA_API_KEY in the environment that launches Pi.
  • The MCP config stores only ${JINA_API_KEY}, never the secret itself.
  • Third-party Pi packages execute code. Review/pin them for enterprise rollout.
  • lsp-pi currently uses protocol 3.17.5 for compatibility; the installer keeps
    this transitive pin in Pi's managed npm configuration.
  • MCP servers remain lazy; their full schemas do not need to live in context.
  • Browser/web automation should come through your MCP gateway rather than
    adding another permanent native tool surface.
  • open-codebase-index chooses/configures embeddings separately; no embedding
    provider is hard-coded by this installer.

EOF
