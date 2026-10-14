import SwiftUI

/// Renders completed assistant responses as visible markdown blocks.
/// This avoids relying on SwiftUI `Text` to interpret Foundation's block intents,
/// which can collapse headers and list markers into a single run of text.
/// LaTeX math is typeset with `MathTypesetter`: inline formulas flow inside the
/// text on its baseline, and display formulas get their own centered row.
struct MarkdownResponseView: View {
    let markdown: String
    var primaryTextColor: Color = DS.Colors.textPrimary
    var secondaryTextColor: Color = DS.Colors.textSecondary
    var codeTextColor: Color = DS.Colors.codeText

    private static let bodyFontSize: CGFloat = 13

    private var blocks: [MarkdownRenderer.Block] {
        MarkdownRenderer.blocks(for: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(for block: MarkdownRenderer.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMathTextView(
                markdownText: text,
                textFontSize: headingFontSize(for: level),
                fallbackFormulaColor: codeTextColor
            )
                .font(headingFont(for: level))
                .foregroundColor(primaryTextColor)
                .padding(.top, level <= 2 ? 4 : 1)

        case .paragraph(let text):
            InlineMathTextView(
                markdownText: text,
                textFontSize: Self.bodyFontSize,
                fallbackFormulaColor: codeTextColor
            )
                .font(.system(size: Self.bodyFontSize))
                .foregroundColor(primaryTextColor)

        case .unorderedListItem(let indentLevel, let text):
            listItem(
                marker: "•",
                text: text,
                indentLevel: indentLevel
            )

        case .orderedListItem(let indentLevel, let number, let text):
            listItem(
                marker: "\(number).",
                text: text,
                indentLevel: indentLevel
            )

        case .codeBlock(let code):
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(codeTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface3)
                )

        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.Colors.accent.opacity(0.7))
                    .frame(width: 3)
                InlineMathTextView(
                    markdownText: text,
                    textFontSize: Self.bodyFontSize,
                    fallbackFormulaColor: codeTextColor
                )
                    .font(.system(size: Self.bodyFontSize))
                    .italic()
                    .foregroundColor(secondaryTextColor)
            }

        case .displayMath(let latex):
            DisplayMathView(
                latex: latex,
                formulaColor: primaryTextColor,
                fallbackFormulaColor: codeTextColor
            )

        case .horizontalRule:
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func listItem(
        marker: String,
        text: String,
        indentLevel: Int
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: Self.bodyFontSize, weight: .semibold))
                .foregroundColor(secondaryTextColor)
                .frame(minWidth: marker.count > 1 ? 18 : 10, alignment: .trailing)

            InlineMathTextView(
                markdownText: text,
                textFontSize: Self.bodyFontSize,
                fallbackFormulaColor: codeTextColor
            )
                .font(.system(size: Self.bodyFontSize))
                .foregroundColor(primaryTextColor)
        }
        .padding(.leading, CGFloat(indentLevel) * 14)
    }

    private func headingFontSize(for level: Int) -> CGFloat {
        switch level {
        case 1:
            return 18
        case 2:
            return 16
        case 3:
            return 14
        default:
            return Self.bodyFontSize
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: headingFontSize(for: level), weight: .bold)
        case 2:
            return .system(size: headingFontSize(for: level), weight: .bold)
        default:
            return .system(size: headingFontSize(for: level), weight: .semibold)
        }
    }
}

// MARK: - Inline Math

/// Text that may contain inline LaTeX. Formulas are typeset into template
/// images and joined into a single `Text` so they wrap with the words around
/// them and pick up the surrounding font color. Formulas too wide to sit in a
/// line (or written as display math mid-sentence) break out onto their own row.
private struct InlineMathTextView: View {
    let markdownText: String
    let textFontSize: CGFloat
    let fallbackFormulaColor: Color

    /// Latin Modern Math has a smaller x-height than the system font, so math
    /// is set slightly larger to match the visual size of the prose.
    private var inlineMathFontSize: CGFloat { (textFontSize * 1.12).rounded() }

    /// Inline formulas wider than this move to their own row, because a single
    /// image cannot wrap and would otherwise overflow narrow speech bubbles.
    private static let maximumInlineFormulaWidth: CGFloat = 240

    private enum ContentRow {
        case textLine(Text)
        case standaloneFormula(latex: String)
    }

