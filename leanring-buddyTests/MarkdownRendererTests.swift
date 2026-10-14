import Foundation
import Testing
@testable import leanring_buddy

struct MarkdownRendererTests {
    @Test
    func bracketWrappedBiologyFormulaBecomesDisplayMath() {
        let rawMarkdown = """
        ## Common Biology Formulas

        ### Photosynthesis
        [
        6CO_2 + 6H_2O + \\text{light energy} \\rightarrow C_6H_{12}O_6 + 6O_2
        ]
        """

        let blockDescriptions = describe(MarkdownRenderer.blocks(for: rawMarkdown))

        #expect(blockDescriptions == [
            "heading:2:Common Biology Formulas",
            "heading:3:Photosynthesis",
            "math:6CO_2 + 6H_2O + \\text{light energy} \\rightarrow C_6H_{12}O_6 + 6O_2",
        ])
    }

    @Test
    func inlineAndDisplayMathDelimitersAreSeparated() {
        let rawMarkdown = "Energy is $E = mc^2$ and display:\n$$\\frac{a}{b}$$"
        let blocks = MarkdownRenderer.blocks(for: rawMarkdown)

        #expect(describe(blocks) == [
            "paragraph:Energy is $E = mc^2$ and display:",
            "math:\\frac{a}{b}",
        ])
        #expect(MarkdownRenderer.inlineSegments(in: "Energy is $E = mc^2$ and display:") == [
            .markdown("Energy is "),
            .math(latex: "E = mc^2", isDisplayStyle: false),
            .markdown(" and display:"),
        ])
    }

    @Test
    func backslashDelimitersAreRecognized() {
        let blocks = MarkdownRenderer.blocks(for: "Solve \\(x^2 = 4\\):\n\\[\nx = \\pm 2\n\\]\nDone.")

        #expect(describe(blocks) == [
            "paragraph:Solve \\(x^2 = 4\\):",
            "math:x = \\pm 2",
            "paragraph:Done.",
        ])
        #expect(MarkdownRenderer.inlineSegments(in: "Solve \\(x^2 = 4\\):") == [
            .markdown("Solve "),
            .math(latex: "x^2 = 4", isDisplayStyle: false),
            .markdown(":"),
        ])
    }

    @Test
    func gluedDisplayFencesDoNotSwallowFollowingText() {
        let rawMarkdown = "We solve:\n\n$$\\begin{aligned}\nx &= 1 \\\\\ny &= 2\n\\end{aligned}$$ [2]\n\nAfter the system."
        let blockDescriptions = describe(MarkdownRenderer.blocks(for: rawMarkdown))

        #expect(blockDescriptions == [
            "paragraph:We solve:",
            "math:\\begin{aligned}\nx &= 1 \\\\\ny &= 2\n\\end{aligned}",
            "paragraph:[2]",
            "paragraph:After the system.",
        ])
    }

    @Test
    func singleLineDisplayMathAndTrailingOpenerAreSplit() {
        let blockDescriptions = describe(MarkdownRenderer.blocks(for: "Para:\n$$x^2$$\nafter.\n\nThus: $$\ny = 3\n$$"))

        #expect(blockDescriptions == [
            "paragraph:Para:",
            "math:x^2",
            "paragraph:after.",
            "paragraph:Thus:",
            "math:y = 3",
        ])
    }

    @Test
    func unbalancedDisplayFenceStaysVisibleText() {
        let blockDescriptions = describe(MarkdownRenderer.blocks(for: "Intro.\n\n$$\nnever closed **text**\n\nMore."))

        #expect(blockDescriptions.first == "paragraph:Intro.")
        #expect(blockDescriptions.contains { $0.contains("never closed **text**") })
        #expect(blockDescriptions.contains { $0.contains("More.") })
        #expect(!blockDescriptions.contains { $0.hasPrefix("math:") })
    }

    @Test
    func bareMathEnvironmentBecomesDisplayMath() {
        let rawMarkdown = """
        The piecewise function:
        \\begin{cases}
        x^2 & x \\ge 0 \\\\
        -x & x < 0
        \\end{cases}
        """

        #expect(describe(MarkdownRenderer.blocks(for: rawMarkdown)) == [
            "paragraph:The piecewise function:",
            "math:\\begin{cases}\nx^2 & x \\ge 0 \\\\\n-x & x < 0\n\\end{cases}",
        ])
    }

    @Test
    func undelimitedFormulaParagraphBecomesDisplayMath() {
        let blockDescriptions = describe(MarkdownRenderer.blocks(for: "E_k = \\frac{1}{2} m v^2\n\nThis uses \\frac{1}{2} in prose."))

        #expect(blockDescriptions == [
            "math:E_k = \\frac{1}{2} m v^2",
            "paragraph:This uses \\frac{1}{2} in prose.",
        ])
    }

    @Test
    func dollarAmountsAreNotMath() {
        #expect(MarkdownRenderer.inlineSegments(in: "It costs $5 and $6 total.") == [
            .markdown("It costs $5 and $6 total."),
        ])
        #expect(MarkdownRenderer.inlineSegments(in: "Between $10 and $20, use $x$.") == [
            .markdown("Between $10 and $20, use "),
            .math(latex: "x", isDisplayStyle: false),
            .markdown("."),
        ])
    }

    @Test
    func codeIsNeverMath() {
        #expect(MarkdownRenderer.inlineSegments(in: "Run `echo $PATH` with $n$ args.") == [
            .markdown("Run `echo $PATH` with "),
            .math(latex: "n", isDisplayStyle: false),
            .markdown(" args."),
        ])

        let blocks = MarkdownRenderer.blocks(for: "```\n$$ not math $$\n\\[ also not \\]\n```")
        #expect(describe(blocks) == ["code:$$ not math $$\n\\[ also not \\]"])
    }

    @Test
    func displayStyleMathInsideTextIsMarked() {
        #expect(MarkdownRenderer.inlineSegments(in: "Value is $$x^2 + 1$$ here.") == [
            .markdown("Value is "),
            .math(latex: "x^2 + 1", isDisplayStyle: true),
            .markdown(" here."),
        ])
    }

    @Test
    func preprocessLeavesNonMathBracketBlocksAlone() {
        let rawMarkdown = """
        Notes
        [
        just a note without math
        ]
        """
        let blockDescriptions = describe(MarkdownRenderer.blocks(for: rawMarkdown))
        #expect(blockDescriptions == ["paragraph:Notes [ just a note without math ]"])
    }

    @Test
    func readableMathFallbackConvertsCommonLatex() {
        let readableFormula = MarkdownRenderer.readableMath("6CO_2 + \\text{light} \\rightarrow C_6H_{12}O_6")

        #expect(readableFormula == "6CO₂ + light → C₆H₁₂O₆")
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

        #expect(describe(MarkdownRenderer.blocks(for: markdown)) == [
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

    private func describe(_ blocks: [MarkdownRenderer.Block]) -> [String] {
        blocks.map { block -> String in
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
            case .displayMath(let latex):
                return "math:\(latex)"
            case .horizontalRule:
                return "rule"
            }
        }
    }
}

