#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"

run_box() {  # run box in a throwaway project dir, dry-run, provisioned, hermetic state
  local proj; proj="$(mktemp -d)"
  ( cd "$proj" && XDG_STATE_HOME="$proj/.state" BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 "$ROOT/box" "$@" )
}

# default: boots a detached named sandbox then attaches a shell
def="$(run_box)"
assert_contains "$def" "msb run -d --replace --name box-" "default boots detached sandbox"
assert_contains "$def" "--net-default-egress deny" "default run is locked down"
assert_contains "$def" "msb exec" "default attaches a shell"

# one-off command
oneoff="$(run_box -- echo hello)"
assert_contains "$oneoff" "msb exec" "one-off uses exec"
assert_contains "$oneoff" "-- echo hello" "one-off passes command"

# provision: open egress
prov="$(run_box provision)"
assert_contains "$prov" "--net-default-egress allow" "provision opens egress"
assert_contains "$prov" "mise install" "provision installs tools"

# net override none -> deny, no allow rules
none="$(run_box --net none)"
assert_contains "$none" "--net-default-egress deny" "net none denies"
assert_eq "" "$(echo "$none" | grep -o 'allow@' || true)" "net none has no allow rules"

# help
help="$(run_box --help)"
assert_contains "$help" "Usage" "help shows usage"

# --net validation: invalid value exits 2
rc=0; out_badnet="$(run_box --net bogus 2>&1)" || rc=$?
assert_eq "2" "$rc" "invalid --net value exits 2"
assert_contains "$out_badnet" "none|sanctioned|full" "invalid --net explains valid values"

# --net validation: missing value exits 2 (not an unbound-variable crash)
rc2=0; out_missing="$(run_box --net 2>&1)" || rc2=$?
assert_eq "2" "$rc2" "missing --net argument exits 2"

# down stops the sandbox
down="$(run_box down)"
assert_contains "$down" "msb stop box-" "down stops the sandbox"

# reset stops, removes, and clears the marker
reset="$(run_box reset)"
assert_contains "$reset" "msb stop box-" "reset stops the sandbox"
assert_contains "$reset" "msb rm box-" "reset removes the sandbox"

# provision --shell: interactive open-egress root shell in /workspace
pshell="$(run_box provision --shell)"
assert_contains "$pshell" "msb run" "provision --shell runs a sandbox"
assert_contains "$pshell" "--net-default-egress allow" "provision --shell has open egress"
assert_contains "$pshell" "--workdir /workspace" "provision --shell lands in workspace"
assert_contains "$pshell" "/usr/bin/bash" "provision --shell opens a shell"

# provision -- CMD: one-off open-egress command
pcmd="$(run_box provision -- apt-get update)"
assert_contains "$pcmd" "--net-default-egress allow" "provision one-off open egress"
assert_contains "$pcmd" "-- apt-get update" "provision one-off passes command"

# plain provision still installs mise (non-interactive), not a shell
pplain="$(run_box provision)"
assert_contains "$pplain" "mise install" "plain provision installs mise"

# Missing msb binary -> clear install guidance, exit 1 (real path, not dry-run).
proj_nomsb="$(mktemp -d)"
rc3=0
out_nomsb="$( cd "$proj_nomsb" && MSB_BIN=/nonexistent/msb BOX_ASSUME_PROVISIONED=1 "$ROOT/box" -- true 2>&1 )" || rc3=$?
assert_eq "1" "$rc3" "missing msb exits 1"
assert_contains "$out_nomsb" "install.microsandbox.dev" "missing msb shows install hint"

# --- custom base image (BOX_IMAGE / .box-image / box build) ---

# default run uses the default base image
assert_contains "$def" "mcr.microsoft.com/devcontainers/base:ubuntu" "default uses the default image"

# BOX_IMAGE env overrides the run image
proji="$(mktemp -d)"
out_env="$( cd "$proji" && XDG_STATE_HOME="$proji/.state" BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 BOX_IMAGE=my/img:1 "$ROOT/box" -- true )"
assert_contains "$out_env" "my/img:1" "BOX_IMAGE pins the run image"

# .box-image file pins the run image when BOX_IMAGE is unset
projf="$(mktemp -d)"; printf '# project image\nmy/custom:tag\n' > "$projf/.box-image"
out_file="$( cd "$projf" && XDG_STATE_HOME="$projf/.state" BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 "$ROOT/box" -- true )"
assert_contains "$out_file" "my/custom:tag" ".box-image pins the run image"

# BOX_IMAGE wins over .box-image
out_both="$( cd "$projf" && XDG_STATE_HOME="$projf/.state" BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 BOX_IMAGE=env/wins:1 "$ROOT/box" -- true )"
assert_contains "$out_both" "env/wins:1" "BOX_IMAGE overrides .box-image"

# box build without Dockerfile.box -> error, exit 1
projb="$(mktemp -d)"
rcb=0
out_nobf="$( cd "$projb" && BOX_DRY_RUN=1 "$ROOT/box" build 2>&1 )" || rcb=$?
assert_eq "1" "$rcb" "build without Dockerfile.box exits 1"
assert_contains "$out_nobf" "Dockerfile.box" "build explains the missing Dockerfile.box"

# box build with Dockerfile.box -> builds, loads, pins .box-image
projc="$(mktemp -d)"; printf 'FROM scratch\n' > "$projc/Dockerfile.box"
tagc="box-$(basename "$projc"):local"
out_build="$( cd "$projc" && BOX_DRY_RUN=1 BOX_BUILDER=docker "$ROOT/box" build 2>&1 )"
assert_contains "$out_build" "docker build -f $projc/Dockerfile.box -t $tagc" "build invokes the builder"
assert_contains "$out_build" "msb image load --tag $tagc" "build loads the image into msb"
assert_eq "$tagc" "$(cat "$projc/.box-image")" "build pins the tag in .box-image"

# --- docker-in-sandbox mode (--docker / .box-docker) ---

# --docker adds a disk-backed docker volume, memory, a dockerd boot entrypoint,
# and the registry allowlist.
dock="$(run_box --docker 2>/dev/null)"
assert_contains "$dock" "--mount-named box-docker:/var/lib/docker:kind=disk" "docker mode mounts a disk-backed docker volume"
assert_contains "$dock" "--memory 2G" "docker mode bumps memory"
assert_contains "$dock" "--entrypoint boxdockerd" "docker mode starts dockerd at boot"
assert_contains "$dock" "allow@registry-1.docker.io:tcp:443" "docker mode allowlists Docker Hub"

# default run has none of the docker wiring
assert_eq "" "$(echo "$def" | grep -o 'box-docker:/var/lib/docker' || true)" "default run has no docker volume"
assert_eq "" "$(echo "$def" | grep -o 'registry-1.docker.io' || true)" "default run does not allowlist registries"

# a .box-docker marker enables docker mode without the flag
projm="$(mktemp -d)"; : > "$projm/.box-docker"
out_marker="$( cd "$projm" && XDG_STATE_HOME="$projm/.state" BOX_DRY_RUN=1 BOX_ASSUME_PROVISIONED=1 "$ROOT/box" -- true 2>/dev/null )"
assert_contains "$out_marker" "--entrypoint boxdockerd" ".box-docker enables docker mode"

finish
