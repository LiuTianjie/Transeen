# Releasing Transeen

Installed copies update themselves with [Sparkle](https://sparkle-project.org) 2.10.0. Once a day they read `https://transeen.itool.tech/updates/appcast.xml`, which is `docs/updates/appcast.xml` in this repository. The feed names a zip on the GitHub Release and its EdDSA signature. Sparkle checks that signature against `SUPublicEDKey` in `Info.plist`, checks that the new app has the same Developer ID signature, and then replaces the app.

## The update signing key

The private key lives in the login keychain under the Sparkle account `transeen`. It was created once with:

```sh
"$(scripts/sparkle-tools.sh)/bin/generate_keys" --account transeen
```

Its public half, `amCBzzdTNLauVV8wwWZpJ3jqmuGA3DpHFh6b+b8KGg4=`, is `SUPublicEDKey` in `Info.plist`. Export a backup with `generate_keys --account transeen -x <file>` and keep that file somewhere safe outside the repository. Losing the key means installed copies can no longer verify updates and every user has to download the next version by hand. Never commit the private key.

## Steps

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Sparkle compares `CURRENT_PROJECT_VERSION`, so it must go up with every release. Turn `## Unreleased` in `CHANGELOG.md` into the version's heading; its items become the release notes in Sparkle's update window.
2. Run `TRANSEEN_NOTARY_PROFILE=<profile> ./scripts/package.sh`. It builds with the Developer ID identity, which also sets `SUFeedURL`, notarizes the app and the DMG, and writes `dist/Transeen-x.y.z.{dmg,zip,sha256}` plus `dist/appcast-x.y.z.xml`, signed for exactly that zip. Do not rebuild or re-zip after this step.
3. Tag `vX.Y.Z` and create the GitHub Release with the DMG, the zip and the checksum file.
4. Once the release is public, copy `dist/appcast-x.y.z.xml` to `docs/updates/appcast.xml`, commit, push `main` and deploy the site (GitHub Pages and the canonical domain). Never publish a feed whose zip cannot be downloaded yet.
5. Check that `curl -s https://transeen.itool.tech/updates/appcast.xml` shows the new version, then choose 检查更新… in an older signed copy and let it install.

Builds without a Developer ID identity have no `SUFeedURL`. They leave Sparkle off and 检查更新… opens the GitHub release page instead.
