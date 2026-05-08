# `dev --create-dev-container` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `dev --create-dev-container` (and `--dind` / `--force`
modifiers) that materialises a self-contained, VS Code-compatible
`.devcontainer/` directory in the CWD, copying the project's
Dockerfile and supporting files and writing a `devcontainer.json` that
matches `./dev`'s runtime semantics (firewall, mise, named volumes).

**Architecture:** A new top-level branch in the `dev` bash script that
runs after argument parsing but before `detect_runtime` (no docker /
podman is needed). The branch validates argument combinations,
collision-checks every destination, copies fixed source files from
`$SCRIPT_DIR`, and emits `devcontainer.json` via heredoc. Two modes
(normal / dind) differ in file set, build target, runArgs, and
mounts. A single new scenario script exercises all four code paths.

**Tech Stack:** bash, Docker / Podman (only at runtime *after* the
generator runs; not used by the generator itself).

---

## File Structure

**Modify:**
- `dev` — add flag parsing for `--create-dev-container` and `--force`,
  add the generator branch + helpers, add help text, add
  mutual-exclusion guard.

**Create:**
- `scripts/test/scenarios/45-create-dev-container.sh` — single
  scenario covering normal-mode generation, collision refusal,
  `--force` overwrite, and dind-mode generation.

**Test orchestration:** `scripts/test/run-all.sh` picks up the new
scenario via its `[0-9]*.sh` glob — no orchestrator change needed.

**TDD rhythm:** the test scenario is written *first* in Task 1, where
it fails entirely (the flag does not exist yet). Each subsequent task
makes a slice of the scenario pass. Task 5 is the green-everywhere
checkpoint.

**Single-scenario invocation:**

```bash
bash scripts/test/scenarios/45-create-dev-container.sh
```

This scenario does not start containers, does not need `sudo`, and
does not modify the host. It writes only inside `mktemp -d` dirs and
cleans them up.

---

### Task 1: Write the failing integration scenario

**Files:**
- Create: `scripts/test/scenarios/45-create-dev-container.sh`

- [ ] **Step 1: Write the scenario**

Create `scripts/test/scenarios/45-create-dev-container.sh`:

