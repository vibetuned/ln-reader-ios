import SwiftUI
import LnReaderCore

/// "Book finished — continue the collection?" prompt, offering the previous /
/// next book by cover. Presented globally via ContinueCollectionHost.
struct ContinueCollectionSheet: View {
    @Environment(CollectionAdvanceController.self) private var advance
    let prompt: CollectionEndPrompt

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("You finished")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("“\(prompt.finished.title)”")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Continue the collection?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            HStack(alignment: .top, spacing: 28) {
                if let previous = prompt.previous {
                    bookOption(previous, label: "Previous")
                }
                if let next = prompt.next {
                    bookOption(next, label: "Next")
                }
            }

            Button("Not now") {
                advance.dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func bookOption(_ book: Book, label: String) -> some View {
        Button {
            advance.continueTo(bookId: book.id)
        } label: {
            VStack(spacing: 8) {
                CoverImage(url: advance.coverURL(for: book))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(width: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 5, y: 3)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(book.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 130)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Presents the collection-end prompt. Attached to the tab root AND to the
/// reader's full-screen cover — only one is `active` at a time, because a
/// sheet can't present from a context hidden under a cover.
struct ContinueCollectionHost: ViewModifier {
    @Environment(CollectionAdvanceController.self) private var advance
    let active: Bool

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { active ? advance.prompt : nil },
            set: { if $0 == nil, active { advance.dismiss() } }
        )) { prompt in
            ContinueCollectionSheet(prompt: prompt)
                .presentationDetents([.medium])
        }
    }
}
