#!/usr/bin/env bash
# scripts/update-deps.sh — audit / update the project's pinned dependencies.
#
# What this script touches (one entry per location we hard-pin a version):
#   mise.base.toml               node, ripgrep, eza, lazygit, neovim
#                                (baked into the runtime container image)
#   mise.toml                    shellcheck, hadolint, actionlint, jq
#                                (developer tools for this repo)
#   Dockerfile                   base image digest, ARG MISE_VERSION,
#                                ARG DOCKER_VERSION, ARG COMPOSE_VERSION
#   .github/workflows/*.yml      pinned action SHAs (re-resolve current
#                                v<major> tag for each action)
#   scripts/lint.sh              HADOLINT_VERSION + sha256,
#                                ACTIONLINT_VERSION + sha256
#
# Usage:
#   scripts/update-deps.sh                 # report what's out of date (default)
#   scripts/update-deps.sh --apply         # interactively approve each update
#   scripts/update-deps.sh --apply --yes   # apply every available update (non-interactive)
#
# Networking: the script needs outbound HTTPS to api.github.com,
# mcr.microsoft.com, and the lint-tool release CDNs. Run on the host or in
# a --maintenance / --dind container — not in a firewalled normal container
# (mcr.microsoft.com is not in allowlist.base).
#
# After --apply, eyeball `git diff`, run `bash scripts/lint.sh`, and commit
# as a single `chore(deps): …` change so release-please groups it cleanly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APPLY=false
YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=true; shift ;;
        --yes|-y)   YES=true;   shift ;;
        --help|-h)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done
if [ "$YES" = "true" ] && [ "$APPLY" = "false" ]; then
    echo "Error: --yes only makes sense together with --apply." >&2
    exit 1
fi

for tool in curl jq sed awk grep sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Error: '$tool' is required." >&2
        exit 1
    }
done
if ! command -v mise >/dev/null 2>&1; then
    echo "Warning: 'mise' not on PATH; mise.base.toml checks will be skipped." >&2
fi

stale=0
applied=0
skipped=0
ok()  { printf '  ok   %s\n' "$*"; }
new() { printf '  NEW  %s\n' "$*"; stale=$((stale + 1)); }

# Returns 0 if the caller should perform the edit, 1 if it should skip.
# Behaviour:
#   - Not in --apply mode  -> always skip (caller is only meant to report).
#   - --apply --yes        -> always accept silently.
#   - --apply (interactive)-> read y/N from /dev/tty; default is No.
#   - --apply but no TTY   -> skip with a hint; --yes is required for non-
#                              interactive batches (CI, automation).
prompt_apply() {
    if [ "$APPLY" != "true" ]; then return 1; fi
    if [ "$YES"   = "true" ]; then
        echo "       (auto-accepted via --yes)"
        applied=$((applied + 1))
        return 0
    fi
    if [ ! -r /dev/tty ]; then
        echo "       skipped (no TTY; rerun with --yes to apply non-interactively)"
        skipped=$((skipped + 1))
        return 1
    fi
    local reply=""
    printf '       apply this update? [y/N] '
    read -r reply </dev/tty || reply=""
    case "$reply" in
        y|Y|yes|YES)
            applied=$((applied + 1))
            return 0
            ;;
        *)
            echo "       skipped"
            skipped=$((skipped + 1))
            return 1
            ;;
    esac
}

