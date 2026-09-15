#!/usr/bin/env bash
# Self-contained for curl | bash. Compatible with macOS Bash 3.2 and Linux.
set -euo pipefail

PI_PACKAGE="@earendil-works/pi-coding-agent"
MIN_NODE_VERSION="22.19.0"
# Protocol 3.18+ removed the node.js import used by lsp-pi.
LSP_PROTOCOL_VERSION="3.17.5"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MCP_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mcp/mcp.json"
PROVIDER=openai-codex
MODEL=gpt-5.6-sol
THINKING_OVERRIDE=''
FEATURE_OVERRIDES=''
ASSUME_YES=0; DRY_RUN=0; PLAIN=0; INTERACTIVE=0; COLOR=0; SCREEN_OPEN=0
ACTIVE_PID=''; RUN_DIR=''; LOG_FILE=''; BACKUP_DIR=''; NPM_ROOT=''
C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''; C_BOLD=''; C_RESET=''
FEATURE_NAMES=(monitor context-mode subagents index servers)
FEATURE_LABELS=("Context monitor" "Large-output retrieval" "Subagents + worktrees" "Semantic code index" "Language servers")
FEATURE_HINTS=("SuPi: context attribution; human report costs no model call" "Context Mode: index logs/docs and retrieve relevant excerpts" "Bounded child sessions; each child consumes model usage" "open-codebase-index; embedding cost depends on provider" "TypeScript / Vue / Python, plus installed Go/Rust toolchains")

usage() {
  cat <<'EOF'
Perfect Pi — one professional coding stack, tuned for quality and efficiency.

Usage: bash install-perfect-pi.sh [options]

  --with FEATURE[,FEATURE...]    Enable optional features
  --without FEATURE[,FEATURE...] Disable optional features
  --provider ID                 Startup provider (default: openai-codex)
  --model ID                    Startup model (default: gpt-5.6-sol)
  --thinking LEVEL              Thinking level (default: medium; high for escalation)
  --yes, -y                     Use selections without prompting
  --dry-run                     Print the plan; no installs or file writes
  --plain                       Plain output, no animation or screen control
  --help, -h                    Show this help

Features: monitor, context-mode, subagents, index, servers
Thinking: off, minimal, low, medium, high, xhigh, max

Examples:
  bash install-perfect-pi.sh
  bash install-perfect-pi.sh --dry-run
  bash install-perfect-pi.sh --yes
  bash install-perfect-pi.sh --yes --thinking high --without servers

Unselected managed extensions are disabled in Pi settings; their installed
files remain available for reuse. Unrelated settings are merged.
NO_COLOR disables ANSI output. PI_CODING_AGENT_DIR and XDG_CONFIG_HOME work.
EOF
}

