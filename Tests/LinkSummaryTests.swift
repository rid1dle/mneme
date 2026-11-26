import Foundation

private func s(_ u: String) -> LinkSummary? { summarizeLink(URL(string: u)!) }

let linkSummaryTests: [TestCase] = [
    test("should read a GitHub pull request address") {
        let x = s("https://github.com/vishwa-labs/vishwa-platform-python/pull/2479")
        expectEqual(x?.site, "GitHub")
        expectEqual(x?.context, "vishwa-labs/vishwa-platform-python")
        expectEqual(x?.headline, "#2479")
        expectEqual(x?.kind, "Pull request")
        expectEqual(x?.symbol, "arrow.triangle.pull")
        expectEqual(s("https://github.com/vishwa-labs/vishwa-platform/pull/2961/files#diff-1")?.headline, "#2961")
    },
    test("should read GitHub issues, commits, files, releases and runs") {
        expectEqual(s("https://github.com/rid1dle/mneme/issues/12")?.kind, "Issue")
        expectEqual(s("https://github.com/rid1dle/mneme/issues/12")?.headline, "#12")
        expectEqual(s("https://github.com/rid1dle/mneme/commit/04fc8891a2b3c4d5e6f7")?.headline, "04fc889")
        expectEqual(s("https://github.com/rid1dle/mneme/commit/04fc8891a2b3c4d5e6f7")?.kind, "Commit")
        let file = s("https://github.com/rid1dle/mneme/blob/main/Sources/App/Shell.swift#L12")
        expectEqual(file?.headline, "Shell.swift")
        expectEqual(file?.kind, "File on main")
        expectEqual(s("https://github.com/rid1dle/mneme/tree/main/Sources/Core")?.headline, "Core")
        expectEqual(s("https://github.com/rid1dle/mneme/releases/tag/v1.2.0")?.headline, "v1.2.0")
        expectEqual(s("https://github.com/rid1dle/mneme/actions/runs/123456")?.kind, "Actions run")
        expectEqual(s("https://github.com/rid1dle/mneme/compare/main...feat-x")?.headline, "main...feat-x")
        expectEqual(s("https://github.com/rid1dle/mneme/discussions/4")?.kind, "Discussion")
    },
    test("should read a GitHub repository address") {
        let r = s("https://github.com/rid1dle/mneme")
        expectEqual(r?.headline, "mneme")
        expectEqual(r?.context, "rid1dle")
        expectEqual(r?.kind, "Repository")
        expectEqual(s("https://www.github.com/rid1dle/mneme/")?.headline, "mneme")
    },
    test("should not claim addresses it does not understand") {
        expect(s("https://github.com/settings/profile") == nil)
        expect(s("https://github.com/") == nil)
        expect(s("https://gist.github.com/x/abc") == nil)
        expect(s("https://example.com/a/b/pull/3") == nil)
    },
]
