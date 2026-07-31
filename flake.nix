{
  description = "bitchat development shell helpers (Xcode still required to build the app)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              git
              jq
              python3
              # Swift/Xcode come from Apple; nix does not replace Xcode.app.
            ];
            shellHook = ''
              echo "bitchat nix shell: tooling only."
              echo "Build/test still need a full Xcode install (xcode-select -p)."
              if ! xcode-select -p >/dev/null 2>&1; then
                echo "WARNING: xcode-select cannot find Xcode developer tools." >&2
              fi
            '';
          };
        });
    };
}
