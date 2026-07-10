# BitChat developer commands
#
# Builds use a repository-local, ignored DerivedData directory. No recipe
# patches, restores, or removes tracked project/configuration files.

project := "bitchat.xcodeproj"
macos_scheme := "bitchat (macOS)"
ios_scheme := "bitchat (iOS)"
derived_data := ".DerivedData"

default:
    @echo "BitChat developer commands:"
    @echo "  just run                Build and run the macOS app"
    @echo "  just build              Build the macOS app without signing"
    @echo "  just test               Run the SwiftPM test suite"
    @echo "  just test-ios           Run tests on the iPhone 17 simulator"
    @echo "  just clean              Remove repo-local build artifacts only"
    @echo "  just nuke               Also remove nested package build caches"
    @echo "  just check              Validate the development environment"

# Static guard against reintroducing source-restoring or source-deleting clean
# behavior. CI runs the same script directly.
check-clean-safety:
    @bash scripts/check-just-clean-safety.sh

check: check-clean-safety
    @echo "Checking prerequisites..."
    @command -v xcodebuild >/dev/null 2>&1 || (echo "❌ xcodebuild not found. Install full Xcode." && exit 1)
    @developer_dir="$$(xcode-select -p 2>/dev/null)"; case "$$developer_dir" in *.app/Contents/Developer) ;; *) echo "❌ Full Xcode is not selected. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; exit 1;; esac
    @xcodebuild -version
    @echo "✅ Development environment ready (a signing identity is not required for just build)"

build: check
    @echo "Building BitChat for macOS..."
    @xcodebuild -project "{{project}}" -scheme "{{macos_scheme}}" -configuration Debug -derivedDataPath "{{derived_data}}" CODE_SIGNING_ALLOWED=NO build

run: build
    @app="{{derived_data}}/Build/Products/Debug/bitchat.app"; test -d "$$app" || (echo "❌ Built app not found at $$app" && exit 1); open "$$app"

# Backward-compatible alias for the old quick-run recipe.
dev-run: run

test:
    @swift test

test-ios: check
    @xcodebuild -project "{{project}}" -scheme "{{ios_scheme}}" -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath "{{derived_data}}" test

# Artifact-only cleanup. In particular, this recipe never invokes Git and
# never writes, moves, restores, or removes source/configuration files.
clean:
    @echo "Cleaning repo-local build artifacts..."
    @rm -rf -- "{{derived_data}}" ".build"
    @echo "✅ Cleaned {{derived_data}} and .build; tracked files were untouched"

# Retain the familiar command, but keep it artifact-only as well.
nuke: clean
    @echo "Cleaning nested package build caches..."
    @find localPackages -type d -name .build -prune -exec rm -rf -- {} +
    @rm -rf -- ".cache"
    @echo "✅ Removed repository build caches; tracked files were untouched"

info:
    @echo "BitChat - decentralized mesh messaging"
    @echo "macOS 13+ and iOS 16+"
    @echo "Bluetooth mesh behavior requires physical Bluetooth-capable devices"
