# Discovery and online reader latency

Scope: show completed source batches before slow sources finish; display bounded
cached discovery snapshots while fresh data loads; defer online horizontal page
state publication until scrolling settles. Keep existing paginator and chapter
handoff, and keep private reading-source DTOs memory-only.

Implementation plan:
1. Add regressions for slow sources, stable partial results, request supersession,
   stale snapshot refresh/failure/invalidation, and page-turn settle/cancel.
2. Reuse the bounded batch fetcher, response cache, and page-turn tracking rather
   than introducing a second cache or replacing the reading surface.
3. Preserve completed content during refresh; prevent superseded requests from
   publishing into another source or section.
4. Run targeted tests in isolated processes where needed, Flutter analysis, and
   inspect the final diff. Physical device frame timing remains a separate check.

Out of scope: JS runtime pools, speculative viewport pagination, changing request
limits, private payload disk persistence, cross-chapter surface unification.

Implemented:
- Per-source progressive publication with stable source slots and explicit
  partial/completed section caches. The old latest-feed reordering helper was
  removed; source contributions remain bounded.
- Optional discovery snapshot callbacks reuse the existing response cache.
  Snapshots expire at 24 hours from their original timestamp; successful refresh
  replaces them, failed refresh does not extend their age. Programming errors
  and malformed JSON are not converted into cache successes.
- Online horizontal paging reuses HorizontalPageTurnTracker and commits at the
  top-level ScrollEnd; chapter and pagination changes discard pending positions.

Validation:
- Batch fetcher: 8 passed; discovery controller: 28 passed.
- Snapshot regressions (IO/web, concurrent loads, private payload disk exclusion,
  invalidation and restart expiry): 11 passed.
- Existing response cache/client facade regressions: 21 passed; existing discovery
  cache: 4 passed; client response cache: 4 passed.
- Online page commit: 2 passed; existing horizontal slide: 4 passed; tracker: 4 passed.
- Widget scenarios run in isolated processes: fast source/slow failure, favorites,
  category paging, refresh content retention, explicit cache invalidation, bounded
  concurrency, list channels, and tablet preview passed.
- Full stateful discovery/search widget files exhibited pumpAndSettle timeouts
  when combined in one process; the failing key scenarios passed independently.
  Simultaneous Flutter invocations also raced over the native SQLite asset;
  rerunning the affected refresh test sequentially passed.
- The architecture suite's only remaining failure is the independently modified
  book_source_management_controller.dart at 816 lines (limit <800), outside this
  change's ownership. The modified discovery controller is below the limit.

Not verified: physical-device frame timing, live slow-source timing, or release
build/distribution. No release or commit was made by this task.

Final review also repaired list-to-standard layout completion: an expanded-source
directory is now an incomplete category snapshot and triggers the remaining
source loads. The failing A-only to A/B regression now passes. CI's existing
isolated-case inventory includes the new fast-source case and page-commit suite.
