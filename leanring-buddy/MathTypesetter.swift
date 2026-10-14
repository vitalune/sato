//
//  MathTypesetter.swift
//  leanring-buddy
//
//  Typesets LaTeX math from assistant responses into images with SwiftMath,
//  a native TeX-style math layout engine (fractions, roots, matrices, big
//  operators, accents) that draws with the Latin Modern Math font.
//
//  Models write LaTeX for KaTeX/MathJax, which accept more commands than
//  SwiftMath. Before typesetting, `swiftMathCompatibleLatex` rewrites common
//  unsupported commands and environments into equivalents SwiftMath can lay
//  out. Anything that still fails returns nil so callers can fall back to a
//  readable Unicode rendering instead of showing a broken formula.
//

import AppKit
import SwiftMath

/// One typeset formula, rendered as a template image so SwiftUI tints it with
/// the surrounding text color (light chat bubbles, dark speech bubbles, etc.).
struct TypesetMathFormula {
    let image: NSImage

    /// Distance from the bottom edge of `image` up to the math baseline.
    /// Inline formulas shift down by this amount so their baseline lines up
    /// with the baseline of the surrounding text.
    let baselineOffsetFromBottom: CGFloat

    var size: CGSize { image.size }
}

enum MathTypesetter {
    enum MathLayoutStyle: String {
        /// Compact text-style layout for formulas that sit inside a line of prose.
        case inline
        /// Larger display-style layout (limits above/below big operators) for
        /// formulas that stand on their own line.
        case display
    }

    /// Images are rasterized above Retina density so formulas stay crisp on
    /// every display without re-rendering when windows move between screens.
    private static let rasterizationScale: CGFloat = 3

    /// Small padding keeps italic overhangs and fraction bars from being
    /// clipped at the image edges. Horizontal padding stays minimal so
    /// punctuation after an inline formula does not look detached.
    private static let formulaPadding = NSEdgeInsets(top: 1, left: 0.5, bottom: 1, right: 0.5)

    private static let boxedFormulaBorderPadding: CGFloat = 4
    private static let boxedFormulaBorderWidth: CGFloat = 1

    /// Caches typeset results (including failures) by style, size, and source.
    /// Completed responses re-render on every SwiftUI update, so typesetting
    /// each formula once keeps scrolling and streaming smooth.
    private static let typesetFormulaCache = NSCache<NSString, CachedTypesetResult>()

    private final class CachedTypesetResult {
        let typesetFormula: TypesetMathFormula?

        init(typesetFormula: TypesetMathFormula?) {
            self.typesetFormula = typesetFormula
        }
    }

    // MARK: - Typesetting

    /// Returns the typeset formula, or nil when SwiftMath cannot lay out the
    /// LaTeX even after compatibility rewriting.
    static func typesetFormula(
        latex: String,
        fontSize: CGFloat,
        layoutStyle: MathLayoutStyle
    ) -> TypesetMathFormula? {
        let cacheKey = "\(layoutStyle.rawValue)|\(fontSize)|\(latex)" as NSString
        if let cachedResult = typesetFormulaCache.object(forKey: cacheKey) {
            return cachedResult.typesetFormula
        }

        let typesetFormula = renderFormula(
            latex: latex,
            fontSize: fontSize,
            layoutStyle: layoutStyle
        )
        typesetFormulaCache.setObject(
            CachedTypesetResult(typesetFormula: typesetFormula),
            forKey: cacheKey
        )
        return typesetFormula
    }

