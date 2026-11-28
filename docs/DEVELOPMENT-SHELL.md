# macOS development shell

The root flake provides the same pinned auxiliary tools on Apple Silicon and
Intel macOS. It uses your selected, separately installed Xcode for Swift,
Apple SDKs, simulators, and signing. Xcode and macOS are not supplied or pinned
by Nix, so this is a reproducible tooling shell, not a reproducible app build.

Install full Xcode and Nix with flakes enabled. From the repository root run:

```sh
nix --extra-experimental-features 'nix-command flakes' develop
just check
just build
just test
```

`just build` makes an unsigned macOS development build. `just test-ios` uses
the simulator named in the [Justfile](../Justfile); create that simulator in
Xcode first. Bluetooth mesh behavior needs physical devices.

The shell includes `just`, Python 3, Git, jq, and SwiftLint. Its `swift` wrapper
calls `xcrun swift`, preserving the Xcode toolchain used by `xcodebuild`.
`mkShellNoCC` avoids injecting a competing compiler into Apple builds.
`DEVELOPER_DIR`, when supplied, takes precedence over `xcode-select`.
If Command Line Tools are selected instead of full Xcode, the shell prints a
setup hint and `just check` rejects that configuration. Complete Xcode's first
launch setup and license acceptance outside the shell.

The nixpkgs URL pins an immutable 26.05 Darwin revision that supports both
architectures. Newer nixpkgs releases can drop Intel macOS support, so check
both outputs before updating. The committed
`flake.lock` also records its content hash. To update intentionally,
change the pinned revision, regenerate the lock file, and check both Darwin
shells. See the [Nix flake documentation](https://wiki.nixos.org/wiki/Flakes)
and [nix develop reference](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-develop.html).

Swift dependencies remain governed by `Package.resolved` and the local
packages. Nix does not download Xcode, bypass signing, or build on Linux.
