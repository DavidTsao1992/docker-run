#!/usr/bin/env bash
# Pick a Docker daemon, and be sure it is actually there.
#
# Two engines are common on a Mac and they do not cooperate. Docker Desktop
# rewrites `currentContext` in ~/.docker/config.json every time it launches, so
# whichever one you meant to use is not necessarily the one a bare `docker`
# command talks to — an update prompt appearing is enough to silently repoint a
# build at a daemon you never tested against. Everything here therefore sets
# DOCKER_CONTEXT explicitly and never inherits it.
#
# The check is "does it answer", not "is it configured". Those differ: a Docker
# Desktop mid-update answers `docker version` while its registry path is dead.
# Configuration is a claim; a reachable daemon is a fact.

set -euo pipefail

DR_DESKTOP_SOCK="$HOME/.docker/run/docker.sock"
DR_COLIMA_SOCK="$HOME/.colima/default/docker.sock"

dr_have() { command -v "$1" >/dev/null 2>&1; }

# Does this context have a daemon behind it right now?
dr_context_alive() {
  local ctx="$1"
  DOCKER_CONTEXT="$ctx" timeout 10 docker info >/dev/null 2>&1
}

dr_pick_engine() {
  # 1. An explicit choice always wins. Someone who set this meant it, and
  #    silently overriding them is how the Desktop problem happens in reverse.
  if [ -n "${DOCKER_RUN_ENGINE:-}" ]; then
    case "$DOCKER_RUN_ENGINE" in
      desktop) echo "desktop-linux"; return 0 ;;
      colima)  echo "colima";        return 0 ;;
      *)       echo "$DOCKER_RUN_ENGINE"; return 0 ;;
    esac
  fi
  if [ -n "${DOCKER_HOST:-}" ]; then echo "__dockerhost__"; return 0; fi

  # 2. Docker Desktop, if its socket is there AND the daemon replies. The socket
  #    alone is not enough: it survives the app being quit.
  if [ -S "$DR_DESKTOP_SOCK" ] && dr_context_alive desktop-linux; then
    echo "desktop-linux"; return 0
  fi

  # 3. Colima. Start it if it is installed but down — that is the whole point of
  #    a runner: you asked to run something, not to administer a VM.
  if dr_have colima; then
    if dr_context_alive colima; then echo "colima"; return 0; fi
    echo "docker-run: colima is not running, starting it…" >&2
    if colima start >&2 && dr_context_alive colima; then echo "colima"; return 0; fi
  fi

  # 4. Neither. Say what to do rather than what failed.
  cat >&2 <<'MSG'
docker-run: no usable Docker daemon.

  Docker Desktop: install it, or open it if it is already installed —
                  its socket exists even while the app is quit, so
                  "installed" and "running" are different things here.
  Colima:         brew install colima && colima start

  If you have one but want the other:  export DOCKER_RUN_ENGINE=desktop|colima
MSG
  return 1
}

# Export DOCKER_CONTEXT for everything downstream. Callers just source this.
dr_use_engine() {
  local ctx
  ctx="$(dr_pick_engine)" || return 1
  if [ "$ctx" = "__dockerhost__" ]; then
    # DOCKER_HOST outranks DOCKER_CONTEXT in the CLI, so leaving the context set
    # alongside it would be a lie in `docker-run doctor` output.
    unset DOCKER_CONTEXT || true
    echo "${DOCKER_HOST}"
    return 0
  fi
  export DOCKER_CONTEXT="$ctx"
  echo "$ctx"
}
