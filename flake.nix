{
  description = "BitChat macOS development tools with the selected Apple Xcode";

  # Pin the input revision so the tools do not drift before a lock file exists.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c9fe7d12cd78d1adcd12dd15e24432dde5b155a0";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          # Resolve Swift through Xcode rather than adding a second Swift/SDK.
          appleSwift = pkgs.writeShellScriptBin "swift" ''
            exec /usr/bin/xcrun swift "$@"
          '';
        in {
          default = pkgs.mkShellNoCC {
            packages = [ pkgs.just pkgs.python3 pkgs.git pkgs.jq pkgs.swiftlint appleSwift ];
            shellHook = ''
              if [ -z "''${DEVELOPER_DIR:-}" ]; then
                export DEVELOPER_DIR="$(/usr/bin/xcode-select -p 2>/dev/null)"
              fi
              case "$DEVELOPER_DIR" in
                *.app/Contents/Developer)
                  if /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then
                    echo "BitChat shell ready. Run just check, just build, or just test."
                  else
                    echo "Xcode is selected but not ready. Complete its first launch setup."
                  fi
                  ;;
                *)
                  echo "Select full Xcode before building; Command Line Tools alone are insufficient."
                  echo "Use xcode-select or set DEVELOPER_DIR, then run just check."
                  ;;
              esac
            '';
          };
        });
    };
}
