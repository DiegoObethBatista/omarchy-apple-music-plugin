# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them privately
through GitHub: **Security → Report a vulnerability** on this repository
([direct link](https://github.com/DiegoObethBatista/omarchy-apple-music-plugin/security/advisories/new)).

Include what you found, how to reproduce it, and the plugin version
(`manifest.json`). You'll get a reply as soon as possible; fixes are released on
`main` and noted in the advisory.

## Scope

In scope: the launcher (`bin/`), the native-messaging bridge, the bundled
Chromium extension (`chromium/extension/`), and the QML widget/service.

Out of scope: Apple Music itself, Chromium, and Omarchy. Report those upstream.

See the README's **Security notes** for the design (owner-only runtime state,
command allow-lists, tokens kept inside the page).
