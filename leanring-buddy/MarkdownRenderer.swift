import Foundation
import SwiftUI

/// Parses assistant response text into display-safe blocks and styled inline markdown.
/// SwiftUI `Text` does not reliably render Foundation's block-level markdown intents,
/// so headers, lists, and code blocks are represented explicitly by `MarkdownResponseView`.
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
        case horizontalRule
    }

    static func blocks(for rawMarkdown: String) -> [Block] {
        let displayMarkdown = preprocessForDisplay(rawMarkdown)
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeBlockLines: [String] = []
        var isInsideCodeBlock = false

        func appendParagraphIfNeeded() {
            guard !paragraphLines.isEmpty else { return }
            let paragraphText = paragraphLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            blocks.append(.paragraph(paragraphText))
            paragraphLines.removeAll()
        }

        func appendCodeBlockIfNeeded() {
            guard !codeBlockLines.isEmpty else { return }
            blocks.append(.codeBlock(codeBlockLines.joined(separator: "\n")))
            codeBlockLines.removeAll()
        }

        for line in displayMarkdown.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") {
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

        do {
            var attributedString = try AttributedString(
                markdown: rawMarkdown,
                options: options
            )
            styleInlineCode(in: &attributedString)
            return attributedString
        } catch {
            return AttributedString(rawMarkdown)
        }
    }

    /// Converts model output into markdown that Foundation can parse reliably,
    /// including common LaTeX-ish math into readable Unicode.
    static func preprocessForDisplay(_ rawMarkdown: String) -> String {
        var text = rawMarkdown
        text = normalizeLineEndings(text)
        text = convertFencedMathBlocks(text)
        text = convertInlineMathDelimiters(text)
        text = convertBracketWrappedMathBlocks(text)
        text = convertLatexCommands(text)
        text = convertScriptNotation(text)
        return text
    }

    // MARK: - Preprocessing

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

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

    /// Turns `$$...$$` and `\[...\]` display math into readable inline-code lines.
    private static func convertFencedMathBlocks(_ text: String) -> String {
        var result = text
        result = replaceMatches(
            in: result,
            pattern: #"\$\$([\s\S]+?)\$\$"#
        ) { match in
            let formula = readableMath(String(match[1]))
            return "\n\n`\(formula)`\n\n"
        }
        result = replaceMatches(
            in: result,
            pattern: #"\\\[([\s\S]+?)\\\]"#
        ) { match in
            let formula = readableMath(String(match[1]))
            return "\n\n`\(formula)`\n\n"
        }
        return result
    }

    /// Turns `$...$` and `\(...\)` inline math into readable text (no dollar signs).
    private static func convertInlineMathDelimiters(_ text: String) -> String {
        var result = text
        result = replaceMatches(
            in: result,
            pattern: #"\\\((.+?)\\\)"#
        ) { match in
            readableMath(String(match[1]))
        }
        // Avoid matching `$$` display math leftovers by requiring non-`$` content.
        result = replaceMatches(
            in: result,
            pattern: #"(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)"#
        ) { match in
            readableMath(String(match[1]))
        }
        return result
    }

    /// Models often wrap formulas in bare `[ ... ]` instead of LaTeX delimiters.
    private static func convertBracketWrappedMathBlocks(_ text: String) -> String {
        var result = replaceMatches(
            in: text,
            pattern: #"\[\s*\n([\s\S]*?)\n\s*\]"#
        ) { match in
            let inner = String(match[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeMath(inner) else {
                return String(match[0])
            }
            return "\n\n`\(readableMath(inner))`\n\n"
        }

        // Single-line `[formula]` blocks that clearly look like math/chemistry.
        result = replaceMatches(
            in: result,
            pattern: #"\[([^\]\n]+)\]"#
        ) { match in
            let inner = String(match[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeMath(inner) else {
                return String(match[0])
            }
            return "`\(readableMath(inner))`"
        }

        return result
    }

    private static func readableMath(_ text: String) -> String {
        let withoutCommands = convertLatexCommands(text)
        let withScripts = convertScriptNotation(withoutCommands)
        return withScripts
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
