import Foundation

/// A minimal test runner: SwiftPM and Swift Testing are not usable with this Mac's command-line tools,
/// so tests are plain functions compiled with swiftc. Names read as specs.
struct TestCase {
    let name: String
    let body: () throws -> Void
}

nonisolated(unsafe) var currentFailures: [String] = []

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) {
    do {
        if try !condition() { currentFailures.append("\(file):\(line) \(message())") }
    } catch { currentFailures.append("\(file):\(line) threw \(error)") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    if a != b { currentFailures.append("\(file):\(line) expected \(b), got \(a) \(message)") }
}

func test(_ name: String, _ body: @escaping () throws -> Void) -> TestCase { TestCase(name: name, body: body) }

/// A fresh folder for one test, with symlinks resolved (/var -> /private/var) so paths compare exactly.
func makeSandbox() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let real = realpath(base.path, nil)!
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

func runAll(_ suites: [(String, [TestCase])]) -> Int32 {
    var failed = 0, passed = 0
    let filter = CommandLine.arguments.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
    for (suite, cases) in suites {
        for c in cases where filter == nil || c.name.contains(filter!) || suite.contains(filter!) {
            currentFailures = []
            do { try c.body() } catch { currentFailures.append("threw \(error)") }
            if currentFailures.isEmpty {
                passed += 1
                print("  ok   \(suite): \(c.name)")
            } else {
                failed += 1
                print("  FAIL \(suite): \(c.name)")
                for f in currentFailures { print("       \(f)") }
            }
        }
    }
    print("\n\(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}
