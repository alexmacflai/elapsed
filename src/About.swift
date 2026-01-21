import SwiftUI
import Foundation

struct AboutView: View {
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if blocks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadMarkdown() }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            switch level {
            case 1:
                Text(text).font(.title).bold()
            case 2:
                Text(text).font(.title2).bold()
            default:
                Text(text).font(.title3).bold()
            }
        case .paragraph(let text):
            Text(text).font(.body)
        case .bulletedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.body)
                        Text(item).font(.body)
                    }
                }
            }
            .padding(.leading, 2)
        case .spacer:
            Spacer(minLength: 8).fixedSize()
        }
    }

    private func loadMarkdown() async {
        guard let url = Bundle.main.url(forResource: "aboutContent", withExtension: "md")
            ?? Bundle.main.url(forResource: "AboutContent", withExtension: "md") else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8) else { return }
            blocks = parseMarkdown(string)
        } catch {
            // leave blocks empty -> ProgressView or nothing
        }
    }
}

// MARK: - Simple Markdown parsing
private enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletedList(items: [String])
    case spacer
}

private func parseMarkdown(_ text: String) -> [MarkdownBlock] {
    // Split by empty lines into raw blocks, but keep bullet lists together
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")

    var blocks: [MarkdownBlock] = []
    var i = 0

    func flushParagraph(_ buffer: inout [String]) {
        if !buffer.isEmpty {
            let joined = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(text: joined)) }
            buffer.removeAll(keepingCapacity: false)
        }
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            blocks.append(.spacer)
            i += 1
            continue
        }

        // Headings #, ##, ###
        if trimmed.hasPrefix("### ") {
            blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
            i += 1
            continue
        } else if trimmed.hasPrefix("## ") {
            blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            i += 1
            continue
        } else if trimmed.hasPrefix("# ") {
            blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            i += 1
            continue
        }

        // Bulleted list: consecutive lines starting with "- "
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
            var items: [String] = []
            var j = i
            while j < lines.count {
                let l = lines[j].trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("- ") {
                    items.append(String(l.dropFirst(2)))
                    j += 1
                } else if l.hasPrefix("• ") {
                    items.append(String(l.dropFirst(2)))
                    j += 1
                } else if l.isEmpty {
                    j += 1 // allow a single empty line inside list blocks
                    break
                } else {
                    break
                }
            }
            if !items.isEmpty { blocks.append(.bulletedList(items: items)) }
            i = j
            continue
        }

        // Paragraph: collect until blank line or next block
        var buffer: [String] = [trimmed]
        var j = i + 1
        while j < lines.count {
            let l = lines[j]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            // stop on next heading or bullet
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ") || t.hasPrefix("- ") || t.hasPrefix("• ") { break }
            buffer.append(t)
            j += 1
        }
        flushParagraph(&buffer)
        i = j
    }

    // Collapse consecutive spacers
    var collapsed: [MarkdownBlock] = []
    var lastWasSpacer = false
    for b in blocks {
        if case .spacer = b {
            if !lastWasSpacer { collapsed.append(b) }
            lastWasSpacer = true
        } else {
            collapsed.append(b)
            lastWasSpacer = false
        }
    }

    return collapsed
}

#Preview {
    NavigationStack {
        AboutView()
            .navigationTitle("About Elapsed")
            .navigationBarTitleDisplayMode(.inline)
    }
}