    var body: some View {
        let segments = MarkdownRenderer.inlineSegments(in: markdownText)
        let containsMath = segments.contains { segment in
            if case .math = segment { return true }
            return false
        }

        if !containsMath {
            Text(MarkdownRenderer.renderInline(markdownText))
        } else {
            let contentRows = composedContentRows(for: segments)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(contentRows.enumerated()), id: \.offset) { _, contentRow in
                    switch contentRow {
                    case .textLine(let textLine):
                        textLine
                    case .standaloneFormula(let latex):
                        DisplayMathView(
                            latex: latex,
                            formulaColor: nil,
                            fallbackFormulaColor: fallbackFormulaColor
                        )
                    }
                }
            }
        }
    }

    /// Builds the rows by parsing the whole line as Markdown with a private-use
    /// placeholder character standing in for each formula. Parsing everything
    /// at once keeps emphasis that spans a formula ("**the value $x$ is**")
    /// intact; the placeholders are then swapped for formula images.
    private func composedContentRows(for segments: [MarkdownRenderer.InlineSegment]) -> [ContentRow] {
        var markdownWithPlaceholders = ""
        var inlineFormulasByPlaceholder: [Character: TypesetMathFormula] = [:]
        var standaloneFormulasByPlaceholder: [Character: String] = [:]
        var nextPlaceholderScalarValue: UInt32 = 0xE000

        for segment in segments {
            switch segment {
            case .markdown(let markdownRun):
                markdownWithPlaceholders += markdownRun

            case .math(let latex, let isDisplayStyle):
                guard let placeholderScalar = Unicode.Scalar(nextPlaceholderScalarValue) else { continue }
                let placeholderCharacter = Character(placeholderScalar)
                nextPlaceholderScalarValue += 1

                if isDisplayStyle {
                    standaloneFormulasByPlaceholder[placeholderCharacter] = latex
                    markdownWithPlaceholders.append(placeholderCharacter)
                } else if let typesetFormula = MathTypesetter.typesetFormula(
                    latex: latex,
                    fontSize: inlineMathFontSize,
                    layoutStyle: .inline
                ) {
                    if typesetFormula.size.width > Self.maximumInlineFormulaWidth {
                        standaloneFormulasByPlaceholder[placeholderCharacter] = latex
                    } else {
                        inlineFormulasByPlaceholder[placeholderCharacter] = typesetFormula
                    }
                    markdownWithPlaceholders.append(placeholderCharacter)
                } else {
                    // Formulas SwiftMath cannot lay out are shown as readable
                    // Unicode in code styling rather than as raw LaTeX.
                    let readableFormula = MarkdownRenderer.readableMath(latex)
                        .replacingOccurrences(of: "`", with: "'")
                    markdownWithPlaceholders += "`\(readableFormula)`"
                }
            }
        }

        let attributedText = MarkdownRenderer.renderInline(markdownWithPlaceholders)
        var contentRows: [ContentRow] = []
        var currentTextLine: Text?
        var textSliceStartIndex = attributedText.startIndex
        var characterIndex = attributedText.startIndex

        func appendToCurrentTextLine(_ textPiece: Text) {
            if let existingTextLine = currentTextLine {
                currentTextLine = Text("\(existingTextLine)\(textPiece)")
            } else {
                currentTextLine = textPiece
            }
        }

        func appendTextSlice(upTo sliceEndIndex: AttributedString.Index) {
            guard textSliceStartIndex < sliceEndIndex else { return }
            appendToCurrentTextLine(Text(AttributedString(attributedText[textSliceStartIndex..<sliceEndIndex])))
        }

        func finishCurrentTextLine() {
            if let completedTextLine = currentTextLine {
                contentRows.append(.textLine(completedTextLine))
            }
            currentTextLine = nil
        }

        while characterIndex < attributedText.endIndex {
            let character = attributedText.characters[characterIndex]
            let nextCharacterIndex = attributedText.characters.index(after: characterIndex)

            if let inlineFormula = inlineFormulasByPlaceholder[character] {
                appendTextSlice(upTo: characterIndex)
                appendToCurrentTextLine(inlineFormulaText(for: inlineFormula))
                textSliceStartIndex = nextCharacterIndex
            } else if let standaloneLatex = standaloneFormulasByPlaceholder[character] {
                appendTextSlice(upTo: characterIndex)
                finishCurrentTextLine()
                contentRows.append(.standaloneFormula(latex: standaloneLatex))

                // Text after a standalone formula starts a fresh row, so its
                // leading spaces would only indent it.
                var resumedTextStartIndex = nextCharacterIndex
                while resumedTextStartIndex < attributedText.endIndex,
                      attributedText.characters[resumedTextStartIndex].isWhitespace {
                    resumedTextStartIndex = attributedText.characters.index(after: resumedTextStartIndex)
                }
                textSliceStartIndex = resumedTextStartIndex
            }

            characterIndex = nextCharacterIndex
        }

        appendTextSlice(upTo: attributedText.endIndex)
        finishCurrentTextLine()
        return contentRows
    }

    /// A formula image inside `Text`, shifted down so the math baseline sits
    /// on the text baseline. Template rendering tints it with the text color.
    private func inlineFormulaText(for typesetFormula: TypesetMathFormula) -> Text {
        Text(Image(nsImage: typesetFormula.image).renderingMode(.template))
            .baselineOffset(-typesetFormula.baselineOffsetFromBottom)
    }
}

// MARK: - Display Math

/// A standalone formula, centered like LaTeX display math. Formulas wider
/// than the available space scroll horizontally instead of being clipped.
private struct DisplayMathView: View {
    let latex: String
    /// Nil inherits the surrounding foreground color.
    let formulaColor: Color?
    let fallbackFormulaColor: Color

    private static let displayMathFontSize: CGFloat = 15

    var body: some View {
        if let typesetFormula = MathTypesetter.typesetFormula(
            latex: latex,
            fontSize: Self.displayMathFontSize,
            layoutStyle: .display
        ) {
            ViewThatFits(in: .horizontal) {
                formulaImage(typesetFormula)
                    .frame(maxWidth: .infinity, alignment: .center)

                ScrollView(.horizontal, showsIndicators: false) {
                    formulaImage(typesetFormula)
                        .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement()
            .accessibilityLabel(latex)
        } else {
            Text(MarkdownRenderer.readableMath(latex))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(fallbackFormulaColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface3)
                )
        }
    }

    @ViewBuilder
    private func formulaImage(_ typesetFormula: TypesetMathFormula) -> some View {
        let templateImage = Image(nsImage: typesetFormula.image)
            .renderingMode(.template)

        if let formulaColor {
            templateImage.foregroundColor(formulaColor)
        } else {
            templateImage
        }
    }
}
