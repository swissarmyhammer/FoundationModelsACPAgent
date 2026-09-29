import Foundation
import Testing

@testable import acp_agent

/// The choices the telemetry bootstrap of `acp-agent` makes before it
/// bootstraps a subsystem.
///
/// **No case here bootstraps the telemetry.** swift-log permits one
/// bootstrap for each process, and this process is the test runner. So the
/// cases examine the pure decisions and the install step with a recorder in
/// place of `LoggingSystem.bootstrap`. The spawned-binary suites of the
/// nested package prove the bootstrap of a real `acp-agent`.
struct TelemetryBootstrapTests {
    // MARK: - Constants

    /// The standard variable that enables the OTLP exporters.
    private static let otlpEndpointVariable = "OTEL_EXPORTER_OTLP_ENDPOINT"

    /// The standard variable that turns off the whole OpenTelemetry SDK.
    private static let sdkDisabledVariable = "OTEL_SDK_DISABLED"

    /// An OTLP endpoint. No case connects to it.
    private static let endpoint = "http://127.0.0.1:4318"

    /// A standard variable that has no effect on the choice.
    private static let serviceNameVariable = "OTEL_SERVICE_NAME"

    /// The value of ``serviceNameVariable``.
    private static let serviceName = "acp-agent"

    /// The log handler factory of a backend that the install step can make.
    private static let backendFactory = "backend factory"

    /// The log handler factory of the fallback.
    private static let fallbackFactory = "stderr factory"

    /// The service of a backend that the install step can make.
    private static let backendService = 7

    /// The error of a backend that the install step cannot make.
    private struct BackendFailure: Error {}

    // MARK: - The export choice

    /// With no OTLP endpoint, the agent exports nothing.
    @Test func noEndpointExportsNothing() {
        #expect(!TelemetryBootstrap.exportsTelemetry(environment: [:]))
    }

    /// With an empty OTLP endpoint, the agent exports nothing.
    @Test func anEmptyEndpointExportsNothing() {
        #expect(!TelemetryBootstrap.exportsTelemetry(environment: [Self.otlpEndpointVariable: ""]))
    }

    /// With an OTLP endpoint and no `OTEL_SDK_DISABLED`, the agent exports.
    @Test func anEndpointExports() {
        #expect(TelemetryBootstrap.exportsTelemetry(environment: [Self.otlpEndpointVariable: Self.endpoint]))
    }

    /// `OTEL_SDK_DISABLED` turns the export off with each case of `true`,
    /// also when an OTLP endpoint is set.
    @Test(arguments: ["true", "TRUE", "True"])
    func theSDKSwitchTurnsTheExportOff(value: String) {
        let environment = [Self.otlpEndpointVariable: Self.endpoint, Self.sdkDisabledVariable: value]

        #expect(!TelemetryBootstrap.exportsTelemetry(environment: environment))
    }

    /// Each value of `OTEL_SDK_DISABLED` other than `true` keeps the export
    /// on.
    @Test(arguments: ["false", "FALSE", "", "yes"])
    func otherSDKSwitchValuesKeepTheExport(value: String) {
        let environment = [Self.otlpEndpointVariable: Self.endpoint, Self.sdkDisabledVariable: value]

        #expect(TelemetryBootstrap.exportsTelemetry(environment: environment))
    }

    // MARK: - The traces and metrics environment

    /// The environment of the traces and metrics bootstrap has no
    /// `OTEL_SDK_DISABLED`, because swift-otel reads `false` in it as
    /// "enable the logs", and the logs have their own bootstrap.
    @Test func theTracingAndMetricsEnvironmentHasNoSDKSwitch() {
        let environment = [
            Self.otlpEndpointVariable: Self.endpoint,
            Self.sdkDisabledVariable: "false",
            Self.serviceNameVariable: Self.serviceName,
        ]

        let tracingAndMetrics = TelemetryBootstrap.tracingAndMetricsEnvironment(from: environment)

        #expect(
            tracingAndMetrics == [
                Self.otlpEndpointVariable: Self.endpoint,
                Self.serviceNameVariable: Self.serviceName,
            ])
    }

    // MARK: - The logging install

    /// When the backend is made, the install step installs its factory one
    /// time and gives back its service.
    @Test func aBackendIsInstalledOneTime() {
        var installed: [String] = []

        let service = TelemetryBootstrap.installLogging(
            from: { (factory: Self.backendFactory, service: Self.backendService) },
            otherwise: Self.fallbackFactory,
            installing: { installed.append($0) })

        #expect(installed == [Self.backendFactory])
        #expect(service == Self.backendService)
    }

    /// When the backend cannot be made, the install step installs the
    /// fallback one time and gives back no service.
    @Test func aFailedBackendInstallsTheFallbackOneTime() {
        var installed: [String] = []

        let service = TelemetryBootstrap.installLogging(
            from: { () throws -> (factory: String, service: Int) in throw BackendFailure() },
            otherwise: Self.fallbackFactory,
            installing: { installed.append($0) })

        #expect(installed == [Self.fallbackFactory])
        #expect(service == nil)
    }
}