    private static func renderFormula(
        latex: String,
        fontSize: CGFloat,
        layoutStyle: MathLayoutStyle
    ) -> TypesetMathFormula? {
        let trimmedLatex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLatex.isEmpty else { return nil }

        // A formula wrapped entirely in \boxed{...} (common for final answers)
        // is typeset without the wrapper and then outlined, since SwiftMath
        // cannot draw boxes itself.
        let boxedFormulaContent = contentOfWholeFormulaBox(in: trimmedLatex)
        let latexToTypeset = latexWithTeXSpacingRules(
            swiftMathCompatibleLatex(boxedFormulaContent ?? trimmedLatex),
            layoutStyle: layoutStyle
        )

        var mathImage = MathImage(
            latex: latexToTypeset,
            fontSize: fontSize,
            textColor: .black,
            labelMode: layoutStyle == .display ? .display : .text,
            textAlignment: .left
        )
        mathImage.contentInsets = formulaPadding

        let (typesettingError, vectorImage, layoutInfo) = mathImage.asImage()
        guard typesettingError == nil,
              let vectorImage,
              let layoutInfo,
              vectorImage.size.width > 0,
              vectorImage.size.height > 0
        else {
            return nil
        }

        // Mirrors MathImage's vertical layout so the baseline can be located
        // inside the image it produced.
        let formulaInkHeight = max(layoutInfo.ascent + layoutInfo.descent, fontSize / 2)
        let availableHeight = vectorImage.size.height - formulaPadding.top - formulaPadding.bottom
        let baselineOffsetFromBottom = (availableHeight - formulaInkHeight) / 2
            + layoutInfo.descent
            + formulaPadding.bottom

        if boxedFormulaContent != nil {
            return outlinedFormula(
                vectorImage: vectorImage,
                baselineOffsetFromBottom: baselineOffsetFromBottom
            )
        }

        guard let rasterizedImage = rasterizedTemplateImage(
            size: vectorImage.size,
            drawContents: { drawingRect in
                vectorImage.draw(in: drawingRect)
            }
        ) else {
            return nil
        }

        return TypesetMathFormula(
            image: rasterizedImage,
            baselineOffsetFromBottom: baselineOffsetFromBottom
        )
    }

    private static func outlinedFormula(
        vectorImage: NSImage,
        baselineOffsetFromBottom: CGFloat
    ) -> TypesetMathFormula? {
        let borderInset = boxedFormulaBorderPadding + boxedFormulaBorderWidth
        let outlinedSize = CGSize(
            width: vectorImage.size.width + borderInset * 2,
            height: vectorImage.size.height + borderInset * 2
        )

        guard let rasterizedImage = rasterizedTemplateImage(
            size: outlinedSize,
            drawContents: { drawingRect in
                let borderRect = drawingRect.insetBy(
                    dx: boxedFormulaBorderWidth / 2,
                    dy: boxedFormulaBorderWidth / 2
                )
                let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 3, yRadius: 3)
                borderPath.lineWidth = boxedFormulaBorderWidth
                NSColor.black.setStroke()
                borderPath.stroke()

                vectorImage.draw(in: NSRect(
                    x: borderInset,
                    y: borderInset,
                    width: vectorImage.size.width,
                    height: vectorImage.size.height
                ))
            }
        ) else {
            return nil
        }