# Small HTTPS helper. Uses GITHUB_TOKEN when present to dodge the
# unauthenticated 60/hour API limit. On HTTP failure (notably 403 rate-
# limit), prints stderr context and returns 1 so callers can bail; never
# returns an empty success — that would let later sed steps wipe pins.
ghapi() {
    local url="$1" body status args
    args=(-sS -w '\n%{http_code}\n')
    [ -n "${GITHUB_TOKEN:-}" ] && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    body=$(curl "${args[@]}" "$url" 2>&1) || {
        echo "ghapi: curl failed for $url: $body" >&2
        return 1
    }
    status=$(printf '%s' "$body" | tail -1)
    body=$(printf '%s' "$body" | sed '$d')
    if [ "$status" != "200" ]; then
        echo "ghapi: HTTP $status for $url" >&2
        if [ "$status" = "403" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
            echo "       (likely rate-limited; export GITHUB_TOKEN to raise the limit)" >&2
        fi
        return 1
    fi
    printf '%s\n' "$body"
}

# Resolve a tag (e.g. v4) to a commit SHA. GitHub returns annotated tags as
# an indirection (object.type == "tag"); follow it once to get the commit.
# Returns 1 (no output) on any HTTP/JSON failure so callers can refuse to
# rewrite pins with an empty value.
action_sha() {
    local repo="$1" tag="$2" ref_json sha type
    ref_json=$(ghapi "https://api.github.com/repos/${repo}/git/refs/tags/${tag}") || return 1
    sha=$(jq -r '.object.sha // empty' <<<"$ref_json")
    type=$(jq -r '.object.type // empty' <<<"$ref_json")
    [ -n "$sha" ] || return 1
    if [ "$type" = "tag" ]; then
        local tag_json
        tag_json=$(ghapi "https://api.github.com/repos/${repo}/git/tags/${sha}") || return 1
        sha=$(jq -r '.object.sha // empty' <<<"$tag_json")
        [ -n "$sha" ] || return 1
    fi
    echo "$sha"
}

gh_latest_tag() {
    local body
    body=$(ghapi "https://api.github.com/repos/$1/releases/latest") || return 1
    jq -r '.tag_name // empty' <<<"$body"
}

# Walk recent releases, return the first tag matching $2 (extended regex).
# Used to keep us on the current major version family for projects whose
# `releases/latest` jumps majors aggressively (docker/compose, moby/moby).
gh_latest_tag_matching() {
    local body
    body=$(ghapi "https://api.github.com/repos/$1/releases?per_page=50") || return 1
    jq -r '.[] | select(.prerelease|not) | .tag_name' <<<"$body" \
        | grep -E "$2" \
        | head -1
}

# --- mise tools -------------------------------------------------------------

check_mise_tool() {
    local file="$1" key="$2" query="${3:-$2}" current latest
    current=$(awk -v k="$key" '
        $1 == k && $2 == "=" { gsub(/"/, "", $3); print $3; exit }
    ' "$file")
    if [ -z "$current" ]; then
        new "${file}  ${key}  (not pinned)"
        return 0
    fi
    if ! command -v mise >/dev/null 2>&1; then return 0; fi
    latest=$(mise latest "$query" 2>/dev/null || true)
    if [ -z "$latest" ]; then
        new "${file}  ${key}  (mise latest failed)"
        return 0
    fi
    if [ "$current" = "$latest" ]; then
        ok "${file}  ${key} = ${current}"
    else
        new "${file}  ${key}: ${current}  ->  ${latest}"
        if prompt_apply; then
            sed -i.bak -E "s|^(${key} = )\"${current}\"|\\1\"${latest}\"|" "$file"
            rm -f "${file}.bak"
        fi
    fi
}

# --- Dockerfile -------------------------------------------------------------

check_base_image() {
    local line current_digest tag latest_digest
    line=$(grep -oE 'mcr\.microsoft\.com/devcontainers/base:[^@[:space:]]+@sha256:[a-f0-9]{64}' Dockerfile | head -1)
    if [ -z "$line" ]; then
        new "Dockerfile  base image  (no digest pin found)"
        return 0
    fi
    tag=$(echo "$line"          | sed -E 's|.*/base:([^@]+)@.*|\1|')
    current_digest=$(echo "$line" | sed -E 's|.*@||')
    latest_digest=$(curl -fsSL \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        "https://mcr.microsoft.com/v2/devcontainers/base/manifests/${tag}" \
        -D - -o /dev/null 2>/dev/null \
        | awk 'tolower($1) == "docker-content-digest:" {print $2}' \
        | tr -d '\r\n ')
    # Belt-and-braces: refuse to proceed unless we got an actual sha256
    # digest. An empty/garbage value would otherwise be sed'd in.
    if [ -z "$latest_digest" ] || [ "${latest_digest#sha256:}" = "$latest_digest" ]; then
        new "Dockerfile  base image  (could not fetch manifest digest; skipping)"
        return 0
    fi
    if [ "$current_digest" = "$latest_digest" ]; then
        ok  "Dockerfile  base image (devcontainers/base:${tag})  ${current_digest:0:19}…"
    else
        new "Dockerfile  base image (devcontainers/base:${tag})  ${current_digest:0:19}…  ->  ${latest_digest:0:19}…"
        if prompt_apply; then
            sed -i.bak "s|@${current_digest}|@${latest_digest}|" Dockerfile
            rm -f Dockerfile.bak
        fi
    fi
}

# $3 is an extended regex applied to release tag_names. The first match
# wins (releases are returned newest-first). $4 is a prefix to strip from
# the tag before writing it back into the Dockerfile — leave empty to
# write the tag verbatim. Filtering by major version keeps cross-major
# bumps (Compose v2->v5, Docker engine 27->29) out of the auto-update path.
check_dockerfile_arg() {
    local arg="$1" repo="$2" pattern="$3" strip_prefix="$4"
    local current latest
    current=$(grep -E "^ARG ${arg}=" Dockerfile | head -1 | cut -d= -f2)
    if [ -z "$current" ]; then
        new "Dockerfile  ARG ${arg}  (not found)"
        return 0
    fi
    latest=$(gh_latest_tag_matching "$repo" "$pattern" || true)
    if [ -z "$latest" ]; then
        new "Dockerfile  ARG ${arg}  (no release matched /${pattern}/, or API lookup failed)"
        return 0
    fi
    if [ -n "$strip_prefix" ]; then
        latest="${latest#${strip_prefix}}"
    fi
    if [ -z "$latest" ]; then
        new "Dockerfile  ARG ${arg}  (stripped version was empty; skipping)"
        return 0
    fi
    if [ "$current" = "$latest" ]; then
        ok  "Dockerfile  ARG ${arg} = ${current}"
    else
        new "Dockerfile  ARG ${arg}: ${current}  ->  ${latest}"
        if prompt_apply; then
            sed -i.bak -E "s|^ARG ${arg}=.*|ARG ${arg}=${latest}|" Dockerfile
            rm -f Dockerfile.bak
        fi
    fi
}

# --- GitHub Actions ---------------------------------------------------------

check_action() {
    local file="$1" repo="$2" tag="$3"
    local current latest
    # Slashes are not metacharacters in extended REs — pass the repo
    # verbatim to grep -oE. Any 40-hex run right after '@' is the pin.
    current=$(grep -oE "${repo}@[0-9a-f]{40}" "$file" | head -1 | cut -d@ -f2)
    if [ -z "$current" ]; then
        new "${file}  ${repo}@${tag}  (no SHA-pin found in file)"
        return 0
    fi
    latest=$(action_sha "$repo" "$tag" || true)
    if [ -z "$latest" ]; then
        new "${file}  ${repo}@${tag}  (could not resolve latest SHA; skipping)"
        return 0
    fi
    if [ "$current" = "$latest" ]; then
        ok  "${file}  ${repo}@${tag}  ${current:0:12}"
    else
        new "${file}  ${repo}@${tag}: ${current:0:12}  ->  ${latest:0:12}"
        if prompt_apply; then
            sed -i.bak "s|${repo}@${current}|${repo}@${latest}|g" "$file"
            rm -f "${file}.bak"
        fi
    fi
}

# --- Lint tooling (scripts/lint.sh) -----------------------------------------
#
# Each pin is (version + sha256). When the version changes we must also
# refresh the sha256 — fetch the new binary, recompute, write both.

check_lint_pin() {
    local ver_var="$1" sha_var="$2" repo="$3" url_template="$4"
    local current latest tmp newsha url
    current=$(awk -v v="$ver_var" '
        $0 ~ "^"v"=" { sub("^"v"=", ""); gsub(/"/, ""); print; exit }
    ' scripts/lint.sh)
    latest=$(gh_latest_tag "$repo" || true)
    if [ -z "$latest" ]; then
        new "scripts/lint.sh  ${ver_var}  (could not resolve latest; skipping)"
        return 0
    fi
    latest="${latest#v}"
    if [ "$current" = "$latest" ]; then
        ok  "scripts/lint.sh  ${ver_var} = ${current}"
        return 0
    fi
    new "scripts/lint.sh  ${ver_var}: ${current}  ->  ${latest}"
    if ! prompt_apply; then return 0; fi
    url="${url_template//\{VERSION\}/$latest}"
    tmp=$(mktemp)
    echo "       fetching ${url} to recompute sha256..."
    if ! curl -fsSL "$url" -o "$tmp"; then
        echo "       FAILED to fetch ${url}; leaving lint.sh untouched." >&2
        rm -f "$tmp"
        return 0
    fi
    newsha=$(sha256sum "$tmp" | awk '{print $1}')
    rm -f "$tmp"
    sed -i.bak -E "s|^${ver_var}=\"${current}\"|${ver_var}=\"${latest}\"|" scripts/lint.sh
    sed -i.bak -E "s|^${sha_var}=\"[a-f0-9]{64}\"|${sha_var}=\"${newsha}\"|" scripts/lint.sh
    rm -f scripts/lint.sh.bak
    echo "       wrote ${ver_var}=${latest}, ${sha_var}=${newsha}"
}

# --- Run all checks --------------------------------------------------------

echo "=== mise.base.toml tools (baked into the container image) ==="
check_mise_tool mise.base.toml node "node@lts"
check_mise_tool mise.base.toml ripgrep
check_mise_tool mise.base.toml eza
check_mise_tool mise.base.toml lazygit
check_mise_tool mise.base.toml neovim

echo
echo "=== mise.toml tools (developer tooling for this repo) ==="
check_mise_tool mise.toml shellcheck
check_mise_tool mise.toml hadolint
check_mise_tool mise.toml actionlint
check_mise_tool mise.toml jq

echo
echo "=== Dockerfile ==="
check_base_image
# Track each ARG on its current major version family — see the comment on
# check_dockerfile_arg. Bump the patterns deliberately when adopting a new
# major (e.g. compose v2 -> v5, docker 27 -> 28).
check_dockerfile_arg MISE_VERSION    jdx/mise        '^v[0-9]+\.[0-9]+\.[0-9]+$' ''
check_dockerfile_arg DOCKER_VERSION  moby/moby       '^docker-v27\.[0-9]+\.[0-9]+$' 'docker-v'
check_dockerfile_arg COMPOSE_VERSION docker/compose  '^v2\.[0-9]+\.[0-9]+$'         'v'

echo
echo "=== GitHub Actions ==="
check_action .github/workflows/ci.yml             actions/checkout                v4
check_action .github/workflows/ci.yml             actions/cache                   v4
check_action .github/workflows/ci.yml             actions/upload-artifact         v4
check_action .github/workflows/release-please.yml googleapis/release-please-action v4

echo
echo "=== Lint tooling (scripts/lint.sh) ==="
check_lint_pin HADOLINT_VERSION   HADOLINT_SHA256_LINUX_X64 \
    hadolint/hadolint \
    "https://github.com/hadolint/hadolint/releases/download/v{VERSION}/hadolint-Linux-x86_64"
check_lint_pin ACTIONLINT_VERSION ACTIONLINT_SHA256_LINUX_X64 \
    rhysd/actionlint \
    "https://github.com/rhysd/actionlint/releases/download/v{VERSION}/actionlint_{VERSION}_linux_amd64.tar.gz"

echo
if [ "$stale" -eq 0 ]; then
    echo "All pinned dependencies are up to date."
    exit 0
fi
if [ "$APPLY" = "true" ]; then
    echo "${stale} update(s) found: ${applied} applied, ${skipped} skipped."
    if [ "$applied" -gt 0 ]; then
        echo "Review: git diff"
        echo "Then rebuild + lint: docker build -t generic-devcontainer . && bash scripts/lint.sh"
    fi
else
    echo "${stale} update(s) available. Rerun with --apply to approve them interactively."
fi
