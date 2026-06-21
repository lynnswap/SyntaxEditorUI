import Foundation
import Testing
@testable import SyntaxEditorCore

@Suite("SyntaxHighlighterEngine", .serialized)
struct SyntaxHighlighterEngineTests {
    @Test("SyntaxHighlighterEngine returns no tokens for empty source")
    func highlighterReturnsNoTokensForEmptySource() async {
        let engine = sharedSyntaxHighlighterEngine
        let tokens = await engine.render(source: "", language: SyntaxLanguage.javascript)
        #expect(tokens.isEmpty)
    }

    @Test("SyntaxHighlighterEngine returns no tokens for plain text")
    func highlighterReturnsNoTokensForPlainText() async {
        let engine = SyntaxHighlighterEngine()
        let source = "plain text\nwith (brackets)"

        let reset = await engine.reset(source: source, language: .plainText)
        #expect(reset.tokens.isEmpty)
        #expect(refreshRangeUnion(reset) == NSRange(location: 0, length: source.utf16.count))

        let update = await engine.update(
            previousSource: source,
            source: source + "\n",
            language: .plainText,
            mutation: SyntaxEditorTextChange.Replacement(location: source.utf16.count, length: 0, replacement: "\n")
        )
        #expect(update.tokens.isEmpty)
        #expect(refreshRangeUnion(update) == NSRange(location: 0, length: (source + "\n").utf16.count))

        let phases = await collectHighlightPhases(
            await engine.resetPhases(source: source, language: .plainText, revision: 2)
        )
        #expect(phases.count == 1)
        #expect(phases.first?.tokens.isEmpty == true)
        #expect(phases.first?.phase == .complete)
    }

    @Test("SyntaxHighlighterEngine produces highlight tokens for JavaScript")
    func highlighterProducesTokensForJavaScript() async {
        await expectHighlightTokens(source: "const answer = 42;", language: .javascript)
    }

    @Test("SyntaxHighlighterEngine produces highlight tokens for JSON")
    func highlighterProducesTokensForJSON() async {
        await expectHighlightTokens(source: "{\"enabled\": true, \"count\": 1}", language: .json)
    }

    @Test("SyntaxHighlighterEngine produces highlight tokens for Swift")
    func highlighterProducesTokensForSwift() async {
        await expectHighlightTokens(source: "let answer = 42", language: .swift)
    }

    @Test("SyntaxEditorHighlighting handles overlapping prepare request patterns")
    func highlightingPrepareHandlesOverlappingRequestPatterns() async {
        await SyntaxEditorHighlighting.prepare(.html)
        await SyntaxEditorHighlighting.prepare([.swift, .html])
        await SyntaxEditorHighlighting.prepare(.html)
        await SyntaxEditorHighlighting.prepare(SyntaxLanguage.allCases)
        await SyntaxEditorHighlighting.prepare(.swift)
        await SyntaxEditorHighlighting.prepare([.html, .swift, .html, .objectiveC])

        await expectPreparedLanguagesRender(SyntaxLanguage.syntaxHighlightedCases)
    }

