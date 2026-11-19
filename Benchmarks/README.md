# Benchmarks

This package holds the measurements of FoundationModelsACPAgent. A measurement
is slow, so it is not a unit test.

## What it measures

`TranscriptSearchBenchmarks` measures the transcript search index (D207) with a
realistic history: 1,000 sessions of 10 turns each. It gives these numbers:

- The time of the first build of the catalog, and of the save.
- The time of a search, for four queries. Each query runs 10 times. The report
  gives the median and the maximum.
- The time of a turn update (4 new chunks, with the embed).
- The time of the load of the stored catalog, the time of the first search
  after it, and the number of texts that the load embedded.

The measurement loads no model. Its embedder is a fake that takes a fixed time
for each text (200 microseconds), as a small real model does.

## How to run it

Run the command from the root of the repository:

```sh
swift test --package-path Benchmarks
```

To keep the build of this package apart from the build of the root package,
give it its own scratch path:

```sh
swift test --package-path Benchmarks --scratch-path Benchmarks/.build
```

The measurement writes its report with a `Logger` (swift-log) to the standard
error of the test run. Each line of the report starts with
`TranscriptSearchMeasurement`.

## How it stays out of the unit tests and the CI

- The root `Package.swift` does not name this package. Thus `swift test` at
  the root does not build or run it.
- The CI workflow (`.github/workflows/ci.yml`) does not name this package.
  Thus the CI does not build or run it. A measurement runs only on demand.
- No environment variable selects the measurement. The package path selects
  it.
- This package reaches the root package with `.package(path: "..")`. The
  family rule "no path dependency" is for the root manifest only.
