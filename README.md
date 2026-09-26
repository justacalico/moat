# Moat

Local-first encrypted notes. Your data lives on your devices — there is no
server, no account, no cloud. Devices find each other on the local network
and sync directly, encrypted end to end.

## Features

- **Markdown notes** with a live preview, formatting toolbar, checklists and
  code blocks
- **Per-note encryption** — lock any note behind your vault passphrase
  (Argon2id + AES-256-GCM); locked notes sync as ciphertext only
- **Serverless LAN sync** — devices announce themselves over UDP
  multicast/broadcast, pair once with a 6-digit code, then replicate over
  end-to-end encrypted TCP sessions (X25519 + HKDF + AES-GCM)
- **Conflict-safe replication** — vector clocks detect divergent edits and
  keep both versions as a conflict copy instead of silently dropping one
- **Folders, tags, colors** for organization; pin, archive, trash with
  restore and a 30-day-style soft delete
- **Search** across titles, bodies and tags with sort and grid/list views
- **Revision history** — every save keeps the previous version; restore any
  of the last 20
- **Vault lock** — biometric unlock and auto-lock timer on supported
  platforms, optional "require unlock at launch"
- **Backup** — export/import the whole library as JSON, or single notes as
  Markdown
- **Adaptive layout** — phone, tablet and desktop form factors from a single
  codebase; the window can be resized without losing state

The web build has everything except multi-device sync (browsers cannot open
the sockets it needs) — it still runs fully offline against local storage.

## Platforms

Android, iOS, Linux, Windows, macOS and web.

## Install

Grab binaries from the [releases page](../../releases). Android ships as a
signed APK/AAB; iOS as an unsigned `.ipa` for AltStore/sideloading; desktop
as native bundles. The web build is also published to GitLab Pages.

## Sync model

1. Open **Sync** on both devices. Each announces `{deviceId, name, port}` on
   UDP `239.77.73.77:47395` plus the subnet broadcast address.
2. Tap **Pair** next to the other device, confirm on it, then type the
   6-digit code it shows.
3. Pairing runs an ephemeral X25519 handshake authenticated by the code and
   produces a long-term shared key. Every later session re-handshakes with
   ephemeral keys + the stored key, then exchanges notes as AES-GCM frames.
4. Encrypted notes replicate as ciphertext; unlock them on any device that
   shares the vault passphrase.

There is no central server and nothing leaves the LAN except what the LAN
itself carries.

## Development

```sh
flutter pub get
flutter run            # pick a device
flutter test           # unit + widget tests, 100% coverage gate in CI
flutter test --update-goldens   # regenerate golden screenshots
```

Versioning uses [cocogitto](https://github.com/cocogitto/cocogitto):
conventional commits (`feat:`, `fix:` with Chinese subjects in this repo)
drive `cog bump --auto`, which writes `CHANGELOG.md` and the tag.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