```bash
#!/bin/bash
# scripts/test/scenarios/45-create-dev-container.sh
# platform: any
#
# `dev --create-dev-container` writes a self-contained .devcontainer/
# in the CWD. Covers: normal mode, collision refusal, --force overwrite,
# dind mode. Pure host-side file manipulation; no container is started.
set -u
LIB="$(dirname "$0")/../lib"
. "$LIB/assert.sh"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEV="${ROOT}/dev"

if [ ! -x "$DEV" ]; then
    log_fail "dev script not found or not executable at $DEV"
    exit 1
fi

# JSON validator: prefer python3 (always present on test hosts).
parse_json() {
    python3 -m json.tool "$1" >/dev/null 2>&1
}

# ---------- normal mode: clean dir ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "${WORK}_b" "${WORK}_d"' EXIT

cd "$WORK"
if ! "$DEV" --create-dev-container >/dev/null 2>&1; then
    log_fail "normal-mode generation failed in clean dir"
    exit 1
fi

for f in devcontainer.json Dockerfile entrypoint.sh firewall-init.sh \
         mise.base.toml allowlist.base; do
    if [ ! -f ".devcontainer/$f" ]; then
        log_fail "normal-mode: expected .devcontainer/$f"
        exit 1
    fi
done
for f in dind-init.sh allowlist.dind; do
    if [ -e ".devcontainer/$f" ]; then
        log_fail "normal-mode: did not expect .devcontainer/$f"
        exit 1
    fi
done
if ! parse_json .devcontainer/devcontainer.json; then
    log_fail "normal-mode: devcontainer.json is not valid JSON"
    exit 1
fi
if ! grep -q '"target": "base"' .devcontainer/devcontainer.json; then
    log_fail "normal-mode: build.target should be \"base\""
    exit 1
fi
if ! grep -q '"--cap-add=NET_ADMIN"' .devcontainer/devcontainer.json; then
    log_fail "normal-mode: --cap-add=NET_ADMIN missing from runArgs"
    exit 1
fi

# ---------- collision: refuse without --force ----------
SHA_BEFORE=$(sha256sum .devcontainer/devcontainer.json | awk '{print $1}')
if "$DEV" --create-dev-container >/dev/null 2>&1; then
    log_fail "second generation should fail without --force"
    exit 1
fi
SHA_AFTER=$(sha256sum .devcontainer/devcontainer.json | awk '{print $1}')
if [ "$SHA_BEFORE" != "$SHA_AFTER" ]; then
    log_fail "refused run still mutated .devcontainer/devcontainer.json"
    exit 1
fi

# ---------- collision: --force overwrites ----------
echo "stub" > .devcontainer/Dockerfile
if ! "$DEV" --create-dev-container --force >/dev/null 2>&1; then
    log_fail "--force should succeed over existing files"
    exit 1
fi
if ! grep -q '^FROM ' .devcontainer/Dockerfile; then
    log_fail "--force did not refresh Dockerfile (still 'stub')"
    exit 1
fi

# ---------- dind mode: clean dir ----------
WORK_D="${WORK}_d"
mkdir -p "$WORK_D"
cd "$WORK_D"
if ! "$DEV" --create-dev-container --dind >/dev/null 2>&1; then
    log_fail "dind-mode generation failed"
    exit 1
fi
for f in devcontainer.json Dockerfile entrypoint.sh firewall-init.sh \
         mise.base.toml allowlist.base dind-init.sh allowlist.dind; do
    if [ ! -f ".devcontainer/$f" ]; then
        log_fail "dind-mode: expected .devcontainer/$f"
        exit 1
    fi
done
if ! parse_json .devcontainer/devcontainer.json; then
    log_fail "dind-mode: devcontainer.json is not valid JSON"
    exit 1
fi
if ! grep -q '"target": "dind"' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: build.target should be \"dind\""
    exit 1
fi
if ! grep -q '"DEVCONTAINER_DIND": "1"' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: containerEnv.DEVCONTAINER_DIND missing"
    exit 1
fi
if ! grep -q '/dev/fuse' .devcontainer/devcontainer.json; then
    log_fail "dind-mode: --device=/dev/fuse missing"
    exit 1
fi

# ---------- mutual exclusion: rejects --build ----------
WORK_B="${WORK}_b"
mkdir -p "$WORK_B"
cd "$WORK_B"
if "$DEV" --create-dev-container --build >/dev/null 2>&1; then
    log_fail "should reject --create-dev-container --build"
    exit 1
fi

log_pass "create-dev-container generates valid normal/dind .devcontainer/"
exit 0
```

- [ ] **Step 2: Mark executable and run; expect FAIL**

```bash
chmod +x scripts/test/scenarios/45-create-dev-container.sh
bash scripts/test/scenarios/45-create-dev-container.sh
```

Expected: `[FAIL] 45-create-dev-container … normal-mode generation
failed in clean dir` (the flag is unknown, `dev` exits non-zero).

- [ ] **Step 3: Commit the failing test**

```bash
git add scripts/test/scenarios/45-create-dev-container.sh
git commit -m "test: scenario for dev --create-dev-container"
```

---

### Task 2: Add flag parsing + mutual-exclusion guard + stub branch

**Files:**
- Modify: `dev`

- [ ] **Step 1: Add the variable initialisations**

In `dev`, locate the block of `*=false` flag defaults (currently around
lines 122-132). Add `CREATE_DC=false` and `FORCE=false` next to the
others:

