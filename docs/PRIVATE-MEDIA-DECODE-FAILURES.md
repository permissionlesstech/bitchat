# Private media decode failures (#1518)

When authenticated private media fails local validation, bitchat now:

1. Logs a structured reason code (`PrivateMediaDecodeFailureReason.logLabel`).
2. Posts a **system line in the affected DM** with a people-readable explanation.
3. Cross-links Android↔iOS interop notes for malformed payloads.

Public mesh file transfers keep the existing security logging path without spamming the mesh timeline.

See also: [ANDROID-IOS-MEDIA-INTEROP.md](./ANDROID-IOS-MEDIA-INTEROP.md) (if present in tree).
