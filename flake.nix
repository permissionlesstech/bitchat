{
  description = "BitChat — decentralized peer-to-peer mesh messaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            jq
            swiftlint
            xcbeautify
          ];

          shellHook = ''
            unset DEVELOPER_DIR SDKROOT
            unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            unset NIX_APPLE_SDK_VERSION NIX_BINTOOLS

            # Strip SDK-related Nix compiler wrapper vars (arch-dependent names)
            for var in $(env | grep -E '^NIX_(CC|BINTOOLS)_WRAPPER_' | cut -d= -f1); do
              unset "$var"
            done

            # System /usr/bin must come first so xcrun detects Xcode/CLT, not
            # the incompatible Nix SDK.
            export PATH="/usr/bin:/usr/sbin:$PATH"
          '';
        };
      });
    };
}
