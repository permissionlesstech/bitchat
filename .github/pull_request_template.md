## Summary

<!-- One or two sentences describing what this PR changes and why. -->

## Problem

<!-- What problem does this PR solve? Link any related issues. -->

## Change

<!-- Describe the change. Focus on *why* this is the right fix, not just *what*. -->

## Test plan

<!-- How did you verify this? Which test suites did you run? -->

- [ ] `swift test` (or `just test`)
- [ ] `just test-ios` (if app code changed)
- [ ] `python3 -m unittest discover -s scripts/tests -p "test_*.py" -v` (if `scripts/` changed)
- [ ] Manual smoke test on device/simulator (if UI or transport changed)

## Checklist

- [ ] The change is focused (one logical change per PR)
- [ ] Tests are included or updated
- [ ] `swiftlint` is clean (if Swift code changed)
- [ ] The README and relevant `docs/` are updated (if behaviour changed)
- [ ] No security-sensitive behaviour was changed without a security review (see [SECURITY.md](../SECURITY.md))