    @Test("SyntaxEditorHighlighting handles concurrent repeated prepare calls")
    func highlightingPrepareHandlesConcurrentRepeatedCalls() async {
        let requests: [[SyntaxLanguage]] = [
            [.html],
            [.swift, .html],
            [.html, .swift, .html],
            SyntaxLanguage.allCases,
            [.objectiveC, .swift, .objectiveC],
        ]

        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    await SyntaxEditorHighlighting.prepare(request)
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    await SyntaxEditorHighlighting.prepare(.swift)
                }
                group.addTask {
                    await SyntaxEditorHighlighting.prepare(.html)
                }
            }
        }

        await expectPreparedLanguagesRender([.swift, .html, .objectiveC])
    }

    @Test("SyntaxEditorHighlighting handles all-language prepare racing specific work")
    func highlightingPrepareHandlesAllLanguagePrepareRacingSpecificWork() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await SyntaxEditorHighlighting.prepare(SyntaxLanguage.allCases)
            }
            group.addTask {
                await SyntaxEditorHighlighting.prepare(.swift)
            }
            group.addTask {
                await SyntaxEditorHighlighting.prepare([.html, .swift])
            }
            group.addTask {
                _ = await SyntaxHighlighterEngine().render(
                    source: smokeSource(for: .swift),
                    language: .swift
                )
            }
            group.addTask {
                _ = await SyntaxHighlighterEngine().render(
                    source: smokeSource(for: .html),
                    language: .html
                )
            }
        }

        await expectPreparedLanguagesRender([.swift, .html])
    }

    @Test("SyntaxEditorHighlighting tolerates prepare while highlighting prepares setup")
    func highlightingPrepareToleratesConcurrentHighlightingSetup() async {
        let source = """
        @interface ReferenceObject
        @property(nonatomic) NSInteger count;
        @end
        """

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await SyntaxEditorHighlighting.prepare([.objectiveC, .objectiveC])
                }
            }
            group.addTask {
                _ = await SyntaxHighlighterEngine().render(source: source, language: .objectiveC)
            }
            group.addTask {
                await SyntaxEditorHighlighting.prepare(.objectiveC)
            }
        }

        let tokens = await SyntaxHighlighterEngine().render(source: source, language: .objectiveC)
        #expect(tokens.isEmpty == false)
        #expect(tokens.allSatisfy { $0.range.length > 0 })
    }

    @Test("SyntaxHighlighterEngine emits Swift syntactic fast pass before semantic completion")
    func highlighterEmitsSwiftSyntacticFastPassBeforeSemanticCompletion() async throws {
        let source = "let value: Int = 1\n"
        let intRange = (source as NSString).range(of: "Int")
        let phases = await collectHighlightPhases(
            await SyntaxHighlighterEngine().resetPhases(source: source, language: .swift, revision: 0)
        )
        let fastPass = try #require(phases.first)
        let complete = try #require(phases.last)

        #expect(phases.map(\.phase) == [.syntacticFastPass, .complete])
        #expect(phases.allSatisfy { $0.source == source && $0.language == .swift && $0.revision == 0 })
        #expect(fastPass.tokens.isEmpty == false)
        #expect(fastPass.tokens.contains {
            tokenIntersects($0, range: intRange, syntaxID: .identifierTypeSystem, language: .swift)
        } == false)
        #expect(complete.tokens.contains {
            tokenIntersects($0, range: intRange, syntaxID: .identifierTypeSystem, language: .swift)
        })
    }

    @Test("SyntaxHighlighterEngine keeps non-deferred languages single phase")
    func highlighterKeepsNonDeferredLanguagesSinglePhase() async {
        let source = "const answer = 42;"
        let phases = await collectHighlightPhases(
            await SyntaxHighlighterEngine().resetPhases(source: source, language: .javascript, revision: 0)
        )

        #expect(phases.map(\.phase) == [.complete])
        #expect(phases.first?.source == source)
        #expect(phases.first?.tokens.isEmpty == false)
    }

    @Test("SyntaxHighlighterEngine final APIs keep returning complete results")
    func highlighterFinalAPIsKeepReturningCompleteResults() async throws {
        let source = "let value: Int = 1\n"
        let updatedSource = "let value: String = \"text\"\n"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let engine = SyntaxHighlighterEngine()

        let reset = await engine.reset(source: source, language: .swift, revision: 0)
        let update = await engine.update(
            source: updatedSource,
            language: .swift,
            mutation: mutation,
            revision: 1
        )
        let render = await engine.render(source: source, language: .swift)

        #expect(reset.phase == .complete)
        #expect(update.phase == .complete)
        #expect(highlightTokensMatch(reset.tokens, render))
    }

    @Test("SyntaxHighlighterEngine keeps refreshes edit-local while typing inside a block comment")
    func highlighterKeepsRefreshEditLocalInsideBlockComment() async throws {
        // A multi-line token used to be dropped and re-inserted whole per edit,
        // making the refresh (and the repaint) span the entire comment.
        let commentBody = (0..<50).map { " * filler line \($0) with some words" }.joined(separator: "\n")
        let source = "let before = 1\n/**\n\(commentBody)\n * MARKER\n\(commentBody)\n */\nlet after = 2\n"
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: source, language: .swift, revision: 0)

        let caret = (source as NSString).range(of: "MARKER").upperBound
        var current = source
        var revision = 1
        for character in "typed words" {
            let insertion = String(character)
            let mutation = SyntaxEditorTextChange.Replacement(
                location: caret + revision - 1,
                length: 0,
                replacement: insertion
            )
            let next = (current as NSString).replacingCharacters(
                in: NSRange(location: mutation.location, length: 0),
                with: insertion
            )
            let result = await engine.update(
                source: next,
                language: .swift,
                mutation: mutation,
                revision: revision
            )
            #expect(
                refreshRangeUnion(result).length < 200,
                "refresh \(refreshRangeUnion(result)) should stay near the edited line, not span the comment"
            )
            current = next
            revision += 1
        }

        // The incremental store still matches a fresh full render.
        let settled = await engine.currentTokensForTesting()
        let fresh = await SyntaxHighlighterEngine().render(source: current, language: .swift)
        #expect(highlightTokensMatch(settled, fresh))
    }

    @Test("SyntaxHighlighterEngine rehighlights owner scopes when the first extension adds a member")
    func highlighterRehighlightsOwnerScopesWhenFirstExtensionAddsMember() async throws {
        // Adding a type's FIRST extension makes its members visible from the
        // original type body; bounding the refresh to the new extension alone
        // leaves the existing call site stale until some later full pass.
        // Filler keeps the document large enough that the fan-out guard does
        // not rescue the bounded-targets path.
        let filler = (0..<200).map { "let filler\($0) = \($0)" }.joined(separator: "\n")
        let source = "struct Foo {\n    func use() {\n        view.backgroundColor = nil\n    }\n}\n\(filler)\n"
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: source, language: .swift, revision: 0)

        let insertion = "extension Foo {\n    var view: UIView { UIView() }\n}\n"
        let caret = (source as NSString).length
        let next = source + insertion
        _ = await engine.update(
            source: next,
            language: .swift,
            mutation: SyntaxEditorTextChange.Replacement(location: caret, length: 0, replacement: insertion),
            revision: 1
        )

        let settled = await engine.currentTokensForTesting()
        let fresh = await SyntaxHighlighterEngine().render(source: next, language: .swift)

        // Sanity: the new extension member must actually change the call
        // site's classification inside the original type body, otherwise this
        // scenario cannot detect a missing recolor.
        let bodyRange = NSRange(location: 0, length: ((source as NSString).length / 2))
        let freshWithout = await SyntaxHighlighterEngine().render(source: source, language: .swift)
        let bodyBefore = freshWithout.filter { $0.range.upperBound <= bodyRange.upperBound }
        let bodyAfter = fresh.filter { $0.range.upperBound <= bodyRange.upperBound }
        #expect(!highlightTokensMatch(bodyBefore, bodyAfter), "scenario must change body classification")

        #expect(highlightTokensMatch(settled, fresh))
    }

    @Test("SyntaxHighlighterEngine recovers from stale mutations beyond the edit neighborhood")
    func highlighterRecoversFromStaleMutationsBeyondEditNeighborhood() async throws {
        // The session is silently behind by a length-neutral change far from the
        // reported mutation. Window-probe validation accepted this (total length
        // and the edit's neighborhood both match) and committed a drifted base;
        // exact splice validation must take the diff-recovery path instead.
        let source = "let alpha = 1\nlet beta = 2\nlet gamma = 3\nlet delta = 4\nlet omega = 9\n"
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: source, language: .swift, revision: 0)

        let drifted = source.replacingOccurrences(of: "beta", with: "zeta")
        let caret = (drifted as NSString).length
        let mutation = SyntaxEditorTextChange.Replacement(location: caret, length: 0, replacement: "x")
        let next = drifted + "x"

        let result = await engine.update(
            source: next,
            language: .swift,
            mutation: mutation,
            revision: 1
        )
        #expect(result.source == next)
        let settled = await engine.currentTokensForTesting()
        let fresh = await SyntaxHighlighterEngine().render(source: next, language: .swift)
        #expect(highlightTokensMatch(settled, fresh))
    }

    @Test("SyntaxHighlighterEngine progressive reset never labels partial paints as full snapshots")
    func highlighterProgressiveResetEmitsPartialPaintsAsReplacements() async throws {
        let unit = try referenceSampleText(named: "Reference.swift")
        let copies = max(1, 60_000 / max(1, unit.utf16.count) + 1)
        let source = String(repeating: unit, count: copies)

        HighlightSession.progressiveResetThresholdOverrideForTesting = 1024
        defer { HighlightSession.progressiveResetThresholdOverrideForTesting = nil }

        let engine = SyntaxHighlighterEngine()
        var results: [SyntaxEditorHighlighting.Result] = []
        let phases = await engine.resetPhases(source: source, language: .swift, revision: 0)
        for await result in phases {
            results.append(result)
        }

        let final = try #require(results.last)
        #expect(final.tokenPayload == .fullSnapshot)
        // Every earlier emission is a partial paint and must say so: a consumer
        // trusting .fullSnapshot as the revision's complete token list would
        // otherwise replace its cache with one viewport chunk.
        for partial in results.dropLast() {
            #expect(partial.tokenPayload == .replacement)
        }
        #expect(results.count > 2)
    }

    @Test(
        "SyntaxHighlighterEngine progressive reset matches the monolithic reset",
        arguments: [SyntaxLanguage.swift, .objectiveC]
    )
    func highlighterProgressiveResetMatchesMonolithicReset(language: SyntaxLanguage) async throws {
        let filename = language == .swift ? "Reference.swift" : "Reference.m"
        let unit = try referenceSampleText(named: filename)
        // Repeat the fixture so the progressive path runs multiple chunks
        // (chunk budget is 16k UTF-16 units).
        let copies = max(1, 60_000 / max(1, unit.utf16.count) + 1)
        let source = String(repeating: unit, count: copies)

        let monolithic = await SyntaxHighlighterEngine().render(source: source, language: language)

        HighlightSession.progressiveResetThresholdOverrideForTesting = 1024
        defer { HighlightSession.progressiveResetThresholdOverrideForTesting = nil }
        let progressive = await SyntaxHighlighterEngine().render(source: source, language: language)

        #expect(highlightTokensMatch(progressive, monolithic))
    }

    @Test("SyntaxHighlighterEngine emits canonical reference sample captures")
    func highlighterEmitsCanonicalReferenceSampleCaptures() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let cases: [(language: SyntaxLanguage, filename: String)] = [
            (.css, "Reference.css"),
            (.html, "Reference.html"),
            (.javascript, "Reference.js"),
            (.json, "Reference.json"),
            (.objectiveC, "Reference.m"),
            (.swift, "Reference.swift"),
            (.toml, "Reference.toml"),
            (.xml, "Reference.xml"),
        ]

        for testCase in cases {
            let source = try referenceSampleText(named: testCase.filename)
            let tokens = await engine.render(source: source, language: testCase.language)
            let nonCanonicalCaptures = tokens
                .filter { $0.rawCaptureName.hasPrefix("editor.syntax.") == false }
                .map(\.rawCaptureName)
                .sorted()
            #expect(
                nonCanonicalCaptures.isEmpty,
                "Non-canonical captures for \(testCase.language.rawValue): \(nonCanonicalCaptures.joined(separator: ", "))"
            )

            let unresolvedTokens = tokens
                .filter {
                    SyntaxEditorHighlightTheme.semanticStyleKeys(
                        for: $0.syntaxID,
                        language: $0.language ?? testCase.language
                    ) == nil
                }
                .map { "\($0.rawCaptureName)->\($0.syntaxID.rawValue)" }
                .sorted()

            #expect(
                unresolvedTokens.isEmpty,
                "Unresolved source syntax IDs for \(testCase.language.rawValue): \(unresolvedTokens.joined(separator: ", "))"
            )
        }
    }

    @Test("SyntaxHighlighterEngine is stable for repeated renders")
    func highlighterRepeatedRenderStability() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = "const value = 42; const message = 'ok';"

        let first = await engine.render(source: source, language: SyntaxLanguage.javascript)
        let second = await engine.render(source: source, language: SyntaxLanguage.javascript)

        #expect(first.isEmpty == false)
        #expect(first.count == second.count)
    }

    @Test("SyntaxHighlighterEngine incrementally updates JavaScript like a full reset")
    func highlighterIncrementallyUpdatesJavaScript() async throws {
        let source = "const value = 42;\nconst message = 'ok';"
        let updatedSource = "const value = 42;\nlet message = 'ok';"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).location <= mutation.range.location)
    }

    @Test("SyntaxHighlighterEngine queries full touched lines for partial token edits")
    func highlighterIncrementallyRefreshesPartialTokenEdits() async throws {
        let source = "const value = 42;\nconst message = value;"
        let updatedSource = "const label = 42;\nconst message = value;"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine re-queries expanded JavaScript template coverage")
    func highlighterIncrementallyRefreshesExpandedTemplateCoverage() async throws {
        let source = "const message = `${first}-${second}-${third}`;"
        let updatedSource = "const message = `${first}-${secondValue}-${third}`;"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)
        let nsSource = updatedSource as NSString
        let firstRange = nsSource.range(of: "first")
        let thirdRange = nsSource.range(of: "third")

        #expect(incremental.tokens == full.tokens)
        #expect(full.tokens.contains {
            SyntaxEditorRangeUtilities.intersection(of: $0.range, and: firstRange).length > 0
        })
        #expect(incremental.tokens.contains {
            SyntaxEditorRangeUtilities.intersection(of: $0.range, and: firstRange).length > 0
        })
        #expect(full.tokens.contains {
            SyntaxEditorRangeUtilities.intersection(of: $0.range, and: thirdRange).length > 0
        })
        #expect(incremental.tokens.contains {
            SyntaxEditorRangeUtilities.intersection(of: $0.range, and: thirdRange).length > 0
        })
    }

    @Test("SyntaxHighlighterEngine repaints dropped JavaScript comment captures")
    func highlighterRepaintsDroppedCommentCaptureExtents() async throws {
        let source = "/* comment */\nconst value = 1;"
        let updatedSource = "* comment */\nconst value = 1;"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)
        let oldCommentExtent = (updatedSource as NSString).range(of: "* comment */")

        #expect(incremental.tokens == full.tokens)
        #expect(
            SyntaxEditorRangeUtilities.intersection(
                of: refreshRangeUnion(incremental),
                and: oldCommentExtent
            ) == oldCommentExtent
        )
    }

    @Test("SyntaxHighlighterEngine keeps incremental refresh ranges local")
    func highlighterIncrementalRefreshRangeStaysLocal() async throws {
        let prefix = (0..<400)
            .map { "const value\($0) = \($0);" }
            .joined(separator: "\n")
        let source = "\(prefix)\nconst tail = 1;"
        let updatedSource = "\(prefix)\nlet tail = 2;"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count / 10)
    }

    @Test("SyntaxHighlighterEngine handles emoji and newline incremental edit ranges")
    func highlighterIncrementalEditHandlesEmojiAndNewlines() async throws {
        let source = """
        const label = "😀";
        let value = 1;
        """
        let updatedSource = """
        const label = "😀";
        let newer = 2;
        const done = true;
        """
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)
        let sourceLength = updatedSource.utf16.count

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
        #expect(incremental.tokens.allSatisfy { token in
            token.range.location >= 0 &&
                token.range.length > 0 &&
                token.range.upperBound <= sourceLength
            })
    }

    @Test("SyntaxHighlighterEngine keeps incremental state after deleting a line break")
    func highlighterIncrementalEditHandlesDeletedLineBreakFollowedByEdit() async throws {
        let source = "const first = 1;\nconst second = 2;\nconst third = 3;"
        let mergedSource = "const first = 1;const second = 2;\nconst third = 3;"
        let updatedSource = "const first = 1;let second = 2;\nconst third = 3;"
        let deleteLineBreak = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: mergedSource))
        let editMergedLine = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: mergedSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: mergedSource,
            language: SyntaxLanguage.javascript,
            mutation: deleteLineBreak
        )
        let incremental = await incrementalEngine.update(
            previousSource: mergedSource,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: editMergedLine
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
    }

    @Test("SyntaxHighlighterEngine keeps incremental state after deleting a carriage-return line break")
    func highlighterIncrementalEditHandlesDeletedCarriageReturnFollowedByEdit() async throws {
        let source = "const first = 1;\rconst second = 2;\rconst third = 3;"
        let mergedSource = "const first = 1;const second = 2;\rconst third = 3;"
        let updatedSource = "const first = 1;let second = 2;\rconst third = 3;"
        let deleteLineBreak = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: mergedSource))
        let editMergedLine = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: mergedSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: mergedSource,
            language: SyntaxLanguage.javascript,
            mutation: deleteLineBreak
        )
        let incremental = await incrementalEngine.update(
            previousSource: mergedSource,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: editMergedLine
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
    }

    @Test("SyntaxHighlighterEngine keeps incremental state after inserting a carriage-return line break")
    func highlighterIncrementalEditHandlesInsertedCarriageReturnFollowedByEdit() async throws {
        let source = "const first = 1;const second = 2;\rconst third = 3;"
        let splitSource = "const first = 1;\rconst second = 2;\rconst third = 3;"
        let updatedSource = "const first = 1;\rlet second = 2;\rconst third = 3;"
        let insertLineBreak = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: splitSource))
        let editSplitLine = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: splitSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: splitSource,
            language: SyntaxLanguage.javascript,
            mutation: insertLineBreak
        )
        let incremental = await incrementalEngine.update(
            previousSource: splitSource,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: editSplitLine
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
    }

    @Test("SyntaxHighlightMutationLineRange includes the line created by newline insertion")
    func syntaxHighlightMutationLineRangeIncludesInsertedNewlineLine() throws {
        let source = "let first = 1let second = 2"
        let updatedSource = "let first = 1\nlet second = 2"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let nsSource = updatedSource as NSString

        let changedLineRange = SyntaxHighlightMutationLineRange.changedLineRange(
            for: mutation,
            in: nsSource
        )

        #expect(changedLineRange == NSRange(location: 0, length: nsSource.length))
    }

    @Test("SyntaxHighlightMutationLineRange includes the line created by carriage-return insertion")
    func syntaxHighlightMutationLineRangeIncludesInsertedCarriageReturnLine() throws {
        let source = "let first = 1let second = 2"
        let updatedSource = "let first = 1\rlet second = 2"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let nsSource = updatedSource as NSString

        let changedLineRange = SyntaxHighlightMutationLineRange.changedLineRange(
            for: mutation,
            in: nsSource
        )

        #expect(changedLineRange == NSRange(location: 0, length: nsSource.length))
    }

    @Test("SyntaxHighlighterEngine keeps incremental state after deleting a final line break")
    func highlighterIncrementalEditHandlesDeletedFinalLineBreakFollowedByEdit() async throws {
        let source = "const first = 1;\n"
        let mergedSource = "const first = 1;"
        let updatedSource = "const first = 1; const second = 2;"
        let deleteLineBreak = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: mergedSource))
        let appendStatement = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: mergedSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: mergedSource,
            language: SyntaxLanguage.javascript,
            mutation: deleteLineBreak
        )
        let incremental = await incrementalEngine.update(
            previousSource: mergedSource,
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: appendStatement
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
    }

    @Test("SyntaxHighlighterEngine keeps incremental state with carriage-return separators")
    func highlighterIncrementalEditHandlesCarriageReturnSeparators() async throws {
        let source = "const first = 1;\rconst second = 2;"
        let updatedAfterCR = "const first = 1;\rlet second = 2;"
        let finalSource = "let first = 1;\rlet second = 2;"
        let editAfterCR = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedAfterCR))
        let editBeforeCR = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: updatedAfterCR, to: finalSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.javascript)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: updatedAfterCR,
            language: SyntaxLanguage.javascript,
            mutation: editAfterCR
        )
        let incremental = await incrementalEngine.update(
            previousSource: updatedAfterCR,
            source: finalSource,
            language: SyntaxLanguage.javascript,
            mutation: editBeforeCR
        )
        let full = await fullEngine.reset(source: finalSource, language: SyntaxLanguage.javascript)

        #expect(highlightTokensMatch(incremental.tokens, full.tokens))
    }

    @Test("SyntaxHighlighterEngine keeps invalidation query ranges in UTF-16 coordinates")
    func highlighterUsesUTF16InvalidationQueryRanges() {
        var invalidatedSet = IndexSet()
        invalidatedSet.insert(integersIn: 120..<150)
        let queryRange = SyntaxEditorHighlighting.Invalidation.queryRange(
            invalidatedSet: invalidatedSet,
            mutation: SyntaxEditorTextChange.Replacement(location: 180, length: 0, replacement: ""),
            sourceUTF16Length: 240
        )
        #expect(queryRange == NSRange(location: 120, length: 60))

        invalidatedSet = IndexSet()
        invalidatedSet.insert(integersIn: 241..<280)
        #expect(
            SyntaxEditorHighlighting.Invalidation.queryRange(
                invalidatedSet: invalidatedSet,
                mutation: SyntaxEditorTextChange.Replacement(location: 180, length: 0, replacement: ""),
                sourceUTF16Length: 240
            ) == NSRange(location: 180, length: 60)
        )
    }

    @Test("SyntaxHighlighterEngine falls back to full reset on stale updates and language changes")
    func highlighterFallsBackToFullResetWhenIncrementalStateDoesNotMatch() async throws {
        let source = "const value = 42;"
        let updatedSource = "let value = 42;"
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let engine = SyntaxHighlighterEngine()

        _ = await engine.reset(source: source, language: SyntaxLanguage.javascript)
        let staleUpdate = await engine.update(
            previousSource: "stale",
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation
        )
        let fullJavaScript = await SyntaxHighlighterEngine()
            .reset(source: updatedSource, language: SyntaxLanguage.javascript)

        #expect(highlightTokensMatch(staleUpdate.tokens, fullJavaScript.tokens))
        #expect(refreshRangeUnion(staleUpdate).location <= mutation.range.location)

        let jsonSource = #"{"enabled": true}"#
        let languageChange = await engine.update(
            previousSource: updatedSource,
            source: jsonSource,
            language: SyntaxLanguage.json,
            mutation: SyntaxEditorTextChange.Replacement(location: 0, length: updatedSource.utf16.count, replacement: jsonSource)
        )
        let fullJSON = await SyntaxHighlighterEngine()
            .reset(source: jsonSource, language: SyntaxLanguage.json)

        #expect(languageChange.language == SyntaxLanguage.json)
        #expect(highlightTokensMatch(languageChange.tokens, fullJSON.tokens))
    }

    @Test("SyntaxHighlighterEngine coalesces stale mutations against the current session source")
    func highlighterCoalescesMutationBaseMismatchAgainstSessionSource() async throws {
        let sessionSource = "const value = 1;\nconst other = 2;"
        let stalePreviousSource = "const value = 2;\nconst other = 2;"
        let updatedSource = "const value = 3;\nconst other = 2;"
        let staleMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: stalePreviousSource, to: updatedSource))
        let engine = SyntaxHighlighterEngine()

        _ = await engine.reset(source: sessionSource, language: SyntaxLanguage.javascript)
        let staleUpdate = await engine.update(
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: staleMutation,
            revision: 2
        )
        let full = await SyntaxHighlighterEngine()
            .reset(source: updatedSource, language: SyntaxLanguage.javascript, revision: 2)

        #expect(highlightTokensMatch(await engine.currentTokensForTesting(), full.tokens))
        #expect(refreshRangeUnion(staleUpdate).location == 0)
        #expect(refreshRangeUnion(staleUpdate).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine survives repeated paste-sized Swift updates")
    func highlighterSurvivesRepeatedPasteSizedSwiftUpdates() async {
        let engine = SyntaxHighlighterEngine()
        var source = "struct PasteTarget {\n"
        var result = await engine.reset(source: source, language: SyntaxLanguage.swift, revision: 1)

        for index in 0..<8 {
            let insertion = String(
                repeating: "    let value\(index) = max(1, 2)\n",
                count: 80
            )
            let mutation = SyntaxEditorTextChange.Replacement(
                location: source.utf16.count,
                length: 0,
                replacement: insertion
            )
            source += insertion
            result = await engine.update(
                source: source,
                language: SyntaxLanguage.swift,
                mutation: mutation,
                revision: index + 2
            )
            #expect(result.source == source)
            #expect(result.tokens.allSatisfy { $0.range.upperBound <= source.utf16.count })
        }

        source += "}\n"
        result = await engine.update(
            source: source,
            language: SyntaxLanguage.swift,
            mutation: SyntaxEditorTextChange.Replacement(location: source.utf16.count - 2, length: 0, replacement: "}\n"),
            revision: 20
        )
        let full = await SyntaxHighlighterEngine()
            .reset(source: source, language: SyntaxLanguage.swift, revision: 20)

        #expect(highlightTokensMatch(await engine.currentTokensForTesting(), full.tokens))
    }

    @Test("SyntaxHighlighterEngine keeps switch-heavy Swift paste updates finite")
    func highlighterKeepsSwitchHeavySwiftPasteUpdatesFinite() async {
        let engine = SyntaxHighlighterEngine()
        var source = """
        struct PasteTarget {
            func render(_ input: Int) {
                switch input {
                default:
                    break
                }
            }
        }

        """
        var result = await engine.reset(source: source, language: SyntaxLanguage.swift, revision: 1)

        for pasteIndex in 0..<4 {
            let insertion = (0..<60).map { caseIndex in
                let valueIndex = pasteIndex * 60 + caseIndex
                return """
                    case \(valueIndex):
                        let value\(valueIndex) = input + \(valueIndex)
                        _ = value\(valueIndex)

                """
            }.joined()
            let insertionLocation = (source as NSString).range(of: "        default:").location
            let mutation = SyntaxEditorTextChange.Replacement(
                location: insertionLocation,
                length: 0,
                replacement: insertion
            )
            source = (source as NSString).replacingCharacters(
                in: NSRange(location: insertionLocation, length: 0),
                with: insertion
            )
            result = await engine.update(
                source: source,
                language: SyntaxLanguage.swift,
                mutation: mutation,
                revision: pasteIndex + 2
            )

            #expect(result.source == source)
            #expect(result.tokens.allSatisfy { $0.range.upperBound <= source.utf16.count })
        }

        let full = await SyntaxHighlighterEngine()
            .reset(source: source, language: SyntaxLanguage.swift, revision: 20)
        #expect(highlightTokensMatch(await engine.currentTokensForTesting(), full.tokens))
    }

    @Test("Swift semantic overlay exits before indexing cancelled paste work")
    func swiftSemanticOverlayExitsBeforeIndexingCancelledPasteWork() async {
        let source = String(
            repeating: """
            struct CancelledPaste {
                func render(_ input: Int) {
                    switch input {
                    case 0:
                        let value = input + 1
                        _ = value
                    default:
                        break
                    }
                }
            }

            """,
            count: 400
        )
        let task = Task {
            var state: SwiftSemanticOverlayState?
            return SwiftSyntaxOverlayTokenProvider.mergingOverlayResult(
                tokens: [],
                source: source,
                state: &state
            )
        }
        task.cancel()

        let result = await task.value
        #expect(result.isCancelled)
        #expect(result.tokens.isEmpty)
    }

    @Test("SyntaxHighlighterEngine does not cache cancelled Swift reset tokens")
    func highlighterDoesNotCacheCancelledSwiftResetTokens() async throws {
        let source = String(
            repeating: """
            struct CancelledReset {
                func render(_ input: Int) -> Int {
                    let value = input + 1
                    return value
                }
            }

            """,
            count: 500
        )
        let engine = SyntaxHighlighterEngine()
        let resetTask = Task {
            await engine.reset(source: source, language: SyntaxLanguage.swift, revision: 1)
        }
        resetTask.cancel()
        let cancelled = await resetTask.value

        #expect(cancelled.tokens.isEmpty)

        let updatedSource = source.replacingOccurrences(of: "input + 1", with: "input + 2")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incremental = await engine.update(
            source: updatedSource,
            language: SyntaxLanguage.swift,
            mutation: mutation,
            revision: 2
        )
        let full = await SyntaxHighlighterEngine()
            .reset(source: updatedSource, language: SyntaxLanguage.swift, revision: 3)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine cancellation lets replacement request run immediately")
    func highlighterCancellationLetsReplacementRequestRunImmediately() async throws {
        let staleSource = String(
            repeating: """
            struct SupersededRequest {
                func render(_ input: Int) -> Int {
                    let value = input + 1
                    return value
                }
            }

            """,
            count: 2_000
        )
        let freshSource = "let fresh = 1"
        let engine = SyntaxHighlighterEngine()

        let staleStream = await engine.replaceCurrentRequest(with: SyntaxEditorHighlighting.Request(
            source: staleSource,
            language: SyntaxLanguage.swift,
            revision: 1,
            operation: .reset
        ))
        var staleIterator = staleStream.makeAsyncIterator()
        let staleFastPass = await staleIterator.next()
        #expect(staleFastPass?.revision == 1)
        #expect(staleFastPass?.phase == .syntacticFastPass)

        let freshStream = await engine.replaceCurrentRequest(with: SyntaxEditorHighlighting.Request(
            source: freshSource,
            language: SyntaxLanguage.swift,
            revision: 2,
            operation: .reset
        ))

        let freshResults = await collectHighlightPhases(freshStream)
        let freshComplete = try #require(freshResults.last)
        #expect(freshResults.allSatisfy { $0.revision == 2 })
        #expect(freshComplete.phase == .complete)
        #expect(freshComplete.source == freshSource)
        #expect(freshComplete.tokens.isEmpty == false)

        let staleComplete = await staleIterator.next()
        #expect(staleComplete == nil)
    }

    @Test("SyntaxHighlighterEngine rebuilds semantic state after cancelled incremental update")
    func highlighterRebuildsSemanticStateAfterCancelledIncrementalUpdate() async throws {
        let prefix = (0..<2_000)
            .map { "let cachedValue\($0) = \($0)" }
            .joined(separator: "\n")
        let source = """
        \(prefix)

        func render() -> Int {
            let item = 1
            return item
        }
        """
        let firstUpdatedSource = source.replacingOccurrences(of: "let item = 1", with: "let renamed = 1")
        let firstMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: firstUpdatedSource))
        let secondUpdatedSource = firstUpdatedSource.replacingOccurrences(of: "return item", with: "return renamed")
        let secondMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: firstUpdatedSource, to: secondUpdatedSource))
        let engine = SyntaxHighlighterEngine()

        _ = await engine.reset(source: source, language: SyntaxLanguage.swift, revision: 1)
        let firstPhaseTask = Task {
            let phases = await engine.updatePhases(
                source: firstUpdatedSource,
                language: SyntaxLanguage.swift,
                mutation: firstMutation,
                revision: 2
            )
            var iterator = phases.makeAsyncIterator()
            return await iterator.next()
        }
        let firstPhase = await firstPhaseTask.value
        #expect(firstPhase?.phase == .syntacticFastPass)
        try await Task.sleep(for: .milliseconds(10))

        let incremental = await engine.update(
            previousSource: firstUpdatedSource,
            source: secondUpdatedSource,
            language: SyntaxLanguage.swift,
            mutation: secondMutation
        )
        let full = await SyntaxHighlighterEngine().reset(
            source: secondUpdatedSource,
            language: SyntaxLanguage.swift
        )

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine keeps current session after cancelled reset")
    func highlighterKeepsCurrentSessionAfterCancelledReset() async throws {
        let source = """
        const first = 1;
        const second = 2;
        """
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: source, language: SyntaxLanguage.javascript, revision: 1)

        let resetTask = Task {
            await engine.reset(
                source: "const stale = 0;",
                language: SyntaxLanguage.javascript,
                revision: 2
            )
        }
        resetTask.cancel()
        let cancelled = await resetTask.value
        #expect(cancelled.tokens.isEmpty)

        let updatedSource = source.replacingOccurrences(of: "second = 2", with: "second = 3")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incremental = await engine.update(
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation,
            revision: 3
        )

        #expect(incremental.tokens.isEmpty == false)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine keeps current session after cancelled empty reset")
    func highlighterKeepsCurrentSessionAfterCancelledEmptyReset() async throws {
        let source = """
        const first = 1;
        const second = 2;
        """
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: source, language: SyntaxLanguage.javascript, revision: 1)

        let resetTask = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await engine.reset(
                source: "",
                language: SyntaxLanguage.javascript,
                revision: 2
            )
        }
        resetTask.cancel()
        let cancelled = await resetTask.value
        #expect(cancelled.tokens.isEmpty)

        let updatedSource = source.replacingOccurrences(of: "second = 2", with: "second = 3")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incremental = await engine.update(
            source: updatedSource,
            language: SyntaxLanguage.javascript,
            mutation: mutation,
            revision: 3
        )

        #expect(incremental.tokens.isEmpty == false)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine returns UTF-16-safe ranges for non-ASCII source")
    func highlighterHandlesNonASCIIRanges() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = "const label = \"こんにちは😀\";"
        let tokens = await engine.render(source: source, language: SyntaxLanguage.javascript)
        let sourceLength = source.utf16.count

        #expect(tokens.isEmpty == false)
        #expect(tokens.allSatisfy { token in
            token.range.location >= 0 &&
                token.range.length > 0 &&
                token.range.upperBound <= sourceLength
            })
    }

    @Test("SyntaxHighlighterEngine keeps parser chunks UTF-16 boundary safe")
    func highlighterKeepsParserChunksUTF16BoundarySafe() async {
        let prefix = "// " + String(repeating: "a", count: 1020)
        #expect(prefix.utf16.count == 1023)

        let source = "\(prefix)😀\nlet value = 1\n"
        let tokens = await SyntaxHighlighterEngine().reset(
            source: source,
            language: SyntaxLanguage.swift
        ).tokens
        let keywordRange = (source as NSString).range(of: "let")

        #expect(tokens.contains { token in
            token.syntaxID == .keyword && token.range == keywordRange
        })
    }

    @Test("SyntaxHighlighterEngine highlights XML structures")
    func highlighterSupportsXML() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE note [
            <!ELEMENT note (#PCDATA)>
        ]>
        <note priority="high"><!-- reminder --><![CDATA[<escaped/>]]></note>
        """

        let tokens = await engine.render(source: source, language: SyntaxLanguage.xml)

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains { $0.syntaxID == .keyword })
        #expect(tokens.contains { $0.syntaxID == .attribute })
        #expect(tokens.contains { $0.syntaxID == .comment })
    }

    @Test("SyntaxHighlighterEngine highlights TOML structures")
    func highlighterSupportsTOML() async {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        # comment
        [package]
        name = "SyntaxEditorUI"
        enabled = true
        count = 1
        """

        let tokens = await engine.render(source: source, language: SyntaxLanguage.toml)
        let nsSource = source as NSString
        let commentRange = nsSource.range(of: "# comment")
        let propertyRange = nsSource.range(of: "name")
        let stringRange = nsSource.range(of: "\"SyntaxEditorUI\"")
        let booleanRange = nsSource.range(of: "true")
        let numberRange = nsSource.range(of: "1")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            tokenIntersects($0, range: commentRange, syntaxID: .comment, language: .toml)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: propertyRange, syntaxID: .attribute, language: .toml)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: stringRange, syntaxID: .string, language: .toml)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: booleanRange, syntaxID: .keyword, language: .toml)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: numberRange, syntaxID: .number, language: .toml)
        })
    }

    @Test("SyntaxHighlighterEngine maps TOML captures through editor syntax families")
    func highlighterMapsTOMLCapturesToEditorSyntaxFamilies() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = try referenceSampleText(named: "Reference.toml")
        let tokens = await engine.render(source: source, language: SyntaxLanguage.toml)

        let sectionName = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "package",
            syntaxID: "plain",
            language: .toml,
            inOccurrenceOf: "[package]"
        )
        let key = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "name",
            syntaxID: "attribute",
            language: .toml,
            inOccurrenceOf: #"name = "ReferencePreview""#
        )
        let operatorToken = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "=",
            syntaxID: "plain",
            language: .toml,
            inOccurrenceOf: #"name = "ReferencePreview""#
        )
        let string = try semanticSnapshot(
            in: tokens,
            source: source,
            text: #""ReferencePreview""#,
            syntaxID: "string",
            language: .toml
        )
        let boolean = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "true",
            syntaxID: "keyword",
            language: .toml,
            inOccurrenceOf: "enabled = true"
        )
        let number = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "2",
            syntaxID: "number",
            language: .toml,
            inOccurrenceOf: "count = 2"
        )

        #expect(sectionName.styleKeys.first == "editor.syntax.plain")
        #expect(key.styleKeys.first == "editor.syntax.attribute")
        #expect(operatorToken.styleKeys.first == "editor.syntax.plain")
        #expect(string.styleKeys.first == "editor.syntax.string")
        #expect(boolean.styleKeys.first == "editor.syntax.keyword")
        #expect(number.styleKeys.first == "editor.syntax.number")
    }
}
