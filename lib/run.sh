#!/usr/bin/env bash
# Build and execute the `docker run` that a language runner needs.
#
# Mount the working directory at its own absolute path and run as the host's uid.
# Editing inside the container edits the real files, and nothing lands owned by
# root.
#
# A container run normally discards whatever it installed, which would mean
# `pip install` again on every invocation. The goal here is to pin a project's
# packages, so installs go into .venv / node_modules in the project directory and
# stay there. The container is disposable; the environment it builds is not.

set -euo pipefail

DR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine.sh
. "$DR_LIB/engine.sh"

# Shared, on the host, so it is owned by the same uid the container runs as.
# A named docker volume would start out root-owned and need chown'ing on every
# first use; a host directory sidesteps that entirely.
DR_CACHE="${DOCKER_RUN_CACHE:-$HOME/.cache/docker-run}"

# Read a per-directory setting, trying the ecosystem's own filename first.
# .python-version already exists in the wild (pyenv, asdf); inventing a second
# spelling for it would mean projects carrying both.
dr_setting() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && { tr -d '[:space:]' < "$f"; return 0; }
  done
  return 1
}

# Populates the global DR_ARGS. A global rather than a printed list because
# macOS still ships bash 3.2 as /bin/bash — no mapfile, no readarray — and this
# is meant to be sourced from a Mac's .bashrc.
dr_docker_args() {
  local image="$1"; shift
  mkdir -p "$DR_CACHE"

  local tty_flag="-i"
  # -t only when both ends are a terminal. docker refuses -t on piped stdin
  # ("the input device is not a TTY"), which breaks `echo x | py -`.
  [ -t 0 ] && [ -t 1 ] && tty_flag="-it"

  DR_ARGS=(
    run --rm "$tty_flag"
    -v "$PWD:$PWD" --workdir "$PWD"
    -u "$(id -u):$(id -g)"
    -v "$DR_CACHE:/cache"
    # Running as a uid with no passwd entry leaves HOME unset, and pip and npm
    # both fall over or scatter files when that happens. Point it at the shared
    # cache so downloads survive between runs.
    -e "DR_MARKER_NAME=$DR_MARKER"
    -e "HOME=/cache/home"
    -e "PIP_CACHE_DIR=/cache/pip"
    -e "npm_config_cache=/cache/npm"
  )

  # Optional per-directory extras, read from dotfiles beside the code.
  [ -f .docker-run.env ] && DR_ARGS+=(--env-file .docker-run.env)
  if [ -f .docker-run.ports ]; then
    local p
    while read -r p; do [ -n "$p" ] && DR_ARGS+=(-p "$p"); done < .docker-run.ports
  fi
  local net
  net="$(dr_setting .docker-run.network 2>/dev/null || true)"
  [ -n "$net" ] && DR_ARGS+=(--network "$net")

  DR_ARGS+=("$image")
}

# Run a shell snippet inside the image. Everything a language runner needs to do
# — create a venv, install, then exec — is a small script, and passing it as one
# string keeps the quoting in one place instead of spread across each runner.
# A bind mount whose host path is not shared into the VM does not fail — docker
# silently creates an empty directory at that path instead. Under Colima only
# some host paths reach the VM (the home directory does; /tmp does not), so the
# container can end up working in a phantom directory: .venv is created, packages
# install, everything reports success, and nothing exists on the host afterwards.
#
# Cheaper to detect than to explain after the fact. Drop a marker on the host and
# have the container confirm it can see it.
DR_MARKER=".docker-run-mount-check"

dr_mount_guard() {
  cat <<'GUARD'
if [ ! -e "$DR_MARKER_NAME" ]; then
  echo "docker-run: this directory is not shared with the Docker VM." >&2
  echo "" >&2
  echo "  The container sees an empty directory at $PWD, so anything it" >&2
  echo "  wrote would vanish. Nothing has been changed." >&2
  echo "" >&2
  echo "  Colima only shares some host paths — your home directory is shared," >&2
  echo "  /tmp is not. Either work somewhere under \$HOME, or add this path:" >&2
  echo "    colima stop && colima start --mount '$PWD:w'" >&2
  exit 78
fi
rm -f "$DR_MARKER_NAME"
GUARD
}

dr_exec() {
  local image="$1" script="$2"; shift 2
  dr_use_engine >/dev/null || return 1
  # Created here, removed by the guard inside the container. If the container
  # cannot see it, the host still can — so clean it up on the way out too.
  : > "$DR_MARKER"
  trap 'rm -f "$DR_MARKER"' EXIT
  script="$(dr_mount_guard)
$script"
  DR_ARGS=()
  dr_docker_args "$image"
  # `bash -lc SCRIPT NAME ARGS...` — the word after the script becomes $0, so the
  # caller's arguments start at $1 inside it. Forgetting that placeholder makes
  # the first user argument silently vanish into $0.
  if [ "${DOCKER_RUN_PRINT:-0}" = "1" ]; then
    printf 'docker'; printf ' %q' "${DR_ARGS[@]}" 'bash' '-lc' "$script" 'docker-run' "$@"; printf '\n'
    return 0
  fi
  exec docker "${DR_ARGS[@]}" bash -lc "$script" docker-run "$@"
}

# The shell that makes sure .venv exists and matches the image's python. Shared
# by py and pi: two copies of the version-stamp rule would drift, and that rule
# is the one thing standing between a changed .python-version and a venv whose
# packages have silently stopped existing.
dr_venv_prep() {
  cat <<'PREP'
set -euo pipefail

# A venv is bound to one minor version: its packages live in
# lib/pythonX.Y/site-packages, while bin/python is a symlink that follows
# whatever the image provides. Change .python-version and the interpreter moves
# but the packages do not — every import fails with ModuleNotFoundError and
# nothing says why. Stamp the version and rebuild when it moves.
want="$(python -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
stamp=".venv/.docker-run-python"
if [ -x .venv/bin/python ] && [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  echo "docker-run: python $(cat "$stamp" 2>/dev/null || echo unknown) -> $want, rebuilding .venv" >&2
  echo "docker-run: requirements.txt will be reinstalled; anything installed ad-hoc is lost" >&2
  rm -rf .venv
fi

if [ ! -x .venv/bin/python ]; then
  echo "docker-run: creating .venv (python $(python --version 2>&1 | cut -d" " -f2))" >&2
  python -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  if [ -f requirements.txt ]; then
    echo "docker-run: installing requirements.txt" >&2
    .venv/bin/pip install --quiet -r requirements.txt
  fi
  echo "$want" > "$stamp"
fi
# Ends here on purpose: this prepares the venv and hands control back. Each
# command appends its own exec — py runs python, pi runs pip. An exec left in
# here would mean pi never reached its own body.
export PATH="$PWD/.venv/bin:$PATH"
PREP
}