        return TypesetMathFormula(
            image: rasterizedImage,
            baselineOffsetFromBottom: baselineOffsetFromBottom + borderInset
        )
    }

    /// Draws into a high-density bitmap and marks the result as a template so
    /// only its alpha is used and SwiftUI applies the current text color.
    private static func rasterizedTemplateImage(
        size: CGSize,
        drawContents: (NSRect) -> Void
    ) -> NSImage? {
        let pixelWidth = Int(ceil(size.width * rasterizationScale))
        let pixelHeight = Int(ceil(size.height * rasterizationScale))

        guard pixelWidth > 0,
              pixelHeight > 0,
              let bitmapRepresentation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )
        else {
            return nil
        }

        // The point size must be set before the context is created so drawing
        // in points is scaled up to the bitmap's pixel density.
        bitmapRepresentation.size = size

        guard let bitmapGraphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRepresentation) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmapGraphicsContext
        drawContents(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let rasterizedImage = NSImage(size: size)
        rasterizedImage.addRepresentation(bitmapRepresentation)
        rasterizedImage.isTemplate = true
        return rasterizedImage
    }

    // MARK: - LaTeX Compatibility

    /// Rewrites KaTeX/MathJax-flavored LaTeX into the subset SwiftMath parses.
    /// Each rewrite keeps the formula's meaning and as much of its layout as
    /// SwiftMath can express.
    static func swiftMathCompatibleLatex(_ latex: String) -> String {
        var compatibleLatex = latex

        compatibleLatex = removeEquationNumberingAndSpacingHints(compatibleLatex)
        compatibleLatex = rewriteUnsupportedEnvironments(compatibleLatex)
        compatibleLatex = rewriteUnsupportedArgumentCommands(compatibleLatex)
        compatibleLatex = rewriteUnsupportedSymbolCommands(compatibleLatex)

        return compatibleLatex.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Restores TeX spacing conventions that SwiftMath does not apply itself.
    static func latexWithTeXSpacingRules(_ latex: String, layoutStyle: MathLayoutStyle) -> String {
        var spacedLatex = latex

        // TeX puts a thin space between a function name and its argument
        // ("sin x"), but SwiftMath sets "sinx". Arguments in parentheses or
        // \left delimiters keep no space, matching TeX.
        spacedLatex = replacingRegularExpression(
            #"(\\(?:sin|cos|tan|cot|sec|csc|arcsin|arccos|arctan|sinh|cosh|tanh|coth|log|ln|lg|exp|det|dim|ker|deg|gcd|arg|Pr)(?![A-Za-z])(?:\s*[\^_](?:\{[^{}]*\}|\\?[A-Za-z0-9]))*)\s*(?=[A-Za-z0-9]|\\(?!left|right|big|Big|bigg|Bigg)[A-Za-z])"#,
            in: spacedLatex,
            with: #"$1\\, "#
        )

        // In running text, TeX places the limits of sums, products, and
        // limits beside the operator so the line height stays close to the
        // prose. SwiftMath stacks them unless told otherwise.
        if layoutStyle == .inline {
            spacedLatex = replacingRegularExpression(
                #"\\(sum|prod|coprod|bigcup|bigcap|bigoplus|bigotimes|bigodot|bigvee|bigwedge|biguplus|bigsqcup|lim|limsup|liminf|max|min|sup|inf)(?![A-Za-z])(?!\s*\\(?:no)?limits)"#,
                in: spacedLatex,
                with: #"\\$1\\nolimits "#
            )
        }

        return spacedLatex
    }

    /// Returns the inside of `\boxed{...}` when it wraps the entire formula.
    private static func contentOfWholeFormulaBox(in latex: String) -> String? {
        for boxCommandName in ["boxed", "fbox"] {
            let commandPrefix = "\\" + boxCommandName
            guard latex.hasPrefix(commandPrefix) else { continue }

            let afterCommandIndex = latex.index(latex.startIndex, offsetBy: commandPrefix.count)
            guard let argument = bracedArgument(in: latex, startingAt: afterCommandIndex),
                  latex[argument.endIndex...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            return argument.content
        }
        return nil
    }

    /// Equation tags, labels, and manual spacing hints have no visual meaning
    /// in a chat bubble (or are unsupported), so they are removed. Tags are
    /// kept as a trailing "(n)" so references in prose still make sense.
    private static func removeEquationNumberingAndSpacingHints(_ latex: String) -> String {
        var cleanedLatex = latex
        var trailingEquationTags: [String] = []

        for tagCommandName in ["tag*", "tag"] {
            cleanedLatex = replaceCommand(
                named: tagCommandName,
                argumentCount: 1,
                in: cleanedLatex
            ) { arguments in
                trailingEquationTags.append(arguments[0])
                return ""
            }
        }

        for removableCommandName in ["label", "vphantom", "hphantom", "phantom", "hspace", "hspace*", "vspace", "vspace*"] {
            cleanedLatex = replaceCommand(
                named: removableCommandName,
                argumentCount: 1,
                in: cleanedLatex
            ) { _ in "" }
        }

        cleanedLatex = replacingRegularExpression(
            #"\\(nonumber|notag|hline|mathstrut|displaybreak|allowbreak)(?![A-Za-z])"#,
            in: cleanedLatex,
            with: ""
        )

        if !trailingEquationTags.isEmpty {
            let tagText = trailingEquationTags
                .map { "(\($0))" }
                .joined(separator: " ")
            cleanedLatex += " \\qquad \\text{\(tagText)}"
        }

        return cleanedLatex
    }

    private static func rewriteUnsupportedEnvironments(_ latex: String) -> String {
        var rewrittenLatex = latex

        // `array` and `alignat` take a column-spec argument that SwiftMath's
        // matrix and aligned environments do not accept.
        rewrittenLatex = replacingRegularExpression(
            #"\\begin\{(array|subarray)\}\s*\{[^{}]*\}"#,
            in: rewrittenLatex,
            with: "\\\\begin{matrix}"
        )
        rewrittenLatex = replacingRegularExpression(
            #"\\end\{(array|subarray)\}"#,
            in: rewrittenLatex,
            with: "\\\\end{matrix}"
        )
        rewrittenLatex = replacingRegularExpression(
            #"\\begin\{(alignat\*?|alignedat)\}\s*\{[^{}]*\}"#,
            in: rewrittenLatex,
            with: "\\\\begin{aligned}"
        )

        let environmentReplacements: [(unsupportedEnvironmentPattern: String, supportedEnvironment: String?)] = [
            ("align\\*?|alignat\\*?|alignedat|eqnarray\\*?|flalign\\*?", "aligned"),
            ("gather\\*|multline\\*?", "gather"),
            ("dcases\\*?|rcases", "cases"),
            // Equation wrappers only mark display math, which the caller
            // already handles, so their begin/end markers are dropped.
            ("equation\\*?|displaymath|math", nil),
        ]

        for (unsupportedEnvironmentPattern, supportedEnvironment) in environmentReplacements {
            let beginReplacement = supportedEnvironment.map { "\\\\begin{\($0)}" } ?? ""
            let endReplacement = supportedEnvironment.map { "\\\\end{\($0)}" } ?? ""
            rewrittenLatex = replacingRegularExpression(
                "\\\\begin\\{(\(unsupportedEnvironmentPattern))\\}",
                in: rewrittenLatex,
                with: beginReplacement
            )
            rewrittenLatex = replacingRegularExpression(
                "\\\\end\\{(\(unsupportedEnvironmentPattern))\\}",
                in: rewrittenLatex,
                with: endReplacement
            )
        }

        return rewrittenLatex
    }

    private static func rewriteUnsupportedArgumentCommands(_ latex: String) -> String {
        var rewrittenLatex = latex

        // Decorations SwiftMath cannot draw keep their content visible.
        for unwrappedCommandName in ["boxed", "fbox", "cancel", "bcancel", "xcancel"] {
            rewrittenLatex = replaceCommand(
                named: unwrappedCommandName,
                argumentCount: 1,
                in: rewrittenLatex
            ) { arguments in
                "{\(arguments[0])}"
            }
        }

        rewrittenLatex = replaceCommand(named: "emph", argumentCount: 1, in: rewrittenLatex) { arguments in
            "\\textit{\(arguments[0])}"
        }
        rewrittenLatex = replaceCommand(named: "mbox", argumentCount: 1, in: rewrittenLatex) { arguments in
            "\\text{\(arguments[0])}"
        }

        // \operatorname* stacks its scripts above and below, which is the
        // closest SwiftMath equivalent of \overset, \stackrel, and \underset.
        for stackedAboveCommandName in ["overset", "stackrel"] {
            rewrittenLatex = replaceCommand(
                named: stackedAboveCommandName,
                argumentCount: 2,
                in: rewrittenLatex
            ) { arguments in
                "\\operatorname*{\(arguments[1])}^{\(arguments[0])}"
            }
        }
        rewrittenLatex = replaceCommand(named: "underset", argumentCount: 2, in: rewrittenLatex) { arguments in
            "\\operatorname*{\(arguments[1])}_{\(arguments[0])}"
        }
        // Braces become under/overlines; a following `_{label}` or `^{label}`
        // then attaches to the marked group as a script.
        rewrittenLatex = replaceCommand(named: "underbrace", argumentCount: 1, in: rewrittenLatex) { arguments in
            "\\underline{\(arguments[0])}"
        }
        rewrittenLatex = replaceCommand(named: "overbrace", argumentCount: 1, in: rewrittenLatex) { arguments in
            "\\overline{\(arguments[0])}"
        }

        let labeledArrowReplacements: [(commandName: String, arrowCommand: String)] = [
            ("xrightarrow", "\\longrightarrow"),
            ("xleftarrow", "\\longleftarrow"),
            ("xRightarrow", "\\Longrightarrow"),
            ("xLeftarrow", "\\Longleftarrow"),
            ("xleftrightarrow", "\\longleftrightarrow"),
            ("xLeftrightarrow", "\\Longleftrightarrow"),
        ]
        for (commandName, arrowCommand) in labeledArrowReplacements {
            rewrittenLatex = replaceLabeledArrowCommand(
                named: commandName,
                arrowCommand: arrowCommand,
                in: rewrittenLatex
            )
        }

        rewrittenLatex = replaceCommand(named: "pmod", argumentCount: 1, in: rewrittenLatex) { arguments in
            "\\;(\\mathrm{mod}\\;\(arguments[0]))"
        }
        rewrittenLatex = replaceCommand(named: "pod", argumentCount: 1, in: rewrittenLatex) { arguments in
            "\\;(\(arguments[0]))"
        }

        rewrittenLatex = replaceCommand(named: "ce", argumentCount: 1, in: rewrittenLatex) { arguments in
            chemistryLatex(fromMhchemFormula: arguments[0])
        }

        return rewrittenLatex
    }

    private static func rewriteUnsupportedSymbolCommands(_ latex: String) -> String {
        // Each pattern only matches the complete command name, so `\dots`
        // does not also rewrite `\dotsb`.
        let symbolReplacements: [(commandPattern: String, replacement: String)] = [
            (#"\\:"#, #"\\>"#),
            (#"\\&"#, #"\\text{&}"#),
            (#"\\textdollar(?![A-Za-z])"#, #"\\\$"#),
            (#"\\dots[co]?(?![A-Za-z])"#, #"\\ldots"#),
            (#"\\dots[bmi](?![A-Za-z])"#, #"\\cdots"#),
            // `\left\lVert` becomes `\left\|` and a bare `\lvert` becomes `|`,
            // which SwiftMath accepts both with and without \left/\right.
            (#"\\[lr]Vert(?![A-Za-z])"#, #"\\|"#),
            (#"\\[lr]vert(?![A-Za-z])"#, "|"),
            (#"\\middle(?![A-Za-z])"#, ""),
            (#"\\bmod(?![A-Za-z])"#, #"\\;\\mathrm{mod}\\;"#),
            (#"\\coloneqq(?![A-Za-z])"#, ":="),
            (#"\\eqqcolon(?![A-Za-z])"#, "=:"),
            (#"\\therefore(?![A-Za-z])"#, "∴"),
            (#"\\because(?![A-Za-z])"#, "∵"),
            (#"\\checkmark(?![A-Za-z])"#, "✓"),
            (#"\\blacksquare(?![A-Za-z])"#, "■"),
            (#"\\rightleftharpoons(?![A-Za-z])"#, "⇌"),
            (#"\\leftrightharpoons(?![A-Za-z])"#, "⇋"),
            (#"\\rightleftarrows(?![A-Za-z])"#, "⇄"),
            (#"\\leftrightarrows(?![A-Za-z])"#, "⇆"),
            (#"\\(leadsto|rightsquigarrow)(?![A-Za-z])"#, "⇝"),
            (#"\\twoheadrightarrow(?![A-Za-z])"#, "↠"),
            (#"\\impliedby(?![A-Za-z])"#, #"\\Longleftarrow"#),
            (#"\\smallsetminus(?![A-Za-z])"#, #"\\setminus"#),
            (#"\\complement(?![A-Za-z])"#, "∁"),
            (#"\\mathscr(?![A-Za-z])"#, #"\\mathcal"#),
            (#"\\not\s*="#, #"\\neq"#),
        ]

        var rewrittenLatex = latex
        for (commandPattern, replacement) in symbolReplacements {
            rewrittenLatex = replacingRegularExpression(
                commandPattern,
                in: rewrittenLatex,
                with: replacement
            )
        }
        return rewrittenLatex
    }

    /// `\xrightarrow[below]{above}` becomes a long arrow with stacked labels.
    private static func replaceLabeledArrowCommand(
        named commandName: String,
        arrowCommand: String,
        in latex: String
    ) -> String {
        var rewrittenLatex = latex
        let commandPrefix = "\\" + commandName

        while let commandRange = rangeOfCommand(named: commandName, in: rewrittenLatex) {
            var argumentSearchIndex = commandRange.upperBound
            var belowLabel: String?

            if let optionalArgument = bracketedOptionalArgument(in: rewrittenLatex, startingAt: argumentSearchIndex) {
                belowLabel = optionalArgument.content
                argumentSearchIndex = optionalArgument.endIndex
            }

            guard let aboveLabelArgument = bracedArgument(in: rewrittenLatex, startingAt: argumentSearchIndex) else {
                // A malformed command is left for SwiftMath to reject so the
                // caller falls back to readable text.
                return rewrittenLatex.replacingCharacters(in: commandRange, with: commandPrefix + "MALFORMED")
            }

            var replacement = "\\operatorname*{\(arrowCommand)}^{\(aboveLabelArgument.content)}"
            if let belowLabel {
                replacement += "_{\(belowLabel)}"
            }
            rewrittenLatex.replaceSubrange(
                commandRange.lowerBound..<aboveLabelArgument.endIndex,
                with: replacement
            )
        }

        return rewrittenLatex
    }

    /// Converts a basic mhchem formula (`\ce{2H2 + O2 -> 2H2O}`) into plain
    /// LaTeX: upright element symbols, numeric subscripts, charges as
    /// superscripts, and reaction arrows.
    static func chemistryLatex(fromMhchemFormula mhchemFormula: String) -> String {
        let arrowReplacements: [(mhchemArrow: String, latexArrow: String)] = [
            ("<=>", " \\rightleftharpoons "),
            ("<->", " \\leftrightarrow "),
            ("->", " \\longrightarrow "),
            ("<-", " \\longleftarrow "),
        ]

        var formulaWithArrows = mhchemFormula
        for (mhchemArrow, latexArrow) in arrowReplacements {
            formulaWithArrows = formulaWithArrows.replacingOccurrences(of: mhchemArrow, with: latexArrow)
        }

        var chemistryLatex = ""
        var previousCharacterCanTakeSubscript = false
        var characterIndex = formulaWithArrows.startIndex

        while characterIndex < formulaWithArrows.endIndex {
            let character = formulaWithArrows[characterIndex]

            if character == "\\" {
                // Already-LaTeX commands such as the arrows above pass through.
                let commandEndIndex = formulaWithArrows[formulaWithArrows.index(after: characterIndex)...]
                    .firstIndex(where: { !$0.isLetter }) ?? formulaWithArrows.endIndex
                chemistryLatex += formulaWithArrows[characterIndex..<commandEndIndex]
                characterIndex = commandEndIndex
                previousCharacterCanTakeSubscript = false
                continue
            }

            if character == "^" {
                // Charges like ^2+ or ^{2-} become superscripts.
                let chargeStartIndex = formulaWithArrows.index(after: characterIndex)
                let chargeIsBraced = chargeStartIndex < formulaWithArrows.endIndex
                    && formulaWithArrows[chargeStartIndex] == "{"
                if chargeIsBraced,
                   let bracedCharge = bracedArgument(in: formulaWithArrows, startingAt: chargeStartIndex) {
                    chemistryLatex += "^{\(bracedCharge.content)}"
                    characterIndex = bracedCharge.endIndex
                } else {
                    let chargeEndIndex = formulaWithArrows[chargeStartIndex...]
                        .firstIndex(where: { !($0.isNumber || $0 == "+" || $0 == "-") }) ?? formulaWithArrows.endIndex
                    chemistryLatex += "^{\(formulaWithArrows[chargeStartIndex..<chargeEndIndex])}"
                    characterIndex = chargeEndIndex
                }
                previousCharacterCanTakeSubscript = false
                continue
            }

            if character.isLetter {
                let letterRunEndIndex = formulaWithArrows[characterIndex...]
                    .firstIndex(where: { !$0.isLetter }) ?? formulaWithArrows.endIndex
                chemistryLatex += "\\mathrm{\(formulaWithArrows[characterIndex..<letterRunEndIndex])}"
                characterIndex = letterRunEndIndex
                previousCharacterCanTakeSubscript = true
                continue
            }

            if character.isNumber && previousCharacterCanTakeSubscript {
                let digitRunEndIndex = formulaWithArrows[characterIndex...]
                    .firstIndex(where: { !$0.isNumber }) ?? formulaWithArrows.endIndex
                chemistryLatex += "_{\(formulaWithArrows[characterIndex..<digitRunEndIndex])}"
                characterIndex = digitRunEndIndex
                continue
            }

            chemistryLatex.append(character)
            previousCharacterCanTakeSubscript = character == ")" || character == "]"
            characterIndex = formulaWithArrows.index(after: characterIndex)
        }

        // SwiftMath has no ⇌ command, so the reversible arrow is drawn as the
        // Unicode character, which Latin Modern Math includes.
        return chemistryLatex.replacingOccurrences(of: "\\rightleftharpoons", with: "⇌")
    }

    // MARK: - LaTeX Command Parsing Helpers

    /// Replaces every `\commandName{arg1}{arg2}...` with the transform result.
    /// Arguments are matched with balanced braces so nested groups survive.
    private static func replaceCommand(
        named commandName: String,
        argumentCount: Int,
        in latex: String,
        transform: ([String]) -> String
    ) -> String {
        var rewrittenLatex = latex
        var searchStartIndex = rewrittenLatex.startIndex

        while let commandRange = rangeOfCommand(
            named: commandName,
            in: rewrittenLatex,
            searchStartIndex: searchStartIndex
        ) {
            var arguments: [String] = []
            var argumentSearchIndex = commandRange.upperBound

            for _ in 0..<argumentCount {
                guard let argument = bracedArgument(in: rewrittenLatex, startingAt: argumentSearchIndex) else {
                    break
                }
                arguments.append(argument.content)
                argumentSearchIndex = argument.endIndex
            }

            guard arguments.count == argumentCount else {
                // Leave malformed commands untouched and keep scanning after them.
                searchStartIndex = commandRange.upperBound
                continue
            }

            let replacement = transform(arguments)
            let replacedRange = commandRange.lowerBound..<argumentSearchIndex
            let replacementStartOffset = rewrittenLatex.distance(
                from: rewrittenLatex.startIndex,
                to: replacedRange.lowerBound
            )
            rewrittenLatex.replaceSubrange(replacedRange, with: replacement)
            searchStartIndex = rewrittenLatex.index(
                rewrittenLatex.startIndex,
                offsetBy: replacementStartOffset + replacement.count
            )
        }

        return rewrittenLatex
    }

    /// Finds `\commandName` where the name is not just the prefix of a longer
    /// command (so searching for `\tag` does not match `\tagline`).
    private static func rangeOfCommand(
        named commandName: String,
        in latex: String,
        searchStartIndex: String.Index? = nil
    ) -> Range<String.Index>? {
        let commandPrefix = "\\" + commandName
        var searchRange = (searchStartIndex ?? latex.startIndex)..<latex.endIndex

        while let candidateRange = latex.range(of: commandPrefix, range: searchRange) {
            let commandNameEndsWithLetter = commandName.last?.isLetter == true
            let nextCharacterIsLetter = candidateRange.upperBound < latex.endIndex
                && latex[candidateRange.upperBound].isLetter

            if !(commandNameEndsWithLetter && nextCharacterIsLetter) {
                return candidateRange
            }
            searchRange = candidateRange.upperBound..<latex.endIndex
        }
        return nil
    }

    /// Reads a `{...}` group (skipping leading whitespace) with balanced braces.
    /// A single unbraced token (`\frac12`-style) is also accepted.
    private static func bracedArgument(
        in latex: String,
        startingAt startIndex: String.Index
    ) -> (content: String, endIndex: String.Index)? {
        var currentIndex = startIndex
        while currentIndex < latex.endIndex, latex[currentIndex].isWhitespace {
            currentIndex = latex.index(after: currentIndex)
        }
        guard currentIndex < latex.endIndex else { return nil }

        guard latex[currentIndex] == "{" else {
            let singleTokenCharacter = latex[currentIndex]
            guard singleTokenCharacter.isLetter || singleTokenCharacter.isNumber else { return nil }
            return (String(singleTokenCharacter), latex.index(after: currentIndex))
        }

        var braceDepth = 0
        var scanIndex = currentIndex
        while scanIndex < latex.endIndex {
            let character = latex[scanIndex]
            if character == "\\" {
                // Escaped braces (`\{`) do not open or close groups.
                let escapedCharacterIndex = latex.index(after: scanIndex)
                scanIndex = escapedCharacterIndex < latex.endIndex
                    ? latex.index(after: escapedCharacterIndex)
                    : escapedCharacterIndex
                continue
            }
            if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth -= 1
                if braceDepth == 0 {
                    let contentStartIndex = latex.index(after: currentIndex)
                    return (String(latex[contentStartIndex..<scanIndex]), latex.index(after: scanIndex))
                }
            }
            scanIndex = latex.index(after: scanIndex)
        }
        return nil
    }

    /// Reads an optional `[...]` argument, as used by `\xrightarrow[below]{above}`.
    private static func bracketedOptionalArgument(
        in latex: String,
        startingAt startIndex: String.Index
    ) -> (content: String, endIndex: String.Index)? {
        guard startIndex < latex.endIndex,
              latex[startIndex] == "[",
              let closingBracketIndex = latex[startIndex...].firstIndex(of: "]")
        else {
            return nil
        }
        let contentStartIndex = latex.index(after: startIndex)
        return (String(latex[contentStartIndex..<closingBracketIndex]), latex.index(after: closingBracketIndex))
    }

    private static func replacingRegularExpression(
        _ pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regularExpression.stringByReplacingMatches(
            in: text,
            range: fullRange,
            withTemplate: template
        )
    }
}
