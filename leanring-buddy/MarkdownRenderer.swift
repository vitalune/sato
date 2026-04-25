import Foundation
import SwiftUI

enum MarkdownRenderer {
    static func render(_ rawMarkdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        do {
            var attributedString = try AttributedString(markdown: rawMarkdown, options: options)
            styleInlineCode(in: &attributedString)
            return attributedString
        } catch {
            return AttributedString(rawMarkdown)
        }
    }

    private static func styleInlineCode(in attributedString: inout AttributedString) {
        for run in attributedString.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let range = run.range
                attributedString[range].font = .system(size: 12, design: .monospaced)
                attributedString[range].foregroundColor = DS.Colors.codeText
            }
        }
    }
}
