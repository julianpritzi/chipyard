{
  description = "Chipyard, set up the same way on every Linux machine: run `nix develop`";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Chipyard's dependencies are the ones upstream pins in conda-reqs/conda-lock-reqs/,
  # installed by upstream's own build-setup.sh (see scripts/nix-shell.sh). Nix pins what
  # that runs on: the conda installer and a fixed Linux userland (an FHS sandbox, which is
  # also what lets conda's prebuilt binaries run on NixOS).
  outputs = { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      fhs = pkgs.buildFHSEnv {
        name = "chipyard";
        # The host packages upstream builds on: keep in sync with the apt-get list in
        # dockerfiles/Dockerfile (minus sudo and openssh-server, which a sandbox can't use),
        # plus zlib from its ubuntu base image, which the prebuilt firtool links against.
        targetPkgs = p: with p; [
          bc gcc gnumake bzip2 cacert curl findutils git gzip iputils kmod nettools
          netcat-openbsd openssh patch procps python3 gnutar unzip xz wget zlib
        ];
        profile = "export CY_MINIFORGE=${pkgs.fetchurl {
          url = "https://github.com/conda-forge/miniforge/releases/download/26.9.4-1/Miniforge3-26.9.4-1-Linux-x86_64.sh";
          hash = "sha256-VxtBAnLMQ08ovGxcScqP/UpNG8up9X8ba6zNtGRGz8w=";
        }}";
        runScript = "bash ${./scripts/nix-shell.sh}";
      };
      # The sandbox needs unprivileged user namespaces, which some hosts restrict (by default
      # Ubuntu >= 24.04, through AppArmor). Say how to allow them instead of failing cryptically.
      sandboxCheck = ''
        if ! err=$(${pkgs.bubblewrap}/bin/bwrap --dev-bind / / true 2>&1); then
          cat >&2 <<EOF
        error: the chipyard sandbox (bubblewrap) cannot start on this machine:
          $err
        It needs unprivileged user namespaces. Ubuntu >= 24.04 restricts them with AppArmor
        by default; allowing them for Nix's bubblewrap once fixes this:

          sudo tee /etc/apparmor.d/nix-bwrap <<'END'
          abi <abi/4.0>,
          include <tunables/global>
          profile nix-bwrap /nix/store/*/bin/bwrap flags=(unconfined) {
            userns,
          }
          END
          sudo apparmor_parser -r /etc/apparmor.d/nix-bwrap

        Or lift the restriction for the whole system (less secure):
          sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0

        Background:
          https://etbe.coker.com.au/2024/04/24/ubuntu-24-04-bubblewrap/
          https://discourse.nixos.org/t/arduino-cli-execution-failure/55453
        EOF
          exit 1
        fi
      '';
    in
    {
      # nix develop
      devShells.x86_64-linux.default = fhs.env.overrideAttrs (old: { shellHook = sandboxCheck + old.shellHook; });
      # nix run . -- <command>
      packages.x86_64-linux.default = pkgs.writeShellScriptBin "chipyard" (sandboxCheck + ''exec ${fhs}/bin/chipyard "$@"'');
    };
}
