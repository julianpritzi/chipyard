#!/usr/bin/env bash
# Entry point of `nix develop` and `nix run . -- <command>` (see flake.nix), run inside
# the FHS sandbox. Sets this checkout up with chipyard's own scripts the first time, and
# again whenever build-setup.conf, the conda lockfiles or the toolchain pins change.
# Then starts a shell, or runs the given command, with chipyard's env.sh sourced.
set -eo pipefail

# the checkout this was started from, also when started from a subdirectory or submodule
cy=$PWD
until [ -e "$cy/build-setup.conf" ] || [ "$cy" = / ]; do cy=$(dirname "$cy"); done
[ -e "$cy/build-setup.conf" ] || { echo "error: not inside a chipyard checkout" >&2; exit 1; }

source "$cy/build-setup.conf"
stamp="$cy $GENERATORS $SETUP_FLAGS $(git -C "$cy" rev-parse HEAD:conda-reqs HEAD:toolchains)"
# re-running the setup checks out the recorded commit of each submodule, so don't while
# a submodule has commits that chipyard doesn't record yet
moved=$(git -C "$cy" submodule status --recursive | grep '^+' || true)
if [ -e "$cy/.nix-setup-done" ] && [ "$(cat "$cy/.nix-setup-done")" != "$stamp" ] && [ -n "$moved" ]; then
    echo "==> Not re-running chipyard's setup, although build-setup.conf, conda-reqs/, toolchains/ or" >&2
    echo "    the checkout's location changed: it would check out the recorded commit in these" >&2
    echo "    submodules. Record yours first (git add <path>), then enter the shell again:" >&2
    echo "$moved" | sed 's/^/      /' >&2
elif [ "$(cat "$cy/.nix-setup-done" 2>/dev/null)" != "$stamp" ]; then
    echo "==> Running chipyard's setup in $cy: first entry, or build-setup.conf, conda-reqs/," >&2
    echo "    toolchains/ or the checkout's location changed. Takes ~30 min. Like ./build-setup.sh," >&2
    echo "    it checks out the pinned commit of every submodule it sets up." >&2
    (
        cd "$cy"
        export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 # abort stalled clones (git retries once)
        rm -rf .nix-setup-done .conda-env .conda-lock-env env.sh
        bash "$CY_MINIFORGE" -b -u -p .conda-base
        source .conda-base/etc/profile.d/conda.sh
        scripts/init-submodules-no-riscv-tools.sh $GENERATORS
        CY_KEEP_LOCKFILE=1 ./build-setup.sh riscv-tools --skip-submodules $SETUP_FLAGS
    )
    echo "$stamp" > "$cy/.nix-setup-done"
fi

activate="source '$cy/.conda-base/etc/profile.d/conda.sh' && source '$cy/env.sh'"
if [ $# -eq 0 ]; then
    exec bash --rcfile <(echo "[ -f ~/.bashrc ] && source ~/.bashrc; $activate") -i
fi
eval "$activate"
exec "$@"
