// The module re-exports `OTel`, so `acp-agent` reaches the exporters through
// this one product. The manifest gives `swift-otel` the `OTLPHTTP` trait
// only. See the doc comment of `package` in `OTelHTTP/Package.swift`.
@_exported import OTel
