# MailMate releases

Sparkle update feed for MailMate, a macOS menu-bar app that drafts Apple Mail
replies with Claude.

- `appcast.xml` — the feed installed copies check once a day
- `downloads/` — notarized disk images + release notes

Every build is EdDSA-signed; installed apps refuse anything not signed by the
matching private key, so this repo hosting the files is not what you trust —
the signature is.
