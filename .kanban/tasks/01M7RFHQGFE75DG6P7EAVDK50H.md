---
assignees:
- claude-code
position_column: todo
position_ordinal: '9180'
title: 'Race: ResumeChildSyncTests.theWireOfTheResumeFollowsTheRulesOfTheValidator fails under the load of the full suite'
---
## Problem

In the full suite run of 2026-11-18 (^ksepr6x), the test `ResumeChildSyncTests.theWireOfTheResumeFollowsTheRulesOfTheValidator(replays: false)` failed at `ResumeChildSyncTests.swift` (`#expect(violations == [])`):

```
violations → [Violation(rule: .announceBeforeUse, position: 1, message: "an update in 01M7RFFFB88MANKWM4TD1SX9ZS before it is announced")]
```

The same suite, run alone with `swift test --skip-build --filter ResumeChildSyncTests`, passed (24 tests). The change of ^ksepr6x touched only `Tests/.../Support/BoundedWait.swift`, which this suite does not use. Thus the cause is a race in the order of the wire under load: an update of a session goes out before its announce.

## Work

- Find why an update of the resumed child can go out before its announce on the wire.
- Correct the order in the source (not in the test), so the trace follows `announceBeforeUse` under load.
- Add a test that makes the race happen in a fixed order, and watch it fail first. #flaky #acpa-6