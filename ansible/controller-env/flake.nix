{
  # Ansible controller Python environment.
  #
  # The O-X-L OPNsense collection (oxlorg.opnsense) talks to the OPNsense API
  # via the `httpx` python module (a hard requirement — see the collection's
  # requirements.txt). The nix-store python that ships with the devbox `ansible`
  # package is read-only and has no httpx, so the frr_* modules fail to import.
  #
  # This flake builds a python that bundles httpx, pinned to the SAME nixpkgs
  # revision devbox resolved `ansible@latest` from (python 3.13.13), so the
  # interpreter ABI matches ansible-core. Point ansible at it with:
  #
  #   ANSIBLE_PYTHON_INTERPRETER=$(nix build --no-link --print-out-paths \
  #     path:./ansible/controller-env)/bin/python3
  #
  # Reproducible + declarative: the pin lives here and in flake.lock, not in an
  # ephemeral `pip install`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d849bb215dcdf71bce3e686839ccdb4219e84b2f";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      packages.${system}.default =
        pkgs.python313.withPackages (ps: [ ps.httpx ]);
    };
}
