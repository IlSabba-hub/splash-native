import Foundation
import Testing
@testable import DeckUI

@MainActor @Suite struct ReadmeTests {
    static let repos = [
        "unsloth/Qwen3.6-35B-A3B-GGUF", "mlx-community/Qwen3.6-35B-A3B-4bit", "unsloth/Qwen3.8-27B-GGUF",
        "mlx-community/Qwen3.8-27B-4bit", "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF", "mlx-community/Qwen3.8-Flash-Next-4bit",
        "unsloth/flint-GGUF", "mlx-community/flint-mixed-3-4bit", "unsloth/Inkling-2-Mini-GGUF", "mlx-community/Inkling-2-Mini-4bit",
        "unsloth/Ornith-1.5-122B-GGUF", "ornith-ai/Ornith-1.5-122B-MLX-4bit", "prism-ml/Ternary-Bonsai-2-27B-gguf",
    ]

    static func readme(_ repo: String) throws -> String {
        let text = try Fixtures.text("hub/readme/" + repo.replacing("/", with: "--") + ".md")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    static func blocks(_ repo: String) throws -> [ReadmeDocument.Block] {
        ReadmeDocument.blocks(try readme(repo), links: .init(repo: repo))
    }

    static func texts(_ blocks: [ReadmeDocument.Block]) -> [String] {
        func markdown(_ block: MarkdownText.Block) -> [String] {
            switch block {
            case let .paragraph(text), let .heading(_, text): [text]
            case .code, .rule: []
            case let .list(items): items.map(\.text)
            case let .quote(blocks): blocks.flatMap(markdown)
            case let .table(header, _, rows): header + rows.flatMap { $0 }
            }
        }
        return blocks.flatMap { block -> [String] in
            switch block {
            case let .markdown(block): markdown(block)
            case let .table(table): table.rows.flatMap { $0.cells.map(\.text) }
            case let .details(summary, blocks): [summary] + texts(blocks)
            }
        }
    }

    static func tables(_ blocks: [ReadmeDocument.Block]) -> [ReadmeDocument.Table] {
        blocks.flatMap { block -> [ReadmeDocument.Table] in
            switch block {
            case let .table(table): [table]
            case let .details(_, blocks): tables(blocks)
            case .markdown: []
            }
        }
    }

    @Test func everyCatalogReadmeIsCleanAndSafe() throws {
        let clock = ContinuousClock()
        var elapsed = Duration.zero
        for repo in Self.repos {
            let text = try Self.readme(repo)
            var blocks: [ReadmeDocument.Block] = []
            elapsed += clock.measure { blocks = ReadmeDocument.blocks(text, links: .init(repo: repo)) }
            #expect(!blocks.isEmpty, "\(repo)")
            for text in Self.texts(blocks) {
                let tags = text.replacing("\\<", with: "").matches(of: /<\/?(table|tr|td|th|br|img|div|span|p|a|sup|sub|details|summary|h[1-6]|ul|li|b|strong|em|code|small)\b/)
                #expect(tags.isEmpty, "\(repo): \(text.prefix(160))")
                for link in text.matches(of: /\]\(([^)]*)\)/) {
                    #expect(link.output.1.hasPrefix("https://"), "\(repo): \(link.output.1)")
                }
            }
        }
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    @Test func inklingBenchmarksAreARealTable() throws {
        let tables = Self.tables(try Self.blocks("unsloth/Inkling-2-Mini-GGUF"))
        let benchmark = try #require(tables.first { $0.rows.first?.cells.contains { $0.text == "Gemma 4 31B" } == true })
        let header = try #require(benchmark.rows.first)
        #expect(header.header)
        #expect(header.cells.map(\.text) == ["", "Inkling 2 Mini", "Gemma 4 31B", "Muse Glimmer", "Qwen3.8-27B", "Nemotron 3.5 Super VL"])
        let params = try #require(benchmark.rows.first { $0.cells.first?.text.hasPrefix("Params (B)") == true })
        #expect(params.cells.map(\.text) == ["Params (B)\nactivated / total", "5/26", "31/31", "30/30", "27/27", "12/125"])
        #expect(params.cells[1].alignment == .center)
        #expect(benchmark.columns == 6 && benchmark.rows.count > 10)
    }

    @Test func groupRowsKeepTheirSpan() throws {
        let tables = Self.tables(try Self.blocks("unsloth/Qwen3.6-35B-A3B-GGUF"))
        let group = try #require(tables.lazy.flatMap(\.rows).first { $0.cells.first?.text == "Coding Agent" })
        #expect(group.cells.count == 1 && group.cells[0].span == 6)
        #expect(tables.count >= 2 && tables.allSatisfy { $0.columns >= 2 })
    }

    @Test func flintHeadingImageAndLinks() throws {
        let blocks = try Self.blocks("unsloth/flint-GGUF")
        #expect(blocks.contains(.markdown(.heading(level: 1, text: "Recursive Flint"))))
        let texts = Self.texts(blocks)
        let image = tr("discover.readme.image", "Flint logo")
        #expect(texts.contains("[\(image)](https://huggingface.co/unsloth/flint-GGUF/resolve/main/assets/flint-logo.png)"))
        #expect(texts.contains { $0.contains("[Blog](https://www.recursive.com/updates/introducing-recursive-flint)") })
    }

    @Test func detailsKeepTheirMarkdown() throws {
        let blocks = try Self.blocks("mlx-community/flint-mixed-3-4bit")
        let details = try #require(blocks.lazy.compactMap { block -> (String, [ReadmeDocument.Block])? in
            if case let .details(summary, inner) = block { (summary, inner) } else { nil }
        }.first)
        #expect(details.0 == "Full numbers and method")
        #expect(!Self.tables(details.1).isEmpty)
    }

    @Test func unsafeOrMalformedLinksStayText() throws {
        let texts = Self.texts(try Self.blocks("unsloth/Qwen3.8-27B-GGUF"))
        #expect(texts.contains { $0.contains("GitHub repo") })
        #expect(!texts.contains { $0.contains("(github.com") || $0.contains("huggingface.co/unsloth/Qwen3.8-27B-GGUF/blob/main/github.com") })
        let ista = Self.texts(try Self.blocks("ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF"))
        #expect(!ista.contains { $0.contains("<!--") || $0.contains("-->") })
    }

    @Test func linkRules() {
        let inline = ReadmeDocument.Inline(links: .init(repo: "a/b"))
        #expect(inline.markdown("[x](http://e.com) [y](https://e.com) [z](javascript:void) [w](#top)") == "x [y](https://e.com) z w")
        #expect(inline.markdown("see [doc](docs/x.md)") == "see [doc](https://huggingface.co/a/b/blob/main/docs/x.md)")
        #expect(inline.markdown("a<br>b <sup>2</sup> `<think>` <think>") == "a\nb 2 `<think>` \\<think>")
        #expect(inline.markdown("[![badge](https://img.shields.io/x.svg)](https://github.com/x)") == "[badge](https://github.com/x)")
        #expect(ReadmeDocument.HTML.decode("&amp; &lt;b&gt; &#39; &#x2014; &bogus;") == "& <b> ' — &bogus;")
    }
}
