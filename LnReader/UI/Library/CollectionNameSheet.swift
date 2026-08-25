import SwiftUI

/// Name prompt for creating a collection. A sheet, not an alert — SwiftUI
/// allows only one `.alert` per view, and the Menu→alert combination is
/// unreliable, so alerts stay reserved for errors.
struct CollectionNameSheet: View {
    var confirmTitle = "Create"
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(confirm)
            }
            .navigationTitle("New collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: confirm)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.height(180)])
        .onAppear { nameFocused = true }
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}
