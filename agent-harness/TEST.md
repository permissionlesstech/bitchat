# BitChat CLI-Anything Test Plan

The harness is tested at two levels:

- `test_core.py` covers command-neutral pieces: JSONL formatting, history
  storage, session state, undo/redo, and backend output parsing.
- `test_full_e2e.py` invokes the installed-style CLI through Click's runner
  with a fake backend.
- `test_live_service.py` covers live-service backend routing without requiring
  Bluetooth hardware or macOS permissions.

Manual live validation is still machine-state dependent because Bluetooth and
macOS TCC prompts are local user state.

Validation commands:

```bash
python -m pytest agent-harness/cli_anything/bitchat/tests
swift test --filter BitchatHarnessServiceTests
pip install -e agent-harness
cli-anything-bitchat --json status
cli-anything-bitchat --json service start
cli-anything-bitchat --json --backend live status
cli-anything-bitchat --json --backend live send --text "agent harness smoke"
cli-anything-bitchat --json service stop
```
