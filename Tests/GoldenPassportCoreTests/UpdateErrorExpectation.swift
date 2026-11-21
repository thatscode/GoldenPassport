import Foundation
import Testing
@testable import GoldenPassportCore

/// The case name of an `UpdateError` ("download" for `.download("…")`), nil for any other error.
func updateErrorCase(_ error: Error) -> String? {
    guard let error = error as? UpdateError else { return nil }
    return Mirror(reflecting: error).children.first?.label ?? String(describing: error)
}

/// Expects `body` to throw the `UpdateError` case `name`, whatever its message.
/// Swift 6.0 (Xcode 16.0) crashes type-checking `#expect { … } throws: { error in if case … }`,
/// so tests use this instead.
func expectUpdateError(_ name: String, sourceLocation: SourceLocation = #_sourceLocation,
                       _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected UpdateError.\(name), but nothing was thrown", sourceLocation: sourceLocation)
    } catch {
        #expect(updateErrorCase(error) == name, "Threw \(error)", sourceLocation: sourceLocation)
    }
}

struct UpdateErrorExpectationTests {
    @Test func namesTheCaseWithoutItsMessage() {
        #expect(updateErrorCase(UpdateError.download("HTTP 404")) == "download")
        #expect(updateErrorCase(UpdateError.sizeMismatch(expected: 1, actual: 2)) == "sizeMismatch")
        #expect(updateErrorCase(UpdateError.digestMismatch) == "digestMismatch")
        #expect(updateErrorCase(CocoaError(.fileNoSuchFile)) == nil)
    }
}
