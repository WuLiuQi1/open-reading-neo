# Release versioning

The Flutter version in `pubspec.yaml` is the source of truth:

```yaml
version: 2.6.7+260908001
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
deployment wrapper. The installed wrapper and website release importer must
both accept `vX.Y.Z+BUILD`, keep marketing version separate from build, and
preserve older assets. The matching production changes were deployed before
publishing build `260908001`; future server deployments must preserve this
contract. The website release identity includes the package build number so
same-version builds can coexist without replacing immutable downloads.

Android split-per-ABI APKs have a package `versionCode` offset added by Flutter.
The Android bridge exposes the unmodified release build separately: update
selection, the About page and changelog use that shared release build; APK
installation validation continues using the actual package versionCode. Old
website metadata without a build-bearing tag is compared using its package
build only, against the installed package build.

If the Android native release-build method is unavailable, the release build
remains unknown instead of borrowing the ABI-offset package number. Update
checks can still compare installed and remote package numbers when the
website supplies an exact platform asset. GitHub-only metadata cannot prove
a same-version upgrade without an installed release-build identity.

Apple describes subsequent builds of the same version as potentially not
requiring a full review, not as guaranteed review-free:
https://developer.apple.com/help/glossary/testflight-app-review/
