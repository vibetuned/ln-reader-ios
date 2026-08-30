import SwiftUI
import LnReaderCore

/// Search field row shown under the nav bar while search is active, with the
/// n/m counter (tap reopens the results) and prev/next stepping.
struct ReaderSearchBar: View {
    @Bindable var model: ReaderViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.closeSearch()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close search")

            TextField("Search in book", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { model.submitSearch() }

            if let selection = model.searchSelection,
               let count = model.searchResults?.count, count > 0 {
                Button("\(selection + 1)/\(count)") {
                    model.showSearchResults = true
                }
                .font(.caption.monospacedDigit())
                Button {
                    model.stepSearchResult(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(selection <= 0)
                .accessibilityLabel("Previous match")
                Button {
                    model.stepSearchResult(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(selection >= count - 1)
                .accessibilityLabel("Next match")
            } else if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "delete.left")
                }
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .onAppear { focused = true }
    }
}

/// Full-content overlay listing the matches of the submitted query.
struct SearchResultsList: View {
    let model: ReaderViewModel

    var body: some View {
        Group {
            if model.isSearching {
                centered { ProgressView() }
            } else if let results = model.searchResults {
                if results.isEmpty {
                    centered {
                        Text("No matches found.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    resultList(results)
                }
            } else {
                centered {
                    Text("Search the whole book for a word or phrase.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func resultList(_ results: [EpubSearchMatch]) -> some View {
        List {
            Section {
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    Button {
                        model.openSearchResult(index)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Page \(result.spineIndex + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(emphasized(result))
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                let capped = results.count >= EpubTextSearch.maxResults
                let label = results.count == 1 ? "1 match" : "\(results.count) matches"
                Text(capped ? "First \(label)" : label)
            }
        }
        .listStyle(.plain)
    }

    private func emphasized(_ result: EpubSearchMatch) -> AttributedString {
        var text = AttributedString(result.snippet)
        if result.matchStart + result.matchLength <= text.characters.count {
            let start = text.index(text.startIndex, offsetByCharacters: result.matchStart)
            let end = text.index(start, offsetByCharacters: result.matchLength)
            text[start ..< end].font = .subheadline.bold()
        }
        return text
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