die() { printf '\n%s  ERROR  %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
warn() { printf '%s  NOTE   %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
ui_ok() { printf '%s  OK     %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [[ -n "$ACTIVE_PID" ]]; then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  if [[ "$SCREEN_OPEN" == 1 ]]; then printf '\033[?25h\033[?1049l'; fi
  if [[ "$COLOR" == 1 ]]; then printf '\033[0m\033[?25h'; fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --plain) PLAIN=1 ;;
      --profile) die "--profile was removed. Use the opinionated default; --thinking high escalates reasoning." ;;
      --provider|--model|--thinking|--with|--without)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value."
        case "$1" in
          --provider) PROVIDER="$2" ;;
          --model) MODEL="$2" ;;
          --thinking) THINKING_OVERRIDE="$2" ;;
          --with) FEATURE_OVERRIDES="$FEATURE_OVERRIDES +$2" ;;
          --without) FEATURE_OVERRIDES="$FEATURE_OVERRIDES -$2" ;;
        esac
        shift ;;
      *) die "Unknown option: $1 (see --help)." ;;
    esac
    shift
  done
  case "$THINKING_OVERRIDE" in ''|off|minimal|low|medium|high|xhigh|max) ;; *) die "Unknown thinking level: $THINKING_OVERRIDE" ;; esac
  [[ "$AGENT_DIR" == /* ]] || die "PI_CODING_AGENT_DIR must be an absolute path."
  [[ "$MCP_CONFIG_FILE" == /* ]] || die "XDG_CONFIG_HOME must be an absolute path."
}

apply_defaults() {
  # Preserve working context for hard projects; save on output and fan-out instead.
  THINKING=medium; KEEP_RECENT=20000; OUTPUT_BYTES=24576; OUTPUT_LINES=400
  CONCURRENCY=2; SPAWNS_RUN=6; SPAWNS_SESSION=12; RETRIES=2
  FEATURES=(1 1 1 0 1)
  THINKING="${THINKING_OVERRIDE:-$THINKING}"
  local spec item enabled i found
  local items=()
  for spec in $FEATURE_OVERRIDES; do
    enabled=1; [[ "${spec:0:1}" == '+' ]] || enabled=0
    [[ "${spec:1}" != ,* && "$spec" != *, && "$spec" != *,,* ]] || die "Invalid feature list: ${spec:1}"
    IFS=',' read -r -a items <<< "${spec:1}"
    for item in "${items[@]}"; do
      found=0
      for i in 0 1 2 3 4; do
        if [[ "$item" == "${FEATURE_NAMES[$i]}" ]]; then FEATURES[$i]="$enabled"; found=1; fi
      done
      [[ "$found" == 1 ]] || die "Unknown feature: $item"
    done
  done
}

init_ui() {
  if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" && "$PLAIN" == 0 ]]; then
    COLOR=1
    C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  fi
  # Read the controlling terminal, never the script on stdin (curl | bash).
  if [[ -t 1 && "$ASSUME_YES" == 0 && "$DRY_RUN" == 0 && -z "${CI:-}" ]]; then
    if { exec 3<>/dev/tty; } 2>/dev/null; then INTERACTIVE=1; fi
  fi
  trap cleanup EXIT
  trap 'printf "\nInstallation cancelled.\n" >&2; exit 130' INT
  trap 'exit 143' TERM
}

ui_banner() {
  printf '\n%s  PERFECT PI%s  /  your terminal, tuned.\n' "$C_CYAN" "$C_RESET"
  printf '%s  ------------------------------------------------------%s\n' "$C_DIM" "$C_RESET"
  printf '  Small context. Deliberate reasoning. Serious tools.\n\n'
}

ui_section() { printf '\n%s  [%s/6] %s%s\n' "$C_CYAN" "$1" "$2" "$C_RESET"; }

close_screen() {
  if [[ "$SCREEN_OPEN" == 1 ]]; then printf '\033[?25h\033[?1049l'; SCREEN_OPEN=0; fi
}

ui_key() {
  local suffix=''
  KEY=''
  IFS= read -r -s -n 1 KEY <&3 || exit 130
  if [[ "$KEY" == $'\033' ]]; then
    IFS= read -r -s -n 2 -t 1 suffix <&3 || true
    case "$suffix" in '[A'|OA) KEY=up ;; '[B'|OB) KEY=down ;; *) KEY=escape ;; esac
  fi
}

# MENU_LABELS / MENU_HINTS / MENU_ON are shared with the caller. Small terminals,
# TERM=dumb, NO_COLOR and --plain get a readable numbered-menu fallback.
ui_menu() {
  local title="$1" mode="$2" cursor="${3:-0}" i cols rows answer marker width
  local count="${#MENU_LABELS[@]}"
  cols="$(tput cols 2>/dev/null || printf '80')"
  rows="$(tput lines 2>/dev/null || printf '24')"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  if [[ "$COLOR" == 1 && "$cols" -ge 60 && "$rows" -ge 24 ]]; then
    width=$((cols - 8)); [[ "$width" -le 90 ]] || width=90
    if [[ "$SCREEN_OPEN" == 0 ]]; then printf '\033[?1049h\033[?25l'; SCREEN_OPEN=1; fi
    while true; do
      printf '\033[H\033[2J'
      ui_banner
      printf '%s  %s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
      for ((i=0; i<count; i++)); do
        marker=' '
        if [[ "$mode" == multi ]]; then marker='[ ]'; [[ "${MENU_ON[$i]}" == 0 ]] || marker='[x]'; fi
        if [[ "$i" == "$cursor" ]]; then
          printf '%s > %s %s%s\n' "$C_CYAN" "$marker" "${MENU_LABELS[$i]}" "$C_RESET"
        else printf '   %s %s\n' "$marker" "${MENU_LABELS[$i]}"; fi
        printf '%s     %.*s%s\n' "$C_DIM" "$width" "${MENU_HINTS[$i]}" "$C_RESET"
        if [[ "$i" -lt "$((count - 1))" ]]; then printf '\n'; fi
      done
      if [[ "$mode" == multi ]]; then printf '  Up/Down or j/k: move  Space: toggle  Enter: continue\n';
      else printf '  Up/Down or j/k: move  Enter: select\n'; fi
      printf '%s  1-%s: quick select  q/Esc: cancel%s\n' "$C_DIM" "$count" "$C_RESET"
      ui_key
      case "$KEY" in
        up|k) cursor=$(((cursor + count - 1) % count)) ;;
        down|j) cursor=$(((cursor + 1) % count)) ;;
        ' ') if [[ "$mode" == multi ]]; then MENU_ON[$cursor]=$((1 - MENU_ON[cursor])); fi ;;
        '') MENU_INDEX="$cursor"; close_screen; return ;;
        [1-9])
          if [[ "$KEY" -le "$count" ]]; then
            cursor=$((KEY - 1))
            if [[ "$mode" == multi ]]; then MENU_ON[$cursor]=$((1 - MENU_ON[cursor]));
            else MENU_INDEX="$cursor"; close_screen; return; fi
          fi ;;
        q|escape) exit 130 ;;
      esac
    done
  fi
  while true; do
    printf '\n  %s\n' "$title"
    for ((i=0; i<count; i++)); do
      marker=''
      if [[ "$mode" == multi ]]; then marker='[ ] '; [[ "${MENU_ON[$i]}" == 0 ]] || marker='[x] '; fi
      printf '  %s. %s%s — %s\n' "$((i + 1))" "$marker" "${MENU_LABELS[$i]}" "${MENU_HINTS[$i]}"
    done
    if [[ "$mode" == multi ]]; then printf '  Number to toggle; Enter to continue; q to cancel: ';
    else printf '  Select [1-%s, default %s]; q to cancel: ' "$count" "$((cursor + 1))"; fi
    IFS= read -r answer <&3 || exit 130
    case "$answer" in
      q) exit 130 ;;
      '') MENU_INDEX="$cursor"; return ;;
      [1-9])
        if [[ "$answer" -le "$count" ]]; then
          cursor=$((answer - 1))
          if [[ "$mode" == multi ]]; then MENU_ON[$cursor]=$((1 - MENU_ON[cursor]));
          else MENU_INDEX="$cursor"; return; fi
        fi ;;
    esac
  done
}

choose_options() {
  [[ "$INTERACTIVE" == 1 ]] || return 0
  MENU_LABELS=("${FEATURE_LABELS[@]}"); MENU_HINTS=("${FEATURE_HINTS[@]}"); MENU_ON=("${FEATURES[@]}")
  ui_menu "Professional toolkit / defaults recommended" multi
  FEATURES=("${MENU_ON[@]}")
}

show_plan() {
  local i state
  ui_banner
  printf '%s  THE BUILD%s\n\n' "$C_BOLD" "$C_RESET"
  printf '  Model            %s/%s\n  Thinking         %s\n' "$PROVIDER" "$MODEL" "$THINKING"
  printf '  Recent context   %s tokens retained after compaction\n' "$KEEP_RECENT"
  printf '  MCP output       %s bytes / %s lines; full text spills to disk\n' "$OUTPUT_BYTES" "$OUTPUT_LINES"
  printf '  Child budgets    %s concurrent / %s per run / %s per session\n' "$CONCURRENCY" "$SPAWNS_RUN" "$SPAWNS_SESSION"
  printf '\n  Core             Pi + MCP adapter + LSP + rules + permission modes\n'
  for i in 0 1 2 3 4; do
    state=off; [[ "${FEATURES[$i]}" == 0 ]] || state=on
    printf '  %-17s %-4s %s\n' "${FEATURE_NAMES[$i]}" "$state" "${FEATURE_LABELS[$i]}"
  done
  printf '\n  Pi settings      %s/settings.json\n  Shared MCP       %s\n' "$AGENT_DIR" "$MCP_CONFIG_FILE"
  printf '  Adapter policy   %s/mcp.json\n' "$AGENT_DIR"
  printf '  Permissions      Build: automatic in-project work; sandbox boundaries still prompt\n'
  printf '                   Custom permission policies are preserved; verify with /sandbox.\n'
  printf '\n  Unselected managed extensions are disabled in settings.\n'
  printf '  Existing configuration is backed up before installation.\n'
  if [[ "$PROVIDER" == openai-codex ]]; then printf '  Codex subscription: optimize usage/quota; token cost is not your bill.\n'; fi
}

confirm_plan() {
  [[ "$INTERACTIVE" == 1 ]] || return 0
  local answer
  printf '\n  Install this setup? [Y/n] '
  IFS= read -r answer <&3 || exit 130
  case "$answer" in ''|y|Y|yes|YES) ;; *) printf '  Cancelled.\n'; exit 130 ;; esac
}

ui_run() {
  local label="$1" output rc=0 frame=0 started="$SECONDS"
  shift
  output="$RUN_DIR/step.log"
  printf '\n--- %s ---\n' "$label" >> "$LOG_FILE"
  if [[ "$COLOR" == 0 ]]; then printf '  RUN    %s\n' "$label"; fi
  # Explicit stdin preserves Node heredocs in asynchronous commands on Bash 3.2.
  "$@" <&0 >"$output" 2>&1 &
  ACTIVE_PID=$!
  if [[ "$COLOR" == 1 ]]; then
    local frames='|/-\\'
    while kill -0 "$ACTIVE_PID" 2>/dev/null; do
      printf '\r\033[2K%s  %s      %s  %ss%s' "$C_CYAN" "${frames:$((frame % 4)):1}" "$label" "$((SECONDS - started))" "$C_RESET"
      frame=$((frame + 1)); sleep 0.12
    done
  fi
  wait "$ACTIVE_PID" || rc=$?
  ACTIVE_PID=''
  if [[ "$COLOR" == 1 ]]; then printf '\r\033[2K'; fi
  cat "$output" >> "$LOG_FILE"
  if [[ "$rc" != 0 ]]; then cat "$output" >&2; die "$label failed (exit $rc). Log: $LOG_FILE"; fi
  ui_ok "$label ($((SECONDS - started))s)"
}

node_meets_minimum() {
  node - "$MIN_NODE_VERSION" <<'NODE'
const current = process.versions.node.split('.').map(Number);
const minimum = process.argv[2].split('.').map(Number);
for (let i = 0; i < 3; i++) {
  if (current[i] > minimum[i]) process.exit(0);
  if (current[i] < minimum[i]) process.exit(1);
}
NODE
}

ensure_node() {
  if command_exists node && command_exists npm && node_meets_minimum; then return; fi
  if [[ "$(uname -s)" == Darwin ]] && command_exists brew; then
    ui_run "Installing/upgrading Node" bash -c 'brew upgrade node 2>/dev/null || brew install node'
    hash -r
  else die "Install Node.js >= $MIN_NODE_VERSION and npm, then rerun."; fi
  command_exists node && command_exists npm && node_meets_minimum || die "Node >= $MIN_NODE_VERSION is not active. Check PATH / your version manager."
}

# Validate before installing, back up original bytes, merge managed fields, and
# atomically replace each document. The stdin heredoc keeps curl installs portable.
configure() {
  node - "$1" "$AGENT_DIR" "$MCP_CONFIG_FILE" "$BACKUP_DIR" "$NPM_ROOT" \
    "$PROVIDER" "$MODEL" "$THINKING" "$KEEP_RECENT" "$OUTPUT_BYTES" "$OUTPUT_LINES" \
    "$CONCURRENCY" "$SPAWNS_RUN" "$SPAWNS_SESSION" "$RETRIES" "${FEATURES[@]}" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [mode, agentDir, sharedPath, backupDir, npmRoot, provider, model, thinking,
  recent, bytes, lines, concurrency, spawnsRun, spawnsSession, retries, ...features] = process.argv.slice(2);
const [monitor, contextMode, subagents, index] = features.map(x => x === '1');
const paths = {
  settings: path.join(agentDir, 'settings.json'), shared: sharedPath,
  adapter: path.join(agentDir, 'mcp.json'),
  children: path.join(agentDir, 'extensions/subagent/config.json'),
  manifest: path.join(agentDir, 'npm/package.json'),
  permissions: path.join(agentDir, 'permission-mode/permission-mode.json'),
};
function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`);
  return value;
}
function section(parent, key) {
  if (parent[key] === undefined) parent[key] = {};
  return object(parent[key], key);
}
function read(file) {
  if (!fs.existsSync(file)) return {};
  try { return object(JSON.parse(fs.readFileSync(file, 'utf8')), file); }
  catch (error) { throw new Error(`Cannot use ${file}: ${error.message}`); }
}
function write(file, data) {
  const text = `${JSON.stringify(data, null, 2)}\n`;
  if (fs.existsSync(file) && fs.readFileSync(file, 'utf8') === text) return;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.perfect-pi-${process.pid}`;
  try {
    fs.writeFileSync(tmp, text, { mode: 0o600, flag: 'wx' });
    fs.renameSync(tmp, file);
  } finally { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); }
}
function configureFiles() {
  const docs = Object.fromEntries(Object.entries(paths).map(([key, file]) => [key, read(file)]));
  const s = docs.settings;
  // Use the extension's sandboxed, low-friction mode and make Pi's own
  // configuration/docs inspectable without boundary-prompt fatigue. auth.json
  // remains denied in every mode, including YOLO. Existing specific rules win
  // except for that credential backstop and managed write protection.
  docs.permissions.defaultMode = 'build';
  const modes = section(docs.permissions, 'modes');
  function patternMap(value, fallback, label) {
    if (value === undefined) return { '*': fallback };
    if (typeof value === 'string') return { '*': value };
    return object(value, label);
  }
  function mergePatterns(modeName, surface, fallback, managed = {}, forced = {}) {
    const permission = section(section(modes, modeName), 'permission');
    const current = patternMap(permission[surface], fallback, `${modeName}.${surface}`);
    const base = current['*'] ?? fallback;
    const specific = Object.fromEntries(Object.entries(current).filter(([key]) => key !== '*'));
    permission[surface] = { '*': base, ...managed, ...specific, ...forced };
  }
  const piRoot = path.join(npmRoot, '@earendil-works', 'pi-coding-agent');
  const authPath = path.join(agentDir, 'auth.json');
  const agentFiles = path.join(agentDir, '*');
  const piDocs = [path.join(piRoot, 'README.md'), path.join(piRoot, 'docs', '*'), path.join(piRoot, 'examples', '*')];
  const readableExternal = Object.fromEntries([agentFiles, ...piDocs].map(file => [file, 'allow']));
  for (const modeName of ['default', 'plan', 'build', 'yolo']) {
    mergePatterns(modeName, 'path', 'allow', {}, { [authPath]: 'deny' });
  }
  for (const modeName of ['default', 'plan', 'build']) {
    mergePatterns(modeName, 'external_directory', 'ask', readableExternal);
  }
  const docsReadOnly = { [path.join(piRoot, '*')]: 'deny' };
  for (const surface of ['write', 'edit']) {
    mergePatterns('plan', surface, 'deny', { '*.md': 'allow', '*.markdown': 'allow' }, docsReadOnly);
    mergePatterns('build', surface, 'allow', {}, { [agentFiles]: 'ask', ...docsReadOnly });
  }
  if (s.packages !== undefined && !Array.isArray(s.packages)) throw new Error('settings.packages must be an array');
  section(docs.shared, 'mcpServers'); section(docs.adapter, 'settings'); section(docs.adapter, 'mcpServers');
  const overrides = section(docs.manifest, 'overrides');
  if (overrides['lsp-pi'] !== undefined) object(overrides['lsp-pi'], 'lsp-pi override');
  section(s, 'modelThinkingLevels'); section(section(s, 'compaction'), 'modelOverrides');
  section(section(s, 'retry'), 'provider'); section(section(s, 'subagents'), 'agentOverrides');
  // Build the proposal during preflight too, detecting malformed nested objects
  // before npm or pi install can mutate existing configuration.
  s.defaultProvider = provider; s.defaultModel = model; s.defaultThinkingLevel = thinking;
  s.modelThinkingLevels[`${provider}/${model}`] = thinking;
  s.enabledModels = ['gpt-5.6-*', 'gpt-6-*'];
  if (provider !== 'openai-codex' || !/^gpt-(5\.6-|6-)/.test(model)) s.enabledModels.push(`${provider}/${model}`);
  s.showCacheMissNotices = true;
  s.theme ??= 'dark'; s.editorPaddingX ??= 1;
  Object.assign(s.compaction, { enabled: true, reserveTokens: 16384, keepRecentTokens: Number(recent) });
  // Preserve explicit per-model reserves, but apply the chosen retained tail.
  section(s.compaction.modelOverrides, `${provider}/${model}`).keepRecentTokens = Number(recent);
  Object.assign(s.retry, { enabled: true, maxRetries: Number(retries) });
  s.retry.provider.maxRetries = 0;
  const toggles = new Map([
    ['@mrclrchtr/supi-context', monitor], ['context-mode', contextMode],
    ['pi-subagents', subagents], ['open-codebase-index', index],
  ]);
  function packageName(entry) {
    const source = typeof entry === 'string' ? entry : entry?.source;
    if (typeof source !== 'string') throw new Error('Invalid Pi package entry');
    const name = source.replace(/^npm:/, '');
    const versionAt = name.indexOf('@', 1);
    return versionAt < 0 ? name : name.slice(0, versionAt);
  }
  s.packages = (s.packages || []).filter(entry => toggles.get(packageName(entry)) !== false);
  Object.assign(docs.adapter.settings, {
    directTools: false,
    outputGuard: { maxBytes: Number(bytes), maxLines: Number(lines), detailsMaxBytes: Number(bytes) },
  });
  // Portable server definition; adapter-only policy lives in Pi's override.
  if (docs.shared.mcpServers['jina-mcp-server'] === undefined) {
    docs.shared.mcpServers['jina-mcp-server'] = {
      url: 'https://mcp.jina.ai/v1?include_tags=search,read',
      headers: { Authorization: 'Bearer ${JINA_API_KEY}' },
    };
  }
  Object.assign(s.subagents, { defaultThinking: thinking });
  for (const role of ['scout', 'researcher', 'evidence-auditor', 'worker', 'reviewer', 'oracle', 'delegate']) {
    Object.assign(section(s.subagents.agentOverrides, role), { thinking: role === 'scout' ? 'low' : thinking, fast: false });
  }
  Object.assign(docs.children, {
    toolDescriptionMode: 'compact', defaultSubagentContext: 'fresh',
    globalConcurrencyLimit: Number(concurrency), maxActiveAsyncRunsPerSession: Number(concurrency),
    maxSubagentSpawnsPerRun: Number(spawnsRun), maxSubagentSpawnsPerSession: Number(spawnsSession),
  });
  if (mode === 'preflight') { console.log('Existing configuration is valid.'); return; }
  if (mode === 'backup') {
    fs.mkdirSync(backupDir, { recursive: true, mode: 0o700 });
    const manifest = {};
    for (const [key, file] of Object.entries(paths)) {
      if (!fs.existsSync(file)) continue;
      const destination = path.join(backupDir, `${key}.json`);
      fs.copyFileSync(file, destination, fs.constants.COPYFILE_EXCL);
      fs.chmodSync(destination, 0o600);
      manifest[key] = { original: file, backup: destination };
    }
    write(path.join(backupDir, 'restore-map.json'), manifest);
    console.log(`Backups: ${backupDir}`);
    return;
  }
  if (mode !== 'apply') throw new Error(`Unknown configuration mode: ${mode}`);
  for (const key of ['settings', 'shared', 'adapter', 'children', 'permissions']) write(paths[key], docs[key]);
  console.log('Applied professional defaults.');
}
try { configureFiles(); } catch (error) { console.error(error.message); process.exit(1); }
NODE
}

prepare_lsp() {
  node - "$AGENT_DIR/npm/package.json" "$LSP_PROTOCOL_VERSION" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [file, version] = process.argv.slice(2);
const data = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { name: 'pi-managed-packages', private: true };
data.overrides ??= {};
data.overrides['lsp-pi'] = { ...data.overrides['lsp-pi'], 'vscode-languageserver-protocol': version };
fs.mkdirSync(path.dirname(file), { recursive: true });
const temp = `${file}.perfect-pi-${process.pid}`;
fs.writeFileSync(temp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
fs.renameSync(temp, file);
NODE
}

# These are global installs. A project's trust prompt must not end up hidden
# behind the progress spinner, nor should its package list affect this setup.
install_package() { ui_run "Installing ${1#npm:}" pi install "$1" --no-approve; }

install_servers() {
  ui_run "Installing TypeScript, Vue and Python servers" npm install -g typescript typescript-language-server @vue/language-server pyright
  if command_exists go; then ui_run "Installing gopls" go install golang.org/x/tools/gopls@latest; fi
  if command_exists rustup; then ui_run "Installing rust-analyzer" rustup component add rust-analyzer; fi
  if [[ "$(uname -s)" == Darwin ]] && command_exists xcrun && xcrun --find sourcekit-lsp >/dev/null 2>&1; then ui_ok "Swift sourcekit-lsp detected"; fi
}

validate_pi_startup() {
  node - "$RUN_DIR" <<'NODE'
const { spawnSync } = require('node:child_process');
const result = spawnSync('pi', ['--offline', '--no-session', '--no-approve', '--mode', 'rpc'], {
  cwd: process.argv[2], input: '', encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024,
});
const output = `${result.stdout || ''}${result.stderr || ''}`;
if (result.error || result.status !== 0 || /failed to load extension|error loading extension/i.test(output)) {
  console.error(output, result.error?.message || 'Pi startup failed. Try pi --no-extensions.');
  process.exit(1);
}
console.log('Pi loaded in offline RPC mode. No model prompt was sent.');
NODE
}

summary() {
  printf '\n%s  READY TO SHIP.%s\n\n' "$C_GREEN" "$C_RESET"
  printf '  %s / %s thinking\n' "$MODEL" "$THINKING"
  printf '\n  Launch Pi in your repo, then:\n'
  printf '    /login          connect your provider\n    /mcp            inspect Jina and MCP discovery\n    /session        inspect tokens and session usage\n    /model          switch models; Ctrl+S saves a default\n'
  [[ "${FEATURES[0]}" == 0 ]] || printf '    /supi-context   see context by source, tool and message\n'
  [[ "${FEATURES[1]}" == 0 ]] || printf '    /ctx-doctor     inspect Context Mode; ask for ctx stats after use\n'
  [[ "${FEATURES[2]}" == 0 ]] || printf '    /subagents-doctor  check child-agent configuration\n'
  [[ "${FEATURES[3]}" == 0 ]] || printf '    /index          choose/configure embeddings for your repo\n'
  printf '\n  /perm build uses sandboxed autonomy; /perm plan is for planning.\n'
  printf '  /sandbox verifies containment; /net manages session domain approvals.\n'
  printf '  Resumed sessions retain their permission mode; use /perm build to switch.\n'
  printf '\n  Shift+Tab adjusts thinking. /new starts a clean task.\n'
  printf '  /compact can summarize a long task before changing phases.\n'
  printf '\n  Backups  %s\n  Log      %s\n\n' "$BACKUP_DIR" "$LOG_FILE"
}

main() {
  parse_args "$@"
  apply_defaults
  init_ui
  choose_options
  show_plan
  if [[ "$DRY_RUN" == 1 ]]; then printf '\n  DRY RUN complete. No files changed or commands installed.\n'; return; fi
  confirm_plan
  umask 077
  export PI_CODING_AGENT_DIR="$AGENT_DIR"
  RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/perfect-pi.XXXXXX")"
  LOG_FILE="$RUN_DIR/install.log"
  BACKUP_DIR="$AGENT_DIR/backups/perfect-pi-$(date +%Y%m%d-%H%M%S)-$$"
  ui_section 1 "Preflight"
  command_exists git || die "git is required."
  ensure_node
  ui_ok "Node $(node -v) / npm $(npm -v)"
  NPM_ROOT="$(npm root -g)"
  [[ "$NPM_ROOT" == /* ]] || die "npm root -g did not return an absolute path."
  if [[ "$(uname -s)" == Linux ]] && { ! command_exists bwrap || ! command_exists socat; }; then
    warn "Build mode needs bubblewrap and socat on Linux. Install them with your system package manager; otherwise Bash falls back to approval prompts."
  fi
  warn "Git worktrees/submodules may fall back to prompts in the permission extension. Only Bash is OS-sandboxed; extension tools are trusted code."
  ui_run "Checking existing configuration" configure preflight
  ui_section 2 "Checkpoint"
  ui_run "Backing up existing configuration" configure backup
  ui_section 3 "Core + discovery"
  if ! command_exists rg; then
    if [[ "$(uname -s)" == Darwin ]] && command_exists brew; then ui_run "Installing ripgrep" brew install ripgrep;
    elif command_exists apt-get; then
      # Authenticate in the foreground so a password prompt is never hidden.
      if [[ "$EUID" -ne 0 ]]; then
        command_exists sudo || die "Install ripgrep, or install sudo for apt-get."
        sudo -v
        ui_run "Updating package lists" sudo -n apt-get update
        ui_run "Installing ripgrep" sudo -n apt-get install -y ripgrep
      else
        ui_run "Updating package lists" apt-get update
        ui_run "Installing ripgrep" apt-get install -y ripgrep
      fi
    else warn "Install ripgrep (rg) for fast local searches."; fi
  fi
  ui_run "Installing Pi" npm install -g --ignore-scripts "$PI_PACKAGE"
  hash -r
  command_exists pi || die "Pi installed but is not on PATH."
  ui_run "Preparing LSP compatibility pin" prepare_lsp
  # Deselect before subsequent Pi commands can load unwanted extensions.
  ui_run "Applying professional defaults" configure apply
  install_package npm:pi-mcp-adapter
  install_package npm:lsp-pi
  install_package git:github.com/code-yeongyu/pi-rules
  install_package npm:pi-permission-modes
  ui_section 4 "Your toolkit"
  [[ "${FEATURES[0]}" == 0 ]] || install_package npm:@mrclrchtr/supi-context@6.4.0
  # The Pi extension bridges its bundled server itself: no duplicate MCP entry.
  [[ "${FEATURES[1]}" == 0 ]] || install_package npm:context-mode@1.0.169
  [[ "${FEATURES[2]}" == 0 ]] || install_package npm:pi-subagents
  [[ "${FEATURES[3]}" == 0 ]] || install_package npm:open-codebase-index
  [[ "${FEATURES[4]}" == 0 ]] || install_servers
  ui_section 5 "Context policy"
  ui_run "Merging final settings" configure apply
  if [[ -n "${JINA_API_KEY:-}" ]]; then ui_ok "JINA_API_KEY detected";
  else warn "Set JINA_API_KEY in the environment that launches Pi to use Jina search."; fi
  ui_section 6 "Health check"
  ui_run "Loading Pi and enabled extensions (60s limit)" validate_pi_startup
  summary
}

main "$@"
