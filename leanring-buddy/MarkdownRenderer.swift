import Foundation
import SwiftUI

/// Parses assistant response text into display-safe blocks and styled inline markdown.
/// SwiftUI `Text` does not reliably render Foundation's block-level markdown intents,
/// so headers, lists, and code blocks are represented explicitly by `MarkdownResponseView`.
///
/// LaTeX math is detected here and typeset by `MathTypesetter`. Display math
/// (`$$...$$`, `\[...\]`, bare `\begin{aligned}` environments) becomes its own
/// block; inline math (`$...$`, `\(...\)`) becomes an inline segment inside the
/// surrounding text. Fenced code, inline code, and dollar amounts are never
/// treated as math.
enum MarkdownRenderer {
    private static let bodyFontSize: CGFloat = 13
    private static let inlineCodeBackground = Color(red: 0.18, green: 0.22, blue: 0.30).opacity(0.55)

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedListItem(indentLevel: Int, text: String)
        case orderedListItem(indentLevel: Int, number: String, text: String)
        case codeBlock(String)
        case blockQuote(String)
        /// LaTeX source of a standalone formula, without its delimiters.
        case displayMath(String)
        case horizontalRule
    }

    /// A run of inline content inside a heading, paragraph, list item, or quote.
    enum InlineSegment: Equatable {
        case markdown(String)
        /// `isDisplayStyle` is true for `$$...$$` and `\[...\]` written inside a
        /// line of text; those formulas are laid out on their own row.
        case math(latex: String, isDisplayStyle: Bool)
    }

    /// LaTeX environments that are display math even without `$$` delimiters.
    private static let standaloneMathEnvironmentNames: Set<String> = [
        "align", "align*", "aligned", "alignat", "alignat*", "equation", "equation*",
        "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*",
        "cases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
        "array", "split", "displaymath",
    ]

    static func blocks(for rawMarkdown: String) -> [Block] {
        let displayMarkdown = normalizeDisplayMathFences(
            convertAlternativeDisplayMathDelimiters(
                normalizeLineEndings(rawMarkdown)
            )
        )
        let lines = displayMarkdown.components(separatedBy: "\n")

        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeBlockLines: [String] = []
        var isInsideCodeBlock = false
        var lineIndex = 0

        func appendParagraphIfNeeded() {
            guard !paragraphLines.isEmpty else { return }
            let paragraphText = paragraphLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            if isStandaloneUndelimitedFormula(paragraphText) {
                blocks.append(.displayMath(paragraphText))
            } else {
                blocks.append(.paragraph(paragraphText))
            }
            paragraphLines.removeAll()
        }

        func appendCodeBlockIfNeeded() {
            guard !codeBlockLines.isEmpty else { return }
            blocks.append(.codeBlock(codeBlockLines.joined(separator: "\n")))
            codeBlockLines.removeAll()
        }

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            lineIndex += 1

            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                appendParagraphIfNeeded()
                if isInsideCodeBlock {
                    appendCodeBlockIfNeeded()
                }
                isInsideCodeBlock.toggle()
                continue
            }

            if isInsideCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            if trimmedLine.isEmpty {
                appendParagraphIfNeeded()
                continue
            }

            // `$$` on its own line opens display math (fences were normalized
            // so the opener and closer always sit on separate lines).
            if trimmedLine == "$$" {
                var formulaLines: [String] = []
                var foundClosingFence = false
                var lookaheadIndex = lineIndex
                while lookaheadIndex < lines.count {
                    let formulaLine = lines[lookaheadIndex]
                    lookaheadIndex += 1
                    if formulaLine.trimmingCharacters(in: .whitespaces) == "$$" {
                        foundClosingFence = true
                        break
                    }
                    formulaLines.append(formulaLine)
                }

                if foundClosingFence {
                    appendParagraphIfNeeded()
                    let formula = formulaLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !formula.isEmpty {
                        blocks.append(.displayMath(formula))
                    }
                    lineIndex = lookaheadIndex
                } else {
                    // An unbalanced `$$` must not swallow the rest of the
                    // response: it is shown as text and parsing continues
                    // normally with the next line.
                    paragraphLines.append(line)
                }
                continue
            }

            if let environmentName = standaloneMathEnvironmentName(openedBy: trimmedLine) {
                let environmentEndMarker = "\\end{\(environmentName)}"
                var formulaLines = [line]
                var foundEnvironmentEnd = trimmedLine.contains(environmentEndMarker)
                var lookaheadIndex = lineIndex
                while !foundEnvironmentEnd && lookaheadIndex < lines.count {
                    formulaLines.append(lines[lookaheadIndex])
                    foundEnvironmentEnd = lines[lookaheadIndex].contains(environmentEndMarker)
                    lookaheadIndex += 1
                }

                if foundEnvironmentEnd {
                    appendParagraphIfNeeded()
                    blocks.append(.displayMath(
                        formulaLines.joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    lineIndex = lookaheadIndex
                    continue
                }
            }

            if let heading = heading(in: line) {
                appendParagraphIfNeeded()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if isHorizontalRule(trimmedLine) {
                appendParagraphIfNeeded()
                blocks.append(.horizontalRule)
                continue
            }

            if let listItem = listItem(in: line) {
                appendParagraphIfNeeded()
                switch listItem.style {
                case .unordered:
                    blocks.append(
                        .unorderedListItem(
                            indentLevel: listItem.indentLevel,
                            text: listItem.text
                        )
                    )
                case .ordered(let number):
                    blocks.append(
                        .orderedListItem(
                            indentLevel: listItem.indentLevel,
                            number: number,
                            text: listItem.text
                        )
                    )
                }
                continue
            }

            if trimmedLine.hasPrefix(">") {
                appendParagraphIfNeeded()
                let quoteText = trimmedLine
                    .dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.blockQuote(String(quoteText)))
                continue
            }

            paragraphLines.append(line)
        }

        appendParagraphIfNeeded()
        appendCodeBlockIfNeeded()
        return blocks
    }

    static func renderInline(_ rawMarkdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        // Delimited math is typeset separately; this only makes stray LaTeX
        // commands written outside delimiters (e.g. "\alpha") readable.
        let readableMarkdown = convertUndelimitedLatexOutsideInlineCode(rawMarkdown)

        do {
            var attributedString = try AttributedString(
                markdown: readableMarkdown,
                options: options
            )
            styleInlineCode(in: &attributedString)
            return attributedString
        } catch {
            return AttributedString(readableMarkdown)
        }
    }

    // MARK: - Inline Math Segmentation

    /// Splits text into Markdown runs and LaTeX math spans.
    ///
    /// Inline math follows Pandoc's dollar rules so prices are left alone: the
    /// opening `$` must be followed by a non-space character, and the closing
    /// `$` must follow a non-space character and must not be followed by a
    /// digit. "It costs $5 and $6" therefore stays plain text. Inline code
    /// spans are copied verbatim, and escaped `\$` stays a literal dollar sign.
    static func inlineSegments(in markdownText: String) -> [InlineSegment] {
        let characters = Array(markdownText)
        var segments: [InlineSegment] = []
        var pendingMarkdown = ""
        var characterIndex = 0

        func appendPendingMarkdownIfNeeded() {
            guard !pendingMarkdown.isEmpty else { return }
            segments.append(.markdown(pendingMarkdown))
            pendingMarkdown = ""
        }

        func appendMath(_ latex: String, isDisplayStyle: Bool) {
            appendPendingMarkdownIfNeeded()
            segments.append(.math(
                latex: latex.trimmingCharacters(in: .whitespacesAndNewlines),
                isDisplayStyle: isDisplayStyle
            ))
        }

        while characterIndex < characters.count {
            let character = characters[characterIndex]

            if character == "`" {
                let backtickRunLength = lengthOfRepeatedCharacter("`", in: characters, startingAt: characterIndex)
                let codeContentStartIndex = characterIndex + backtickRunLength
                if let closingRunIndex = indexOfBacktickRun(
                    length: backtickRunLength,
                    in: characters,
                    startingAt: codeContentStartIndex
                ) {
                    let codeSpanEndIndex = closingRunIndex + backtickRunLength
                    pendingMarkdown += String(characters[characterIndex..<codeSpanEndIndex])
                    characterIndex = codeSpanEndIndex
                } else {
                    pendingMarkdown += String(repeating: "`", count: backtickRunLength)
                    characterIndex = codeContentStartIndex
                }
                continue
            }

            if character == "\\", characterIndex + 1 < characters.count {
                let escapedCharacter = characters[characterIndex + 1]
                if escapedCharacter == "(" || escapedCharacter == "[" {
                    let closingDelimiter: [Character] = escapedCharacter == "(" ? ["\\", ")"] : ["\\", "]"]
                    if let closingDelimiterIndex = indexOfSequence(
                        closingDelimiter,
                        in: characters,
                        startingAt: characterIndex + 2
                    ) {
                        let latex = String(characters[(characterIndex + 2)..<closingDelimiterIndex])
                        if !latex.trimmingCharacters(in: .whitespaces).isEmpty {
                            appendMath(latex, isDisplayStyle: escapedCharacter == "[")
                            characterIndex = closingDelimiterIndex + 2
                            continue
                        }
                    }
                }

                // Other escapes (including `\$`) are left for the Markdown parser.
                pendingMarkdown.append(character)
                pendingMarkdown.append(escapedCharacter)
                characterIndex += 2
                continue
            }

            if character == "$" {
                let isDoubleDollar = characterIndex + 1 < characters.count
                    && characters[characterIndex + 1] == "$"

                if isDoubleDollar {
                    if let closingFenceIndex = indexOfSequence(
                        ["$", "$"],
                        in: characters,
                        startingAt: characterIndex + 2
                    ) {
                        let latex = String(characters[(characterIndex + 2)..<closingFenceIndex])
                        if !latex.trimmingCharacters(in: .whitespaces).isEmpty {
                            appendMath(latex, isDisplayStyle: true)
                            characterIndex = closingFenceIndex + 2
                            continue
                        }
                    }
                    pendingMarkdown += "$$"
                    characterIndex += 2
                    continue
                }

                if let closingDollarIndex = closingInlineDollarIndex(
                    in: characters,
                    openingDollarIndex: characterIndex
                ) {
                    appendMath(
                        String(characters[(characterIndex + 1)..<closingDollarIndex]),
                        isDisplayStyle: false
                    )
                    characterIndex = closingDollarIndex + 1
                    continue
                }

                pendingMarkdown.append("$")
                characterIndex += 1
                continue
            }

            pendingMarkdown.append(character)
            characterIndex += 1
        }

        appendPendingMarkdownIfNeeded()
        return segments
    }

    private static func closingInlineDollarIndex(
        in characters: [Character],
        openingDollarIndex: Int
    ) -> Int? {
        let contentStartIndex = openingDollarIndex + 1
        guard contentStartIndex < characters.count,
              !characters[contentStartIndex].isWhitespace
        else {
            return nil
        }

        var scanIndex = contentStartIndex
        while scanIndex < characters.count {
            let character = characters[scanIndex]
            if character == "\\" {
                // `\$` inside math is an escaped dollar, not a closer.
                scanIndex += 2
                continue
            }
            if character == "$" {
                let precedingCharacter = characters[scanIndex - 1]
                let followingCharacter: Character? = scanIndex + 1 < characters.count
                    ? characters[scanIndex + 1]
                    : nil
                let isValidClosingDollar = scanIndex > contentStartIndex
                    && !precedingCharacter.isWhitespace
                    && followingCharacter?.isNumber != true
                // The next dollar either closes the formula or, as in
                // "$5 and $6", shows the opener was a price.
                return isValidClosingDollar ? scanIndex : nil
            }
            scanIndex += 1
        }
        return nil
    }

    private static func lengthOfRepeatedCharacter(
        _ repeatedCharacter: Character,
        in characters: [Character],
        startingAt startIndex: Int
    ) -> Int {
        var runLength = 0
        while startIndex + runLength < characters.count,
              characters[startIndex + runLength] == repeatedCharacter {
            runLength += 1
        }
        return runLength
    }

    private static func indexOfBacktickRun(
        length requiredRunLength: Int,
        in characters: [Character],
        startingAt startIndex: Int
    ) -> Int? {
        var scanIndex = startIndex
        while scanIndex < characters.count {
            if characters[scanIndex] == "`" {
                let runLength = lengthOfRepeatedCharacter("`", in: characters, startingAt: scanIndex)
                if runLength == requiredRunLength {
                    return scanIndex
                }
                scanIndex += runLength
            } else {
                scanIndex += 1
            }
        }
        return nil
    }

    private static func indexOfSequence(
        _ sequence: [Character],
        in characters: [Character],
        startingAt startIndex: Int
    ) -> Int? {
        guard !sequence.isEmpty, startIndex <= characters.count - sequence.count else { return nil }
        for candidateIndex in startIndex...(characters.count - sequence.count) {
            if Array(characters[candidateIndex..<(candidateIndex + sequence.count)]) == sequence {
                return candidateIndex
            }
        }
        return nil
    }

    // MARK: - Display Math Normalization

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Rewrites `\[...\]` and bracket-wrapped formulas into `$$` fences so the
    /// block parser only has one display math syntax to recognize. Fenced code
    /// is left untouched.
    private static func convertAlternativeDisplayMathDelimiters(_ text: String) -> String {
        mapOutsideFencedCode(in: text) { proseText in
            var convertedText = replaceMatches(
                in: proseText,
                pattern: #"\\\[([\s\S]+?)\\\]"#
            ) { match in
                "\n$$\n\(match[1].trimmingCharacters(in: .whitespacesAndNewlines))\n$$\n"
            }

            // Models sometimes drop the backslashes and wrap formulas in bare
            // brackets on their own lines.
            convertedText = replaceMatches(
                in: convertedText,
                pattern: #"(?m)^[ \t]*\[[ \t]*\n([\s\S]*?)\n[ \t]*\][ \t]*$"#
            ) { match in
                let innerText = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard looksLikeMath(innerText) else { return match[0] }
                return "$$\n\(innerText)\n$$"
            }
            convertedText = replaceMatches(
                in: convertedText,
                pattern: #"(?m)^[ \t]*\[[ \t]+([^\[\]\n]+?)[ \t]+\][ \t]*$"#
            ) { match in
                let innerText = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard innerText.contains("\\"), looksLikeMath(innerText) else { return match[0] }
                return "$$\n\(innerText)\n$$"
            }
            return convertedText
        }
    }

    /// Models often glue content onto `$$` fence lines ("$$\begin{aligned}" or
    /// "\end{aligned}$$ [2]"). Moving every `$$` fence onto its own line lets
    /// the block parser find clean display math blocks instead of letting an
    /// unmatched fence swallow the rest of the response.
    private static func normalizeDisplayMathFences(_ text: String) -> String {
        var normalizedLines: [String] = []
        var isInsideCodeBlock = false
        var isInsideDisplayMath = false

        func appendIfNotBlank(_ lineFragment: Substring) {
            let trimmedFragment = lineFragment.trimmingCharacters(in: .whitespaces)
            if !trimmedFragment.isEmpty {
                normalizedLines.append(trimmedFragment)
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                isInsideCodeBlock.toggle()
                normalizedLines.append(line)
                continue
            }

            if isInsideCodeBlock {
                normalizedLines.append(line)
                continue
            }

            if isInsideDisplayMath {
                if let closingFenceRange = trimmedLine.range(of: "$$") {
                    appendIfNotBlank(trimmedLine[..<closingFenceRange.lowerBound])
                    normalizedLines.append("$$")
                    appendIfNotBlank(trimmedLine[closingFenceRange.upperBound...])
                    isInsideDisplayMath = false
                } else {
                    normalizedLines.append(line)
                }
                continue
            }

            if trimmedLine.hasPrefix("$$") {
                let textAfterOpeningFence = trimmedLine.dropFirst(2)
                if let closingFenceRange = textAfterOpeningFence.range(of: "$$") {
                    let formula = textAfterOpeningFence[..<closingFenceRange.lowerBound]
                    if formula.trimmingCharacters(in: .whitespaces).isEmpty {
                        normalizedLines.append(line)
                    } else {
                        normalizedLines.append("$$")
                        appendIfNotBlank(formula)
                        normalizedLines.append("$$")
                        appendIfNotBlank(textAfterOpeningFence[closingFenceRange.upperBound...])
                    }
                } else {
                    normalizedLines.append("$$")
                    appendIfNotBlank(textAfterOpeningFence)
                    isInsideDisplayMath = true
                }
                continue
            }

            // "We get: $$" opens a display block at the end of a text line.
            if trimmedLine.hasSuffix("$$"),
               trimmedLine.components(separatedBy: "$$").count == 2 {
                appendIfNotBlank(trimmedLine.dropLast(2))
                normalizedLines.append("$$")
                isInsideDisplayMath = true
                continue
            }

            normalizedLines.append(line)
        }

        return normalizedLines.joined(separator: "\n")
    }

    private static func standaloneMathEnvironmentName(openedBy trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\\begin{"),
              let closingBraceIndex = trimmedLine.firstIndex(of: "}")
        else {
            return nil
        }
        let environmentNameStartIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: "\\begin{".count)
        let environmentName = String(trimmedLine[environmentNameStartIndex..<closingBraceIndex])
        return standaloneMathEnvironmentNames.contains(environmentName) ? environmentName : nil
    }

    /// Detects a paragraph that is a bare LaTeX formula without delimiters,
    /// such as "E = \frac{1}{2} m v^2". It must use structural LaTeX and must
    /// not contain prose words, so sentences that merely mention a symbol
    /// stay as text.
    private static func isStandaloneUndelimitedFormula(_ paragraphText: String) -> Bool {
        guard !paragraphText.contains("$"), !paragraphText.contains("`") else { return false }

        let structuralLatexPattern = #"\\(frac|dfrac|tfrac|sqrt|sum|prod|int|iint|oint|lim|binom|vec|hat|overline|mathbb|mathcal|partial|nabla)(?![A-Za-z])|[\^_]\{"#
        guard paragraphText.range(of: structuralLatexPattern, options: .regularExpression) != nil else {
            return false
        }

        var textWithoutLatex = replaceMatches(
            in: paragraphText,
            pattern: #"\\(text|mathrm|operatorname|mathbf|mathit)\{[^{}]*\}"#
        ) { _ in " " }
        textWithoutLatex = textWithoutLatex.replacingOccurrences(
            of: #"\\[A-Za-z]+"#,
            with: " ",
            options: .regularExpression
        )
        return textWithoutLatex.range(of: "[A-Za-z]{4,}", options: .regularExpression) == nil
    }

    private static func mapOutsideFencedCode(
        in text: String,
        transform: (String) -> String
    ) -> String {
        var transformedText = ""
        var proseLines: [String] = []
        var isInsideCodeBlock = false

        func appendTransformedProseIfNeeded() {
            guard !proseLines.isEmpty else { return }
            transformedText += transform(proseLines.joined(separator: "\n")) + "\n"
            proseLines.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isCodeFenceLine = trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")

            if isCodeFenceLine && !isInsideCodeBlock {
                appendTransformedProseIfNeeded()
                isInsideCodeBlock = true
                transformedText += line + "\n"
            } else if isCodeFenceLine && isInsideCodeBlock {
                isInsideCodeBlock = false
                transformedText += line + "\n"
            } else if isInsideCodeBlock {
                transformedText += line + "\n"
            } else {
                proseLines.append(line)
            }
        }
        appendTransformedProseIfNeeded()

        if transformedText.hasSuffix("\n") {
            transformedText.removeLast()
        }
        return transformedText
    }

    // MARK: - Block Helpers

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        let headingCharacters = trimmedLine.prefix { $0 == "#" }
        let headingLevel = headingCharacters.count
        guard (1...6).contains(headingLevel) else { return nil }

        let remainingText = trimmedLine.dropFirst(headingLevel)
        guard remainingText.first?.isWhitespace == true else { return nil }

        let title = remainingText
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (headingLevel, title)
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        let ruleCharacter = trimmedLine.first
        guard let ruleCharacter,
              ruleCharacter == "-" || ruleCharacter == "*" || ruleCharacter == "_"
        else {
            return false
        }

        return trimmedLine.count >= 3 && trimmedLine.allSatisfy { $0 == ruleCharacter }
    }

    private enum ListStyle {
        case unordered
        case ordered(number: String)
    }

    private static func listItem(
        in line: String
    ) -> (indentLevel: Int, style: ListStyle, text: String)? {
        let leadingWhitespaceCount = line.prefix { $0 == " " || $0 == "\t" }.count
        let indentationLevel = leadingWhitespaceCount / 2
        let content = line.dropFirst(leadingWhitespaceCount)

        if let firstCharacter = content.first,
           (firstCharacter == "-" || firstCharacter == "*" || firstCharacter == "+"),
           content.dropFirst().first?.isWhitespace == true {
            return (
                indentationLevel,
                .unordered,
                String(content.dropFirst().trimmingCharacters(in: .whitespaces))
            )
        }

        let numberCharacters = content.prefix { $0.isNumber }
        guard !numberCharacters.isEmpty,
              let delimiter = content.dropFirst(numberCharacters.count).first,
              delimiter == "." || delimiter == ")",
              content.dropFirst(numberCharacters.count + 1).first?.isWhitespace == true
        else {
            return nil
        }

        return (
            indentationLevel,
            .ordered(number: String(numberCharacters)),
            String(
                content
                    .dropFirst(numberCharacters.count + 1)
                    .trimmingCharacters(in: .whitespaces)
            )
        )
    }

    // MARK: - Readable Unicode Fallback

    /// Converts LaTeX into readable Unicode text. Used when SwiftMath cannot
    /// typeset a formula, so the user still sees "x² + √(y)" rather than raw
    /// LaTeX source.
    static func readableMath(_ text: String) -> String {
        let withoutCommands = convertLatexCommands(text)
        let withScripts = convertScriptNotation(withoutCommands)
        return withScripts
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies the Unicode fallback to LaTeX written outside math delimiters,
    /// skipping inline code spans so code samples are shown exactly.
    private static func convertUndelimitedLatexOutsideInlineCode(_ markdownText: String) -> String {
        let codeSpanSeparatedParts = markdownText.components(separatedBy: "`")
        guard codeSpanSeparatedParts.count > 1 else {
            return convertScriptNotation(convertLatexCommands(markdownText))
        }

        // Even-numbered parts sit outside backtick pairs.
        return codeSpanSeparatedParts.enumerated().map { partIndex, part in
            partIndex.isMultiple(of: 2)
                ? convertScriptNotation(convertLatexCommands(part))
                : part
        }
        .joined(separator: "`")
    }

    private static func looksLikeMath(_ text: String) -> Bool {
        if text.contains("\\") {
            return true
        }
        if text.range(of: #"[_^]\{"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"[A-Za-z0-9]_\d"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"[A-Za-z0-9]\^\d"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func convertLatexCommands(_ text: String) -> String {
        var result = text

        // Unwrap text-mode wrappers first so their contents stay readable.
        for commandName in ["text", "mathrm", "mathbf", "mathit", "operatorname", "textbf", "textit"] {
            let pattern = "\\\\" + commandName + "\\{([^{}]*)\\}"
            result = replaceMatches(in: result, pattern: pattern) { match in
                String(match[1])
            }
        }

        let symbolReplacements: [(String, String)] = [
            (#"\\rightarrow"#, "→"),
            (#"\\longrightarrow"#, "→"),
            (#"\\to\b"#, "→"),
            (#"\\leftarrow"#, "←"),
            (#"\\longleftarrow"#, "←"),
            (#"\\leftrightarrow"#, "↔"),
            (#"\\Rightarrow"#, "⇒"),
            (#"\\Leftarrow"#, "⇐"),
            (#"\\Leftrightarrow"#, "⇔"),
            (#"\\times"#, "×"),
            (#"\\cdot"#, "·"),
            (#"\\pm"#, "±"),
            (#"\\mp"#, "∓"),
            (#"\\approx"#, "≈"),
            (#"\\neq"#, "≠"),
            (#"\\ne\b"#, "≠"),
            (#"\\leq"#, "≤"),
            (#"\\le\b"#, "≤"),
            (#"\\geq"#, "≥"),
            (#"\\ge\b"#, "≥"),
            (#"\\infty"#, "∞"),
            (#"\\degree"#, "°"),
            (#"\\circ"#, "°"),
            (#"\\ldots"#, "…"),
            (#"\\cdots"#, "⋯"),
            (#"\\partial"#, "∂"),
            (#"\\nabla"#, "∇"),
            (#"\\sum"#, "∑"),
            (#"\\prod"#, "∏"),
            (#"\\int"#, "∫"),
            (#"\\sqrt"#, "√"),
            (#"\\alpha"#, "α"),
            (#"\\beta"#, "β"),
            (#"\\gamma"#, "γ"),
            (#"\\delta"#, "δ"),
            (#"\\epsilon"#, "ε"),
            (#"\\theta"#, "θ"),
            (#"\\lambda"#, "λ"),
            (#"\\mu"#, "μ"),
            (#"\\pi"#, "π"),
            (#"\\sigma"#, "σ"),
            (#"\\phi"#, "φ"),
            (#"\\omega"#, "ω"),
            (#"\\Delta"#, "Δ"),
            (#"\\Omega"#, "Ω"),
            (#"\\%"#, "%"),
            (#"\\&"#, "&"),
            (#"\\_"#, "_"),
            (#"\\\{"#, "{"),
            (#"\\\}"#, "}")
        ]

        for (pattern, replacement) in symbolReplacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        // \frac{a}{b} → (a)/(b)
        result = replaceMatches(
            in: result,
            pattern: #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#
        ) { match in
            "(\(match[1]))/(\(match[2]))"
        }

        // Handle `\sqrt{x}` after the bare `\sqrt` → `√` replacement.
        result = replaceMatches(
            in: result,
            pattern: #"√\{([^{}]+)\}"#
        ) { match in
            "√(\(match[1]))"
        }

        return result
    }

    /// Converts `_{12}`, `^{2}`, and chemistry-style `_2` into Unicode scripts
    /// so markdown does not treat underscores as emphasis.
    private static func convertScriptNotation(_ text: String) -> String {
        var result = text

        result = replaceMatches(
            in: result,
            pattern: #"_\{([^{}]+)\}"#
        ) { match in
            toUnicodeSubscript(String(match[1]))
        }
        result = replaceMatches(
            in: result,
            pattern: #"\^\{([^{}]+)\}"#
        ) { match in
            toUnicodeSuperscript(String(match[1]))
        }
        // Chemistry-style single-token subscripts/superscripts: CO_2, x^2
        result = replaceMatches(
            in: result,
            pattern: #"(?<=[A-Za-z0-9\)\]])\_(\d+)"#
        ) { match in
            toUnicodeSubscript(String(match[1]))
        }
        result = replaceMatches(
            in: result,
            pattern: #"(?<=[A-Za-z0-9\)\]])\^(\d+)"#
        ) { match in
            toUnicodeSuperscript(String(match[1]))
        }

        return result
    }

    private static func toUnicodeSubscript(_ text: String) -> String {
        let map: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
            "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
            "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
            "v": "ᵥ", "x": "ₓ"
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    private static func toUnicodeSuperscript(_ text: String) -> String {
        let map: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "n": "ⁿ", "i": "ⁱ"
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regularExpression = try? NSRegularExpression(
            pattern: pattern,
            options: []
        ) else {
            return text
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regularExpression.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            var captureGroups: [String] = [String(result[matchRange])]
            for captureIndex in 1..<match.numberOfRanges {
                if let captureRange = Range(match.range(at: captureIndex), in: result) {
                    captureGroups.append(String(result[captureRange]))
                } else {
                    captureGroups.append("")
                }
            }
            result.replaceSubrange(matchRange, with: transform(captureGroups))
        }
        return result
    }

    private static func styleInlineCode(in attributedString: inout AttributedString) {
        for run in attributedString.runs {
            let range = run.range
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributedString[range].font = .system(size: bodyFontSize - 1, design: .monospaced)
                attributedString[range].foregroundColor = DS.Colors.codeText
                attributedString[range].backgroundColor = inlineCodeBackground
            }
        }
    }
}
