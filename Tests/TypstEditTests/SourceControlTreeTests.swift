import XCTest
@testable import TypstEdit

final class SourceControlTreeTests: XCTestCase {
    private func change(_ path: String, original: String? = nil) -> GitChange {
        GitChange(path: path, originalPath: original, indexStatus: " ", worktreeStatus: "M",
                  isStaged: false, isUnstaged: true)
    }

    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, shortHash: id, parents: parents, subject: id, author: "A", date: Date(), refs: "")
    }

    func testTreeGroupsFoldersFirstAndKeepsFullPaths() {
        let nodes = GitChangeTreeNode.build(from: [
            change("main.typ"), change("chapters/b.typ"), change("chapters/a.typ"), change("chapters/img/x.png"),
        ])
        XCTAssertEqual(nodes.map(\.name), ["chapters", "main.typ"])
        let chapters = nodes[0]
        XCTAssertTrue(chapters.isDirectory)
        XCTAssertEqual(chapters.children.map(\.name), ["img", "a.typ", "b.typ"])
        XCTAssertEqual(chapters.children[0].children.first?.change?.path, "chapters/img/x.png")
    }

    func testTreeKeepsFileAndFolderAtSamePathDistinct() {
        let nodes = GitChangeTreeNode.build(from: [change("docs"), change("docs/readme.md")])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(Set(nodes.map(\.id)).count, 2)
        XCTAssertTrue(nodes[0].isDirectory)
        XCTAssertEqual(nodes[1].change?.path, "docs")
    }

    func testTreeKeepsNamesWithSpacesAndSameFileNames() {
        let nodes = GitChangeTreeNode.build(from: [change("a dir/main.typ"), change("b/main.typ")])
        let leaves = nodes.flatMap(\.children).compactMap(\.change?.path)
        XCTAssertEqual(Set(leaves), ["a dir/main.typ", "b/main.typ"])
    }

    func testLinearGraphUsesOneLane() {
        let rows = GitGraphRow.build(from: [commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount).max(), 1)
    }

    func testMergeGraphOpensAndClosesSecondLane() {
        // m merges b2 into a1; both branch from root.
        let rows = GitGraphRow.build(from: [
            commit("m", ["a1", "b2"]), commit("b2", ["root"]), commit("a1", ["root"]), commit("root", []),
        ])
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertEqual(rows[1].lane, 1)
        XCTAssertEqual(rows[2].lane, 0)
        XCTAssertEqual(rows[3].lane, 0)
        XCTAssertEqual(rows.map(\.laneCount).max(), 2)
        // The merge row draws one segment to each parent.
        XCTAssertEqual(rows[0].segments.filter { $0.startY == 0.5 }.count, 2)
    }

    func testDuplicateParentsDoNotAddLanes() {
        let rows = GitGraphRow.build(from: [commit("b", ["a", "a"]), commit("a", [])])
        XCTAssertEqual(rows[0].laneCount, 1)
        XCTAssertEqual(rows[0].segments.filter { $0.startY == 0.5 }.count, 1)
    }

    func testDiffClassificationUsesHunkState() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
         same
        -old
        +++not a header
        ---not a header
        """
        let kinds = GitDiffLine.parse(diff).map(\.kind)
        XCTAssertEqual(kinds, [.header, .header, .header, .hunk, .context, .removed, .added, .removed])
    }

    // MARK: Graph marks

    func testDotMarkCombinesUnpushedHollowAndHeadRing() {
        XCTAssertEqual(GitGraphDotMark.mark(isHead: false, isUnpushed: false),
                       GitGraphDotMark(isHollow: false, hasHeadRing: false))
        XCTAssertEqual(GitGraphDotMark.mark(isHead: false, isUnpushed: true),
                       GitGraphDotMark(isHollow: true, hasHeadRing: false))
        XCTAssertEqual(GitGraphDotMark.mark(isHead: true, isUnpushed: false),
                       GitGraphDotMark(isHollow: false, hasHeadRing: true))
        // HEAD that is not pushed keeps both marks.
        XCTAssertEqual(GitGraphDotMark.mark(isHead: true, isUnpushed: true),
                       GitGraphDotMark(isHollow: true, hasHeadRing: true))
    }

    // MARK: Ref names

    func testRemoteBranchShortNames() {
        XCTAssertEqual(GitRefName.shortName(ofRemoteBranch: "origin/feature"), "feature")
        XCTAssertEqual(GitRefName.shortName(ofRemoteBranch: "origin/nested/name"), "nested/name")
        XCTAssertEqual(GitRefName.shortName(ofRemoteBranch: "feature"), "feature")
        // No component after the separator: keep the name as it is.
        XCTAssertEqual(GitRefName.shortName(ofRemoteBranch: "origin/"), "origin/")
        XCTAssertEqual(GitRefName.shortName(ofRemoteBranch: "/feature"), "/feature")
    }

    func testRefNameRulesAcceptValidNames() {
        XCTAssertNil(GitRefNameRules.problem(with: "feature"))
        XCTAssertNil(GitRefNameRules.problem(with: "feature/x"))
        XCTAssertNil(GitRefNameRules.problem(with: "v1.2.3"))
        XCTAssertNil(GitRefNameRules.problem(with: "release-2026"))
        // Empty is not a problem here; callers disable empty names separately.
        XCTAssertNil(GitRefNameRules.problem(with: ""))
    }

    func testRefNameRulesRejectInvalidNames() {
        XCTAssertNotNil(GitRefNameRules.problem(with: "-branch"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "/branch"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "branch/"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a..b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a~b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a^b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a:b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a?b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a*b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a[b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a\\b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a@{b"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "refs.lock"))
        XCTAssertNotNil(GitRefNameRules.problem(with: "a\u{7}b"))
    }

    func testRefNameRulesRejectReservedNames() {
        XCTAssertNotNil(GitRefNameRules.problem(with: "HEAD", reserved: ["HEAD"]))
        XCTAssertNil(GitRefNameRules.problem(with: "HEAD"))
        XCTAssertNil(GitRefNameRules.problem(with: "head", reserved: ["HEAD"]))
    }

    // MARK: Sync badge

    func testSyncBadgeHidesWhenInSync() {
        XCTAssertNil(GitSyncBadge.label(ahead: 0, behind: 0))
    }

    func testSyncBadgeFormatsAheadAndBehind() {
        XCTAssertEqual(GitSyncBadge.label(ahead: 1, behind: 0), "↓0 ↑1")
        XCTAssertEqual(GitSyncBadge.label(ahead: 0, behind: 2), "↓2 ↑0")
        XCTAssertEqual(GitSyncBadge.label(ahead: 5, behind: 3), "↓3 ↑5")
    }
}
