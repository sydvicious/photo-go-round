import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI

/// A test run's log lines stay out of the agent's.
///
/// Until 2026-09-16 every test wrote under `com.sydpolk.photogoround`, as
/// `swiftpm-testing-helper`, so a `log show` for the agent's subsystem on the
/// Mac that ran the tests had fake photographs, port 9000 and `test:` consumers
/// mixed in with the real ones. Syd: "fix that test logging".
@Suite("Test logging")
struct TestLoggingTests {

    @Test("A test process logs under a subsystem of its own")
    func testsLogApart() {
        #expect(Log.subsystem == "com.sydpolk.photogoround.tests")
    }

    @Test("A process that is not a test logs under the agent's subsystem")
    func realProcessesLogUnderTheAgent() {
        #expect(Log.subsystem(forProcess: "photogoroundd", environment: [:]) == "com.sydpolk.photogoround")
        #expect(Log.subsystem(forProcess: "Photo-Go-Round", environment: [:]) == "com.sydpolk.photogoround")
        #expect(
            Log.subsystem(forProcess: "Photo-Go-Round", environment: ["XCTestConfigurationFilePath": "/x"])
                == "com.sydpolk.photogoround.tests",
            "the app hosting its unit tests is a test run")
        #expect(
            Log.subsystem(forProcess: "swiftpm-testing-helper", environment: [:])
                == "com.sydpolk.photogoround.tests")
    }
}
