# Release versioning

The Flutter version in `pubspec.yaml` is the source of truth:

```yaml
version: 2.6.7+260907001
```

The part before `+` is the marketing version shown to users. The numeric part
after `+` is the platform build number. Update selection compares marketing
version first and, when it is equal, compares the numeric build number.
An older installed app that only compares marketing versions cannot discover a
same-version build-only update. It must first be upgraded manually or through
TestFlight to a build containing this comparison logic.

For an ordinary small update, keep the marketing version unchanged and
increment only the build number. This is the normal TestFlight workflow for a
new build of the same app version, although Apple may still require review or
processing and the repository does not promise review-free distribution.
Build numbers normally follow the existing `YYMMDDNNN` convention (for
example `260907001`) and must always increase for the same marketing version.

Release tags may use either form:

- `v2.6.7` (legacy form; the build is taken from `pubspec.yaml`)
- `v2.6.7+260907002` (preferred form; the tag build must match `pubspec.yaml`)

The `+BUILD` form is required when publishing another build of an existing
marketing version, because a Git tag and GitHub Release are immutable release
identities. GitHub Latest ordering is marketing version, prerelease, then
numeric build.

Each published build has its own release-note file named
`.github/release-notes/vX.Y.Z+BUILD.md`; the complete `version+build` identity
is unique. The in-app changelog therefore shows build-specific entries, while
update selection still compares marketing version first and build second.
Build numbers must remain globally increasing across version changes as well;
do not reset the build to `1` after changing the marketing version, because
Android version codes must remain newer than already installed packages.

The repository workflow validates and passes the tag to the official-site
deployment wrapper. The production wrapper installed on the server must also
be updated to accept and validate `vX.Y.Z+BUILD` before a build-tagged release
can be deployed. This repository change does not modify that separately
installed production program.

Android split-per-ABI APKs have a package `versionCode` offset added by Flutter.
The Android bridge exposes the unmodified release build separately: update
selection, the About page and changelog use that shared release build; APK
installation validation continues using the actual package versionCode. Old
website metadata without a build-bearing tag is compared using its package
build only, against the installed package build.

The current website release importer also validates `version` against the
whole tag suffix. Its manifest parser must be updated to separate version and
build before using these tags in production; updating only the shell wrapper
is insufficient. Neither the website repository nor production was changed
by this client-side implementation.

Apple describes subsequent builds of the same version as potentially not
requiring a full review, not as guaranteed review-free:
https://developer.apple.com/help/glossary/testflight-app-review/
