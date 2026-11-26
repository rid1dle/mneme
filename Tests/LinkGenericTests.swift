import Foundation

private func d(_ u: String) -> LinkSummary? { describeLink(URL(string: u)!) }

let linkGenericTests: [TestCase] = [
    test("should describe any web link by its site and a readable page name") {
        let x = d("https://www.smashingmagazine.com/2024/05/how-to-ship-fast-without-breaking-things/")
        expectEqual(x?.site, "Smashingmagazine")
        expectEqual(x?.headline, "How to ship fast without breaking things")
        expectEqual(x?.kind, "smashingmagazine.com")
        expect(x?.symbol == nil)
        let home = d("https://news.ycombinator.com/")
        expectEqual(home?.headline, "Ycombinator")
        expectEqual(home?.kind, "news.ycombinator.com")
    },
    test("should skip ids and file endings when reading a page name") {
        expectEqual(d("https://example.com/docs/getting_started.html")?.headline, "Getting started")
        expectEqual(d("https://example.com/orders/8f14e45fceea167a5a36dedd4bea2543")?.headline, "Orders")
        expectEqual(d("https://example.com/items/123456")?.headline, "Items")
    },
    test("should give every site the same badge colour each time") {
        expectEqual(d("https://example.com/a")?.color, d("https://example.com/b")?.color)
        expectEqual(d("https://github.com/a/b/pull/1")?.color, "#24292F")
    },
    test("should read work tools: Jira, Linear, Confluence, Notion, Figma, GitLab") {
        let jira = d("https://vishwa.atlassian.net/browse/PLAT-142")
        expectEqual(jira?.site, "Jira"); expectEqual(jira?.headline, "PLAT-142"); expectEqual(jira?.kind, "Issue")
        let linear = d("https://linear.app/vishwa/issue/ENG-88/fix-the-sync-timeout")
        expectEqual(linear?.headline, "ENG-88"); expectEqual(linear?.detail, "Fix the sync timeout")
        let conf = d("https://vishwa.atlassian.net/wiki/spaces/ENG/pages/123456/Release+checklist")
        expectEqual(conf?.site, "Confluence"); expectEqual(conf?.headline, "Release checklist")
        let notion = d("https://www.notion.so/vishwa/Quarterly-plan-2027-0123456789abcdef0123456789abcdef")
        expectEqual(notion?.site, "Notion"); expectEqual(notion?.headline, "Quarterly plan 2027")
        let figma = d("https://www.figma.com/design/AbC123xyz/Shelf-redesign?node-id=1-2")
        expectEqual(figma?.site, "Figma"); expectEqual(figma?.headline, "Shelf redesign"); expectEqual(figma?.kind, "Design")
        let gitlab = d("https://gitlab.com/group/project/-/merge_requests/42")
        expectEqual(gitlab?.site, "GitLab"); expectEqual(gitlab?.headline, "!42"); expectEqual(gitlab?.kind, "Merge request")
    },
    test("should read Google Docs, Sheets, Slides, Drive and Meet links") {
        expectEqual(d("https://docs.google.com/document/d/1AbC/edit")?.site, "Google Docs")
        expectEqual(d("https://docs.google.com/spreadsheets/d/1AbC/edit#gid=0")?.site, "Google Sheets")
        expectEqual(d("https://docs.google.com/presentation/d/1AbC/edit")?.site, "Google Slides")
        expectEqual(d("https://drive.google.com/drive/folders/1AbC")?.kind, "Folder")
        let meet = d("https://meet.google.com/abc-defg-hij")
        expectEqual(meet?.headline, "abc-defg-hij"); expectEqual(meet?.kind, "Meeting")
    },
    test("should read Slack, YouTube, X, LinkedIn, Stack Overflow, Reddit and Wikipedia links") {
        let slack = d("https://vishwa-ai.slack.com/archives/C05ABC123/p1764088140123456")
        expectEqual(slack?.site, "Slack"); expectEqual(slack?.kind, "Message"); expectEqual(slack?.context, "vishwa-ai")
        expectEqual(d("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.kind, "Video")
        expectEqual(d("https://youtu.be/dQw4w9WgXcQ")?.site, "YouTube")
        let x = d("https://x.com/apple/status/1234567890")
        expectEqual(x?.headline, "@apple"); expectEqual(x?.kind, "Post")
        expectEqual(d("https://www.linkedin.com/in/some-person/")?.kind, "Profile")
        let so = d("https://stackoverflow.com/questions/24005678/how-do-i-sort-an-array-in-swift")
        expectEqual(so?.headline, "How do i sort an array in swift"); expectEqual(so?.kind, "Question")
        let reddit = d("https://www.reddit.com/r/macapps/comments/abc123/best_clipboard_manager/")
        expectEqual(reddit?.headline, "Best clipboard manager"); expectEqual(reddit?.kind, "r/macapps")
        expectEqual(d("https://en.wikipedia.org/wiki/Mnemosyne")?.headline, "Mnemosyne")
    },
    test("should read package pages, dashboards and meetings") {
        expectEqual(d("https://www.npmjs.com/package/left-pad")?.headline, "left-pad")
        expectEqual(d("https://pypi.org/project/polars/")?.kind, "PyPI package")
        let g = d("https://grafana.internal.example.com/d/abc123/udaan-feedback-overview?orgId=1")
        expectEqual(g?.kind, "Dashboard"); expectEqual(g?.headline, "Udaan feedback overview")
        expectEqual(d("https://us02web.zoom.us/j/81234567890?pwd=x")?.kind, "Meeting")
    },
    test("should show a local address as a local server") {
        let l = d("http://localhost:8000/api/run")
        expectEqual(l?.site, "Local server"); expectEqual(l?.headline, ":8000"); expectEqual(l?.kind, "/api/run")
        expectEqual(d("http://127.0.0.1:3000")?.headline, ":3000")
    },
    test("should keep only the page's own title, without the site and place it repeats") {
        expectEqual(cleanPageTitle("Shelf: show pinboard names in search · Issue #12 · rid1dle/mneme · GitHub", site: "GitHub"), "Shelf: show pinboard names in search")
        expectEqual(cleanPageTitle("How do I sort an array in Swift? - Stack Overflow", site: "Stack Overflow"), "How do I sort an array in Swift?")
        expectEqual(cleanPageTitle("Never Gonna Give You Up - YouTube", site: "YouTube"), "Never Gonna Give You Up")
        expectEqual(cleanPageTitle("Mnemosyne - Wikipedia", site: "Wikipedia"), "Mnemosyne")
        expectEqual(cleanPageTitle("Pricing | Linear", site: "Linear"), "Pricing")
        expectEqual(cleanPageTitle("Vision | Apple Developer Documentation", site: "Apple"), "Vision")
        expectEqual(cleanPageTitle("A - B testing explained", site: "Example"), "A - B testing explained")
    },
    test("should not describe something that is not a web address") {
        expect(d("mailto:a@b.com") == nil)
        expect(d("file:///tmp/x") == nil)
    },
]
