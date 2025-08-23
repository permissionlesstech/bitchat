## Contributing to BitChat Localization

Thanks for helping localize BitChat. This guide covers adding or improving translations.

Scope
- Localize user-facing UI text only: menus, labels, help/usage, errors, toasts, accessibility.
- Do not localize chat content or command tokens (e.g., `/msg`, `/w`).

Where strings live
- UI strings: `bitchat/Localization/Localizable.xcstrings` (all locales).
- Permission prompts: `bitchat/Localization/<locale>.lproj/InfoPlist.strings`.

Keys and conventions
- Namespaces: `nav.*`, `settings.*`, `cmd.<id>.title`, `cmd.<id>.help`, `errors.*`, `toast.*`, `accessibility.*`, `placeholder.*`.
- Keep keys stable; do not hardcode strings in views.

Add a new locale
1) Add translations in `Localizable.xcstrings` (Xcode editor recommended).
2) Create `bitchat/Localization/<locale>.lproj/InfoPlist.strings` and copy Base keys.
3) Run tests and verify:
   - Unit tests: localization lookups and Base fallback.
   - Optional UI: run Simulator with launch args `-AppleLanguages (xx) -AppleLocale xx_YY`.

Testing
- Unit tests live under `bitchatTests/LocalizationTests.swift`.
- CI builds and packages the String Catalog and InfoPlist strings automatically (see `project.yml`).

Review checklist
- Translations are concise and consistent in tone.
- Usage/help strings explain arguments, but tokens remain canonical.
- RTL strings render without clipping; use shorter phrasing if needed.
