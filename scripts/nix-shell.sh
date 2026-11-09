#!/usr/bin/env bash
# Entry point of `nix develop` and `nix run . -- <command>` (see flake.nix), run inside
# the FHS sandbox. Sets this checkout up with chipyard's own scripts the first time, and
# again whenever build-setup.conf, the conda lockfiles or the toolchain pins change.
# Then starts a shell, or runs the given command, with chipyard's env.sh sourced.
set -eo pipefail

# A conda on the host (`conda init`, an activated env) comes along through inherited variables
# and PATH, and would be used instead of the checkout's own one: drop it.
unset CONDA_SHLVL ${!CONDA_PREFIX*} CONDA_DEFAULT_ENV CONDA_PROMPT_MODIFIER CONDA_EXE _CONDA_EXE CONDA_PYTHON_EXE _CE_M _CE_CONDA
PATH=$(IFS=:; for d in $PATH; do [ -e "$d/../conda-meta" ] || printf '%s:' "$d"; done); PATH=${PATH%:}
# VS Code's snap puts its own GTK, GIO and locale paths into its terminals (keeping the originals
# in *_VSCODE_SNAP_ORIG), which breaks conda's GTK programs: restore the originals.
for v in $(compgen -e | sed -n 's/_VSCODE_SNAP_ORIG$//p'); do
    o=${v}_VSCODE_SNAP_ORIG; if [ -n "${!o}" ]; then export "$v=${!o}"; else unset "$v"; fi; unset "$o"
done

# the checkout this was started from, also when started from a subdirectory or submodule
cy=$PWD
until [ -e "$cy/build-setup.conf" ] || [ "$cy" = / ]; do cy=$(dirname "$cy"); done
[ -e "$cy/build-setup.conf" ] || { echo "error: not inside a chipyard checkout" >&2; exit 1; }

source "$cy/build-setup.conf"
stamp="$cy $GENERATORS $SETUP_FLAGS $(git -C "$cy" rev-parse HEAD:conda-reqs HEAD:toolchains)"
# re-running the setup checks out the recorded commit of each submodule, so don't while
# a submodule has commits that chipyard doesn't record yet
moved=$(git -C "$cy" submodule status --recursive | grep '^+' || true)
if [ -n "$CY_NO_SETUP" ] && [ "$(cat "$cy/.nix-setup-done" 2>/dev/null)" != "$stamp" ]; then
    echo "==> chipyard's setup hasn't run in $cy yet, or is out of date: run \`nix develop\` in a terminal." >&2
elif [ -e "$cy/.nix-setup-done" ] && [ "$(cat "$cy/.nix-setup-done")" != "$stamp" ] && [ -n "$moved" ]; then
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
    if [ ! -e "$cy/.vscode/settings.json" ]; then
        mkdir -p "$cy/.vscode"
        cat > "$cy/.vscode/settings.json" <<EOF
{
  // Written by scripts/nix-shell.sh after chipyard's setup; not tracked by git, so edit freely
  // (or delete it, e.g. after moving the checkout, to have it written again on the next setup).
  // VS Code terminals open in chipyard's Nix shell, without ever running the setup themselves.
  "terminal.integrated.profiles.linux": {
    "chipyard": { "path": "$(command -v nix || echo nix)", "args": ["run", "--no-warn-dirty", "$cy"], "env": { "CY_NO_SETUP": "1" } }
  },
  "terminal.integrated.defaultProfile.linux": "chipyard",
  // the conda installations hold most of the checkout's directories, too many to watch
  "files.watcherExclude": { "**/.conda-*/**": true },
  // chipyard's Scala code isn't formatted with scalafmt: formatting on save would rewrite whole files
  "[scala]": { "editor.formatOnSave": false }
}
EOF
    fi
fi

activate="source '$cy/.conda-base/etc/profile.d/conda.sh' && source '$cy/env.sh'"
prompt='PS1="(chipyard) ${PS1#"$CONDA_PROMPT_MODIFIER"}"; CONDA_PROMPT_MODIFIER="(chipyard) "'
[ -e "$cy/env.sh" ] || activate=: prompt=: # not set up yet (only with CY_NO_SETUP)
if [ $# -eq 0 ]; then
    exec bash --rcfile <(echo "[ -f ~/.bashrc ] && source ~/.bashrc; $activate; $prompt") -i
fi
eval "$activate"
exec "$@"
