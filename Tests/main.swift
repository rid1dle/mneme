import Foundation

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--fixture" {
    try ScreenFixture.build(at: URL(fileURLWithPath: CommandLine.arguments[2]), variant: CommandLine.arguments[3])
    exit(0)
}
exit(runAll(suites))
