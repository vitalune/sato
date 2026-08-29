import Foundation
import Testing
@testable import leanring_buddy

struct MarkdownRendererTests {
    @Test
    func preprocessConvertsBiologyFormulaExample() {
        let rawMarkdown = """
        ## Common Biology Formulas

        ### Photosynthesis
        [
        6CO_2 + 6H_2O + \\text{light energy} \\rightarrow C_6H_{12}O_6 + 6O_2
        ]
        """

        let displayMarkdown = MarkdownRenderer.preprocessForDisplay(rawMarkdown)

        #expect(displayMarkdown.contains("## Common Biology Formulas"))
        #expect(displayMarkdown.contains("### Photosynthesis"))
        #expect(displayMarkdown.contains("6CO₂"))
        #expect(displayMarkdown.contains("6H₂O"))
        #expect(displayMarkdown.contains("light energy"))
        #expect(displayMarkdown.contains("→"))
        #expect(displayMarkdown.contains("C₆H₁₂O₆"))
        #expect(displayMarkdown.contains("6O₂"))
        #expect(!displayMarkdown.contains("\\text"))
        #expect(!displayMarkdown.contains("\\rightarrow"))
        #expect(!displayMarkdown.contains("CO_2"))
    }

    @Test
    func preprocessConvertsInlineAndDisplayMathDelimiters() {
        let rawMarkdown = "Energy is $E = mc^2$ and display:\n$$\\frac{a}{b}$$"
        let displayMarkdown = MarkdownRenderer.preprocessForDisplay(rawMarkdown)

        #expect(displayMarkdown.contains("E = mc²"))
        #expect(!displayMarkdown.contains("$E"))
        #expect(displayMarkdown.contains("(a)/(b)"))
        #expect(!displayMarkdown.contains("\\frac"))
    }

    @Test
    func preprocessLeavesNonMathBracketBlocksAlone() {
        let rawMarkdown = """
        Notes
        [
        just a note without math
        ]
        """
        let displayMarkdown = MarkdownRenderer.preprocessForDisplay(rawMarkdown)
        #expect(displayMarkdown.contains("[\njust a note without math\n]"))
    }

    @Test
    func blocksPreserveHeadersParagraphsAndListMarkers() {
        let markdown = """
        ## Step by step

        A release candidate was prepared.

        - The version was verified.
        - All tests passed.

        1. Publish the release.
        2. Deploy the appcast.
        """

        let blocks = MarkdownRenderer.blocks(for: markdown)
        let blockDescriptions = blocks.map { block -> String in
            switch block {
            case .heading(let level, let text):
                return "heading:\(level):\(text)"
            case .paragraph(let text):
                return "paragraph:\(text)"
            case .unorderedListItem(let indentLevel, let text):
                return "bullet:\(indentLevel):\(text)"
            case .orderedListItem(let indentLevel, let number, let text):
                return "number:\(indentLevel):\(number):\(text)"
            case .codeBlock(let text):
                return "code:\(text)"
            case .blockQuote(let text):
                return "quote:\(text)"
            case .horizontalRule:
                return "rule"
            }
        }

        #expect(blockDescriptions == [
            "heading:2:Step by step",
            "paragraph:A release candidate was prepared.",
            "bullet:0:The version was verified.",
            "bullet:0:All tests passed.",
            "number:0:1:Publish the release.",
            "number:0:2:Deploy the appcast."
        ])
    }

    @Test
    func blocksKeepFencedCodeTogether() {
        let blocks = MarkdownRenderer.blocks(for:
            """
            Before.

            ```swift
            let releaseVersion = "1.2.2"
            ```

            After.
            """
        )

        #expect(blocks.count == 3)
        guard case .codeBlock(let code) = blocks[1] else {
            Issue.record("Expected fenced content to be one code block.")
            return
        }
        #expect(code == #"let releaseVersion = "1.2.2""#)
    }

    @Test
    func renderInlineParsesEmphasisAndCode() {
        let attributedString = MarkdownRenderer.renderInline("This has **bold** and `code`.")
        let plainText = String(attributedString.characters)

        #expect(plainText == "This has bold and code.")
    }
}
