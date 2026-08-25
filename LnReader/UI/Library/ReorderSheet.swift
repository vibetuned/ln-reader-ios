import SwiftUI
import LnReaderCore

/// Drag-to-arrange a collection's manual order (Android's ReorderScreen).
/// Rows save as they move — no separate confirm step.
struct ReorderSheet: View {
    let model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.sortedItems) { item in
                    HStack(spacing: 12) {
                        CoverImage(url: model.coverURL(for: item))
                            .frame(width: 32, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(item.book.title)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                }
                .onMove { source, destination in
                    model.moveManualItems(fromOffsets: source, toOffset: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Manual order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