```bash
DRY_RUN=false
FORCE_BUILD=false
DEFAULT_PORTS=false
MAINTENANCE=false
DIND=false
MONITOR=false
MONITOR_FW=false
DISABLE_FW=false
ENABLE_FW=false
CREATE_DC=false
FORCE=false
EXTRA_PORTS=()
CMD_ARGS=()
```

- [ ] **Step 2: Add the new flag cases to the parsing loop**

In the `while [[ $# -gt 0 ]]; do case $1 in` block (currently
lines 279-340), add two cases above the catch-all `*)`:

```bash
    --create-dev-container)
      CREATE_DC=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
```

- [ ] **Step 3: Add the generator branch + mutual-exclusion guard**

Immediately after the argument-parsing `done` and before the existing
`if [[ "$DIND" == true && "$MAINTENANCE" == true ]]; then` block, add:

```bash
if [[ "$CREATE_DC" == true ]]; then
  # Allowed companions: --dind, --force. Reject everything else.
  bad=()
  [[ "$DRY_RUN"     == true ]] && bad+=(--dry-run)
  [[ "$FORCE_BUILD" == true ]] && bad+=(--build)
  [[ "$DEFAULT_PORTS" == true ]] && bad+=(--default-ports)
  [[ "$MAINTENANCE" == true ]] && bad+=(--maintenance)
  [[ "$MONITOR"     == true ]] && bad+=(--monitor)
  [[ "$MONITOR_FW"  == true ]] && bad+=(--monitor-fw)
  [[ "$DISABLE_FW"  == true ]] && bad+=(--disable-firewall)
  [[ "$ENABLE_FW"   == true ]] && bad+=(--enable-firewall)
  [[ ${#EXTRA_PORTS[@]} -gt 0 ]] && bad+=(--port)
  [[ ${#CMD_ARGS[@]}  -gt 0 ]] && bad+=("--")
  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "Error: --create-dev-container does not compose with: ${bad[*]}" >&2
    echo "       Allowed companions: --dind, --force." >&2
    exit 1
  fi
  create_dev_container
  exit 0
fi
```

The `create_dev_container` function does not exist yet; add a stub
above this block (above the existing `if [[ "$DIND" == true && …`
guard) so the script doesn't error on parse:

```bash
create_dev_container() {
  echo "Error: create_dev_container not yet implemented" >&2
  exit 1
}
```

- [ ] **Step 4: Verify the mutual-exclusion check fires**

```bash
./dev --create-dev-container --build 2>&1 | head -2
```

Expected: two lines starting with `Error: --create-dev-container does
not compose with: --build` and `Allowed companions: …`. Exit code 1.

```bash
./dev --create-dev-container; echo "exit=$?"
```

Expected: `Error: create_dev_container not yet implemented` then
`exit=1`.

- [ ] **Step 5: Commit**

```bash
git add dev
git commit -m "dev: parse --create-dev-container and --force flags"
```

---

### Task 3: Implement file collision check and file copies

**Files:**
- Modify: `dev`

- [ ] **Step 1: Replace the stub with the real `create_dev_container`**

Replace the stub function body with:

```bash
create_dev_container() {
  local target_dir=".devcontainer"
  local sources=(Dockerfile entrypoint.sh firewall-init.sh \
                 mise.base.toml allowlist.base)
  if [[ "$DIND" == true ]]; then
    sources+=(dind-init.sh allowlist.dind)
  fi
  # devcontainer.json is generated, not copied — but it counts toward
  # the destination set for collision checking.
  local destinations=("${target_dir}/devcontainer.json")
  for f in "${sources[@]}"; do
    destinations+=("${target_dir}/${f}")
  done

  # Collision check.
  local existing=()
  for d in "${destinations[@]}"; do
    [[ -e "$d" ]] && existing+=("$d")
  done
  if [[ ${#existing[@]} -gt 0 && "$FORCE" != true ]]; then
    echo "Refusing to overwrite:" >&2
    for d in "${existing[@]}"; do
      echo "  $d" >&2
    done
    echo "Pass --force to overwrite." >&2
    exit 1
  fi

  mkdir -p "$target_dir"

  # Copy source files from $SCRIPT_DIR.
  for f in "${sources[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
      echo "Error: missing source file ${SCRIPT_DIR}/${f}" >&2
      exit 1
    fi
    cp "${SCRIPT_DIR}/${f}" "${target_dir}/${f}"
  done

  # devcontainer.json is written in the next task — for now, write a
  # placeholder so the collision-check logic and file set are testable.
  printf '{}\n' > "${target_dir}/devcontainer.json"

  echo "Wrote ${target_dir}/ (mode: $([[ "$DIND" == true ]] && echo dind || echo normal))"
}
```

