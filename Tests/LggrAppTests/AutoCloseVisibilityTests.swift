import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

// The surfaces that make an automatic close *visible*. See docs/_design/04-screens.md § 3.3 and
// `SessionAutoClose`.
//
// Why this file exists rather than another suite over the decision itself: the decision was already
// proved by `SessionAutoCloseTests`, and `NotificationServiceTests` already proves that
// `SessionManager` stamps the session and builds `autoCloseNotice`. What none of them could see is
// whether anything *renders* either one — and it did not. `autoCloseNotice` had no reader, and
// `autoClosedAt` and `autoCloseReason` were stored on every closed session and drawn nowhere, so on a
// fresh install (where the completion notification is off, like every other kind) a session's end
// simply moved with nothing saying why.
//
// The views themselves cannot be asserted without a host, so what is pinned here is every string and
// every role those views read. A regression that removes the mark still has to delete one of these.

@Suite("An automatic close is visible on the record")
struct AutoCloseVisibilityTests {

    /// 2024-01-15 09:00:00 UTC, a Monday. Fixed so no assertion depends on when the suite runs.
    private let mondayJan15 = Date(timeIntervalSinceReferenceDate: 726_969_600 + 9 * 3600)

    @Test("The mark names the witness the end came from, and when the app decided it")
    func namesTheWitness() {
        for reason in SessionAutoCloseReason.allCases {
            let help = AutoClosedMark.help(mondayJan15, reason: reason)
            // The witness, in the wording `SessionAutoCloseReason` already owns — so the row, the
            // detail screen and the notification cannot word the same fact three ways.
            #expect(help.contains(reason.displayName))
            // And who decided it. "Ended at 12:04" with no author is the number the user cannot check.
            #expect(help.contains("decided by Lggr"))
        }
    }

    @Test("A record with no stored reason still says the app is the author")
    func reasonlessRecordStillAttributed() {
        // Only reachable for a session written before the reason sat beside the instant. It must still
        // say who chose the number rather than falling back to silence.
        let help = AutoClosedMark.help(mondayJan15, reason: nil)
        #expect(help.contains("Lggr"))
        #expect(!help.isEmpty)
    }

    @Test("Nothing on the mark reads as a verdict on the person")
    func neverBlames() {
        var sentences = [AutoClosedMark.spoken, AutoClosedMark.help(mondayJan15, reason: nil)]
        sentences += SessionAutoCloseReason.allCases.map {
            AutoClosedMark.help(mondayJan15, reason: $0)
        }

        for sentence in sentences {
            let lowered = sentence.lowercased()
            for word in NotificationCopy.bannedWords {
                #expect(!lowered.contains(word), "\(sentence) contains \(word)")
            }
            // The subject is the record, never the reader.
            #expect(!lowered.contains("you "))
            #expect(!lowered.contains("forgot"))
        }
    }

    @Test("Every reason carries a glyph, so the mark never draws nothing")
    func everyReasonHasAGlyph() {
        for reason in SessionAutoCloseReason.allCases {
            #expect(!reason.symbolName.isEmpty)
        }
        // The fallback for a record with no stored reason.
        #expect(!Icon.autoClosed.isEmpty)
    }

    @Test("A session Lggr closed carries the provenance the mark is drawn from")
    func provenanceIsOnTheSession() {
        var session = FocusSession(intendedOutcome: "Receipt ingestion", startedAt: mondayJan15)
        let closeAt = mondayJan15.addingTimeInterval(40 * 60)
        let applied = session.applyAutoClose(
            SessionAutoClose.Decision(
                closeAt: closeAt,
                reason: .idle,
                uncountedDuration: 20 * 60
            ),
            at: mondayJan15.addingTimeInterval(60 * 60)
        )

        #expect(applied)
        // The three the row and the detail screen read. Without all three there is a mark with
        // nothing to say.
        #expect(session.wasAutoClosed)
        #expect(session.autoClosedAt != nil)
        #expect(session.autoCloseReason == .idle)
        // And it is *not* an edit: the app must never claim the user's authorship for its own
        // arithmetic, which is why these are two marks and not one.
        #expect(!session.wasEdited)
    }
}

@Suite("The one banner distinguishes a failure from a fact")
struct BannerKindTests {

    @Test("A failure is still announced as an error")
    func failureUnchanged() {
        // The three existing call sites pass nothing, so this is what they get. If this changes,
        // every error announcement in the app changed with it.
        #expect(ErrorBanner.Kind.failure.spokenRole == "Error")
        #expect(ErrorBanner.Kind.failure.symbolName == Icon.error)
    }

    @Test("Provenance is announced as a notice, and never wears the warning triangle")
    func noticeIsNotAnError() {
        #expect(ErrorBanner.Kind.notice.spokenRole == "Notice")
        #expect(ErrorBanner.Kind.notice.spokenRole != ErrorBanner.Kind.failure.spokenRole)
        #expect(ErrorBanner.Kind.notice.symbolName != Icon.error)
        #expect(ErrorBanner.Kind.notice.symbolName == Icon.notice)
    }

    @Test("The auto-close sentence is what the notice carries, verbatim")
    func noticeCarriesTheDecisionsOwnSentence() {
        // The sentence `SessionManager` puts on `autoCloseNotice` and the one the banner shows are one
        // string: `SessionAutoClose.Decision.sentence(closedAtText:)`. Asserted here so a second
        // wording cannot appear on screen.
        let decision = SessionAutoClose.Decision(
            closeAt: Date(timeIntervalSinceReferenceDate: 726_969_600),
            reason: .appNotRunning,
            uncountedDuration: 11 * 3600
        )
        let sentence = decision.sentence(closedAtText: "18:00")
        #expect(sentence == "Ended at 18:00, the last minute Lggr was running.")
    }
}
