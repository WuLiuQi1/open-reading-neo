# iOS batch source health crash

User report: checking a library of about 3,000 sources exits after 8–9 results.
The user's device, build and crash report are not yet available.

## Evidence and repair plan

- `flutter_js` 0.8.7's Apple runtime routes every native host callback through
  one static bound method, overwritten by each new runtime. Health checks own
  separate runtimes and overlap while awaiting network requests. This permits
  cross-context values and calls into an already released context.
- Its script evaluation creates JS strings without releasing them, and its
  global callback registry retains disposed runtime/host state. Timer callbacks
  can also evaluate after disposal.
- First reproduce multi-instance host isolation failure in a regression test.
  Replace only the Apple runtime adapter, reusing existing JSC C bindings with
  instance-owned callbacks and explicit native allocation lifetimes. Keep the
  source protocol, host API, network replay and batch scheduling unchanged.
- Reject late/queued evaluations after evaluator disposal. Cancel owned timers
  and release callback/native state exactly once. Add no dependencies.
- Verify interleaved runtimes, disposal during network replay, exception paths,
  timers, and a 3,000-source synthetic health run with actual Apple JSC.
  Run existing script/health suites, static analysis and iOS compilation.

The stop condition is passing targeted regressions and platform compilation.
This establishes the repaired runtime contract; it does not prove the user's
specific source pack or physical iPhone has been retested. An unbounded
synchronous source script remains outside Dart Future timeout enforcement.

Native contract reference:
https://developer.apple.com/documentation/javascriptcore/jsglobalcontextcreate(_:)
(values cannot be used across context groups).

## Verification

- Before repair, the interleaved-engine regression failed: the first source's
  `cache.put('key', 'first'); cache.get('key')` returned `null`, not `first`.
- After repair, 167 script, source-runtime, health and architecture regressions
  passed, including the new lifecycle tests. Log:
  `/tmp/open-reading-health-runtime-regressions.log`.
- `flutter test --no-pub --dart-define=SOURCE_HEALTH_STRESS_COUNT=3000
  test/source_health_batch_lifecycle_test.dart` passed in 13 seconds on macOS.
  It uses actual Apple JSC, iOS's three concurrent workers, 3,000 independent
  sources and 12,000 fake network responses. Every source completed search,
  info, catalog and content, with healthy results saved to the registry.
  The default regression uses 30 sources; the define enables the stress run.
- `flutter analyze --no-pub`: no issues. Use Flutter's bundled Dart 3.12 SDK;
  the Homebrew Dart 3.9 analyzer does not understand the repository's existing
  private named parameter syntax.
- `flutter build ios --release --no-codesign --no-pub`: succeeded, producing
  `build/ios/iphoneos/Runner.app`. Log:
  `/tmp/open-reading-ios-health-runtime-build.log`.
- Generated lockfile churn from platform compilation was removed. Existing
  unrelated working-tree changes were preserved; no dependency changes.

No signed distribution or physical-iPhone retest has been performed. The
user's crash log/source pack is still needed to tie this confirmed runtime
defect to the specific reported crash.