- [ ] **Step 2: Smoke-test in a tmp dir**

```bash
TMP=$(mktemp -d) && (cd "$TMP" && /workspace/dev --create-dev-container && ls -1 .devcontainer/) && rm -rf "$TMP"
```

Expected output (paths may vary):

```
Wrote .devcontainer/ (mode: normal)
Dockerfile
allowlist.base
devcontainer.json
entrypoint.sh
firewall-init.sh
mise.base.toml
```

- [ ] **Step 3: Smoke-test the collision refusal**

```bash
TMP=$(mktemp -d) && (
  cd "$TMP"
  /workspace/dev --create-dev-container >/dev/null
  /workspace/dev --create-dev-container 2>&1 | head -3
  echo "exit=$?"
  /workspace/dev --create-dev-container --force >/dev/null && echo "force ok"
) && rm -rf "$TMP"
```

Expected: a `Refusing to overwrite:` block listing 6 paths, exit 1
(the `head -3` truncates output; that's fine), then `force ok`.

- [ ] **Step 4: Smoke-test dind mode file set**

```bash
TMP=$(mktemp -d) && (cd "$TMP" && /workspace/dev --create-dev-container --dind && ls -1 .devcontainer/) && rm -rf "$TMP"
```

Expected: includes `dind-init.sh` and `allowlist.dind` in addition to
the normal-mode files.

- [ ] **Step 5: Commit**

```bash
git add dev
git commit -m "dev: copy support files into .devcontainer/ on --create-dev-container"
```

---

### Task 4: Emit the real `devcontainer.json` (normal mode)

**Files:**
- Modify: `dev`

- [ ] **Step 1: Replace the placeholder write with the real heredoc**

In `create_dev_container`, replace the line
`printf '{}\n' > "${target_dir}/devcontainer.json"` with the
two-branch emission:

```bash
  if [[ "$DIND" == true ]]; then
    write_devcontainer_json_dind "${target_dir}/devcontainer.json"
  else
    write_devcontainer_json_normal "${target_dir}/devcontainer.json"
  fi
```

- [ ] **Step 2: Add the normal-mode emitter**

Add this helper above `create_dev_container`:

```bash
write_devcontainer_json_normal() {
  local out="$1"
  cat > "$out" <<'JSON'
{
  "name": "generic-devcontainer",
  "build": {
    "dockerfile": "Dockerfile",
    "context": ".",
    "target": "base"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "overrideCommand": true,
  "runArgs": ["--cap-add=NET_ADMIN"],
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume"
  ]
}
JSON
}
```

The single-quoted heredoc tag (`'JSON'`) prevents bash from
interpreting `${localWorkspaceFolder}` and `${devcontainerId}` — those
must reach `devcontainer.json` literally (they're devcontainer-cli
variables, not shell variables).

- [ ] **Step 3: Add a placeholder dind emitter (real one in Task 5)**

So the `if/else` in Step 1 doesn't break, add:

```bash
write_devcontainer_json_dind() {
  local out="$1"
  echo "Error: dind devcontainer.json not yet implemented" >&2
  exit 1
}
```

- [ ] **Step 4: Verify normal-mode JSON**

```bash
TMP=$(mktemp -d) && (
  cd "$TMP"
  /workspace/dev --create-dev-container >/dev/null
  python3 -m json.tool .devcontainer/devcontainer.json >/dev/null && echo "json ok"
  grep -c 'devcontainerId' .devcontainer/devcontainer.json
) && rm -rf "$TMP"
```

Expected: `json ok` then `2` (two `${devcontainerId}` references in
mounts).

- [ ] **Step 5: Commit**

```bash
git add dev
git commit -m "dev: emit normal-mode devcontainer.json"
```

---

### Task 5: Emit `devcontainer.json` for `--dind` mode

**Files:**
- Modify: `dev`

- [ ] **Step 1: Replace the dind placeholder with the real emitter**

Replace the `write_devcontainer_json_dind` stub with:

```bash
write_devcontainer_json_dind() {
  local out="$1"
  cat > "$out" <<'JSON'
{
  // dind mode requires kernel.apparmor_restrict_unprivileged_userns=0
  // on Ubuntu 23.10+ / Linux 6.x hosts. See README.md → "Firewall" /
  // "Docker-in-Docker" sections for the host-side preflight.
  "name": "generic-devcontainer-dind",
  "build": {
    "dockerfile": "Dockerfile",
    "context": ".",
    "target": "dind"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "overrideCommand": true,
  "containerEnv": {
    "DEVCONTAINER_DIND": "1"
  },
  "runArgs": [
    "--cap-add=NET_ADMIN",
    "--cap-add=SYS_ADMIN",
    "--device=/dev/fuse",
    "--device=/dev/net/tun",
    "--security-opt", "apparmor=unconfined",
    "--security-opt", "seccomp=unconfined",
    "--security-opt", "systempaths=unconfined",
    "--security-opt", "label=disable"
  ],
  "mounts": [
    "source=${devcontainerId}-mise,target=/mise,type=volume",
    "source=${devcontainerId}-home,target=/home/vscode,type=volume",
    "source=${devcontainerId}-dind,target=/home/vscode/.local/share/docker,type=volume"
  ]
}
JSON
}
```

The leading `//` comments make this strictly JSONC, not JSON. VS
Code's devcontainer reader accepts JSONC — that's why our scenario
test uses `python3 -m json.tool` only on the *normal* mode output (it
rejects comments). For dind we'll validate via `grep` on the expected
keys instead. Update the scenario from Task 1 accordingly: it already
uses `parse_json` for both modes, so we'll relax the dind check.

- [ ] **Step 2: Loosen dind JSON validation in the scenario**

Edit `scripts/test/scenarios/45-create-dev-container.sh`. Replace the
dind-mode `parse_json` block:

```bash
if ! parse_json .devcontainer/devcontainer.json; then
    log_fail "dind-mode: devcontainer.json is not valid JSON"
    exit 1
fi
```

with a JSONC-aware validator. Add this helper near the top of the
scenario, beside `parse_json`:

```bash
# JSONC validator: strip line comments, then validate as JSON.
parse_jsonc() {
    sed 's:^[[:space:]]*//.*$::' "$1" | python3 -m json.tool >/dev/null 2>&1
}
```

Replace the dind `parse_json` call with `parse_jsonc`:

```bash
if ! parse_jsonc .devcontainer/devcontainer.json; then
    log_fail "dind-mode: devcontainer.json is not valid JSONC"
    exit 1
fi
```

- [ ] **Step 3: Run the full scenario; expect PASS**

```bash
bash scripts/test/scenarios/45-create-dev-container.sh
```

Expected: `[PASS] 45-create-dev-container … create-dev-container
generates valid normal/dind .devcontainer/`. Exit 0.

- [ ] **Step 4: Smoke-test the generated dind JSON manually**

```bash
TMP=$(mktemp -d) && (
  cd "$TMP"
  /workspace/dev --create-dev-container --dind >/dev/null
  grep -c 'devcontainerId' .devcontainer/devcontainer.json
) && rm -rf "$TMP"
```

Expected: `3` (three `${devcontainerId}` references — mise, home,
dind).

- [ ] **Step 5: Commit**

```bash
git add dev scripts/test/scenarios/45-create-dev-container.sh
git commit -m "dev: emit dind-mode devcontainer.json"
```

---

### Task 6: Update `--help` text and add post-write summary

**Files:**
- Modify: `dev`

- [ ] **Step 1: Add the new flags to `usage()`**

In `dev`, locate the `usage()` function (currently around lines
135-200). In the `OPTIONS:` block, add — after the `--enable-firewall`
entry and before the trailing `--`:

```
  --create-dev-container
                  Generate a self-contained .devcontainer/ in the
                  current directory (devcontainer.json + Dockerfile +
                  support files). VS Code's "Reopen in Container" will
                  build and attach to it. Compose with --dind for the
                  Docker-in-Docker variant. Use --force to overwrite
                  existing files.
  --force         Overwrite existing files when used with
                  --create-dev-container.
```

In the `EXAMPLES:` block, add at the bottom:

```
  dev --create-dev-container             # Scaffold .devcontainer/ for VS Code
  dev --create-dev-container --dind      # Scaffold dind-mode .devcontainer/
```

- [ ] **Step 2: Add post-write summary inside `create_dev_container`**

Replace the trailing
`echo "Wrote ${target_dir}/ (mode: ...)"` line with a richer
message:

```bash
  local mode_label="normal"
  [[ "$DIND" == true ]] && mode_label="dind"
  echo "Wrote ${target_dir}/ (${mode_label} mode)."
  echo
  echo "Next steps:"
  echo "  1. Open this directory in VS Code:   code ."
  echo "  2. When prompted, choose 'Reopen in Container'."
  echo "  3. (Optional) Add a workspace-root .devcontainer-allowlist"
  echo "     for project-specific firewall hostnames; firewall-init.sh"
  echo "     merges it at container startup."
}
```

- [ ] **Step 3: Verify the help text**

```bash
./dev --help | grep -A1 create-dev-container
```

Expected: the new help block visible.

- [ ] **Step 4: Verify the post-write summary**

```bash
TMP=$(mktemp -d) && (cd "$TMP" && /workspace/dev --create-dev-container) && rm -rf "$TMP"
```

Expected stdout includes:

```
Wrote .devcontainer/ (normal mode).

Next steps:
  1. Open this directory in VS Code:   code .
  …
```

- [ ] **Step 5: Re-run the scenario; commit**

```bash
bash scripts/test/scenarios/45-create-dev-container.sh
```

Expected: still `[PASS]`. Then:

```bash
git add dev
git commit -m "dev: document --create-dev-container in help and stdout"
```

---

## Self-Review

Plan covers each spec section:

- *Architecture / file-set selection* → Task 3.
- *normal-mode devcontainer.json* → Task 4.
- *dind-mode devcontainer.json* → Task 5.
- *Output layout* → Tasks 3 + 4 + 5 (file copy, JSON write, dind
  extras).
- *Collision behaviour* → Task 3 (logic) + scenario step in Task 1.
- *CLI surface / mutual-exclusion / post-write summary* → Tasks 2 + 6.
- *Testing* → Task 1 (scenario file) + Task 5 (final green check).

No placeholders, no "implement appropriate X". Function names are
consistent across tasks (`create_dev_container`,
`write_devcontainer_json_normal`, `write_devcontainer_json_dind`).
The `parse_json` / `parse_jsonc` helpers are introduced in the same
task they're first used.

One spec point worth flagging: the spec describes "leading JSON
comment" for the dind file. JSON proper has no comments; the plan
uses JSONC (`//`) and adds a `parse_jsonc` test helper for the
validator. This is a faithful translation of the spec's intent
(VS Code's devcontainer reader accepts JSONC).
