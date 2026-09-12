# docker-run

Run Python and TypeScript in Docker, with each project's packages pinned to that
project's directory. No pyenv, no nvm, no version managers on the host — the only
thing you install is Docker.

The working directory is mounted into the container at its own absolute path and
the container runs as your uid, so editing inside it edits the real files and
nothing lands owned by root. The container is the disposable part; what it builds
in the project directory is not.

```bash
./install.sh          # puts bin/ on PATH
docker-run doctor     # which engine, and does it actually work
```

```bash
py                    # REPL
py script.py          # run a script
py -m pytest

pi                    # install requirements.txt
pi requests httpx     # install specific packages

ts                    # REPL
ts script.ts          # run TypeScript directly — no build step, no tsconfig needed
```

## The environment persists; the container does not

A container run normally discards whatever it installed, which would mean
`pip install` every single time. Here installs land in the project directory and
stay:

| | Python | TypeScript |
|---|---|---|
| where packages live | `.venv/` | `node_modules/` |
| created on | first `py` in the directory | first `ts` in the directory |
| seeded from | `requirements.txt` | `package.json` |

`requirements.txt` is installed for you when `.venv` is first created. After that,
edit it and run `pi`. Syncing on every `py` instead would put a pip resolve in
front of every command, including `py -c 'print(1)'`.

Bare `pi` installs `requirements.txt`; given package names it installs those.
There is deliberately no bare `pip` on `PATH`: that would shadow the system pip in
every directory, including ones where you want nothing to do with a container.

`node_modules` rather than something venv-shaped because node already keeps
packages per directory — anything else would be fighting npm instead of using it.
TypeScript runs through `tsx`, installed into the project's own `node_modules`, so
a `.ts` file runs as written.

**The `.venv` is a Linux virtualenv.** It is built inside the container and its
binaries are Linux ones, so don't expect to activate it from macOS. It is a
package set that belongs to this directory, not a host toolchain.

## Pinning a version

```bash
echo 3.11 > .python-version     # or .python.version
echo 22   > .node-version       # or .nvmrc
```

Defaults are Python 3.12 and Node 22. These are the filenames pyenv and nvm
already use, so a project that has them needs no extra file.

Changing `.python-version` rebuilds `.venv`, because a virtualenv's packages live
in `lib/pythonX.Y/site-packages` while its `bin/python` follows whatever the image
provides. Left alone, the interpreter would move and every import would fail with
`ModuleNotFoundError` and no hint as to why. The rebuild reinstalls
`requirements.txt`; anything installed ad-hoc is lost, and it says so.

## Per-directory extras

| file | effect |
|---|---|
| `.docker-run.env` | passed as `--env-file` |
| `.docker-run.ports` | one `host:container` per line |
| `.docker-run.network` | `--network` (e.g. `host`) |

## Which Docker

Auto-detected, in this order: `DOCKER_RUN_ENGINE` if you set it, then Docker
Desktop if its daemon answers, then Colima — started for you if it is installed
but down.

`DOCKER_CONTEXT` is always set explicitly and never inherited. Docker Desktop
rewrites `currentContext` in `~/.docker/config.json` every time it launches, so
inheriting it means an update prompt appearing on your machine can silently
repoint a build at a daemon you never tested against.

The check is "does it answer", not "is it configured" — a Docker Desktop mid-update
replies to `docker version` while its path to the registry is dead. `docker-run
doctor` goes further and pulls an image, because that is the cheapest thing that
exercises the whole path.

```
export DOCKER_RUN_ENGINE=desktop   # or colima
```

## If a directory is not shared with the VM

Colima shares only some host paths — your home directory yes, `/tmp` no. A bind
mount of an unshared path does not fail: Docker creates an empty directory at that
path inside the VM, so a container can appear to work, install packages, report
success, and leave nothing behind on the host.

Every run drops a marker file and has the container confirm it can see it. If it
cannot, the run stops before doing anything:

```
docker-run: this directory is not shared with the Docker VM.
  The container sees an empty directory at /tmp/x, so anything it
  wrote would vanish. Nothing has been changed.
```

Work under `$HOME`, or `colima start --mount '/your/path:w'`.

## Caches

Shared at `~/.cache/docker-run` (`DOCKER_RUN_CACHE` to move it), holding pip and
npm caches and the container's `HOME`. A host directory rather than a named volume
because it is already owned by the right uid — a named volume starts out root-owned
and would need chown'ing on first use of every project.

## Notes

Bash 3.2 compatible, because that is what macOS still ships as `/bin/bash` and
this is meant to be sourced from a Mac's shell profile.