struct MathTypesetterTests {
    @Test(arguments: [
        #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#,
        #"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#,
        #"\begin{align} x &= 1 \\ y &= 2 \end{align}"#,
        #"\begin{equation} E = mc^2 \end{equation}"#,
        #"\boxed{x = 2}"#,
        #"\underbrace{a + b}_{n}"#,
        #"a \xrightarrow{f} b"#,
        #"a\,b\:c\;d\!e"#,
        #"\ce{2H2 + O2 -> 2H2O}"#,
        #"\dots, \ldots, \cdots"#,
        #"E = mc^2 \tag{1}"#,
        #"\begin{array}{cc} a & b \\ c & d \end{array}"#,
        #"\overset{def}{=}"#,
        #"\underset{x}{\arg\min}"#,
        #"a \equiv b \pmod{m}"#,
        #"\left\lVert x \right\rVert"#,
        #"\begin{dcases} 1 & x > 0 \\ 0 & \text{otherwise} \end{dcases}"#,
    ])
    func commonModelLatexTypesets(latex: String) {
        let typesetFormula = MathTypesetter.typesetFormula(latex: latex, fontSize: 15, layoutStyle: .display)

        #expect(typesetFormula != nil, "SwiftMath could not typeset: \(latex)")
        #expect((typesetFormula?.size.width ?? 0) > 0)
        #expect(typesetFormula?.image.isTemplate == true)
    }

    @Test
    func compatibilityRewritesUnsupportedEnvironments() {
        #expect(MathTypesetter.swiftMathCompatibleLatex(#"\begin{align*} a &= b \end{align*}"#)
            == #"\begin{aligned} a &= b \end{aligned}"#)
        #expect(MathTypesetter.swiftMathCompatibleLatex(#"\begin{equation} x \end{equation}"#) == "x")
        #expect(MathTypesetter.swiftMathCompatibleLatex(#"x \label{eq:main}"#) == "x")
    }

    @Test
    func chemistryFormulasUseUprightElementsAndSubscripts() {
        #expect(MathTypesetter.chemistryLatex(fromMhchemFormula: "H2O") == #"\mathrm{H}_{2}\mathrm{O}"#)
        #expect(MathTypesetter.chemistryLatex(fromMhchemFormula: "SO4^2-") == #"\mathrm{SO}_{4}^{2-}"#)
    }

    @Test
    func inlineFormulasSitOnTheTextBaseline() {
        guard let typesetFormula = MathTypesetter.typesetFormula(
            latex: #"\frac{a}{b}"#,
            fontSize: 15,
            layoutStyle: .inline
        ) else {
            Issue.record("Expected a fraction to typeset.")
            return
        }

        // A fraction extends below the baseline, so the baseline sits above
        // the bottom edge but below the vertical middle of the image.
        #expect(typesetFormula.baselineOffsetFromBottom > 0)
        #expect(typesetFormula.baselineOffsetFromBottom < typesetFormula.size.height / 2)
    }

    @Test
    func unsupportedLatexReturnsNilForReadableFallback() {
        #expect(MathTypesetter.typesetFormula(latex: #"\definitelynotacommand{x}"#, fontSize: 15, layoutStyle: .inline) == nil)
    }
}
