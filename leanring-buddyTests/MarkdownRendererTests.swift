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
    func renderParsesHeadingsAndEmphasis() throws {
        let attributedString = MarkdownRenderer.render(
            "## Title\n\nThis has **bold** and `code`."
        )
        let plainText = String(attributedString.characters)
        #expect(plainText.contains("Title"))
        #expect(plainText.contains("bold"))
        #expect(plainText.contains("code"))
        #expect(!plainText.contains("##"))
        #expect(!plainText.contains("**"))
    }
}
