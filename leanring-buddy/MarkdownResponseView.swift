import SwiftUI

/// Renders completed assistant responses as visible markdown blocks.
/// This avoids relying on SwiftUI `Text` to interpret Foundation's block intents,
/// which can collapse headers and list markers into a single run of text.
struct MarkdownResponseView: View {
    let markdown: String
    var primaryTextColor: Color = DS.Colors.textPrimary
    var secondaryTextColor: Color = DS.Colors.textSecondary
    var codeTextColor: Color = DS.Colors.codeText

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
            Text(MarkdownRenderer.renderInline(text))
                .font(headingFont(for: level))
                .foregroundColor(primaryTextColor)
                .padding(.top, level <= 2 ? 4 : 1)

        case .paragraph(let text):
            Text(MarkdownRenderer.renderInline(text))
                .font(.system(size: 13))
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
                Text(MarkdownRenderer.renderInline(text))
                    .font(.system(size: 13))
                    .italic()
                    .foregroundColor(secondaryTextColor)
            }

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
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(secondaryTextColor)
                .frame(minWidth: marker.count > 1 ? 18 : 10, alignment: .trailing)

            Text(MarkdownRenderer.renderInline(text))
                .font(.system(size: 13))
                .foregroundColor(primaryTextColor)
        }
        .padding(.leading, CGFloat(indentLevel) * 14)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 18, weight: .bold)
        case 2:
            return .system(size: 16, weight: .bold)
        case 3:
            return .system(size: 14, weight: .semibold)
        default:
            return .system(size: 13, weight: .semibold)
        }
    }
}
