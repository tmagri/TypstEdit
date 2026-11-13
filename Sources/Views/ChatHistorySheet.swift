import SwiftUI

struct ChatHistorySheet: View {
    @ObservedObject var store: AIChatSessionStore
    let activeSessionID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedLabel: String?
    @State private var results: [ChatSessionSearchResult] = []
    @State private var editingSessionID: UUID?
    @State private var labelsDraft = ""

    private var searchKey: String {
        "\(query)\u{0}\(selectedLabel ?? "")"
    }

    private var availableLabels: [String] {
        Array(Set(store.sessions.flatMap(\.labels))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)

            if !availableLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        labelFilter("All", selected: selectedLabel == nil) { selectedLabel = nil }
                        ForEach(availableLabels, id: \.self) { label in
                            labelFilter(label, selected: selectedLabel == label) {
                                selectedLabel = selectedLabel == label ? nil : label
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
            Divider()

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(query.isEmpty ? "No Conversations" : "No Matches")
                        .font(.headline)
                    Text(query.isEmpty ? "Saved conversations will appear here." : "Try another search or label.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { result in
                            historyRow(result)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(results.count) conversation\(results.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
        .task(id: searchKey) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let matches = await store.searchSessions(query: query, label: selectedLabel)
            guard !Task.isCancelled else { return }
            results = matches
        }
        .alert("Edit Conversation Labels", isPresented: Binding(
            get: { editingSessionID != nil },
            set: { if !$0 { editingSessionID = nil } }
        )) {
            TextField("Comma-separated labels", text: $labelsDraft)
            Button("Cancel", role: .cancel) { editingSessionID = nil }
            Button("Save") {
                if let id = editingSessionID {
                    store.setLabels(labelsDraft.split(separator: ",").map(String.init), for: id)
                    Task {
                        results = await store.searchSessions(query: query, label: selectedLabel)
                    }
                }
                editingSessionID = nil
            }
        } message: {
            Text("Labels help group related chats. Each label can be up to 40 characters.")
        }
    }

    private func labelFilter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func historyRow(_ result: ChatSessionSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    store.switchSession(to: result.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(result.summary.displayTitle)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if result.id == activeSessionID {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                            Spacer(minLength: 4)
                            Text(result.summary.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let snippet = result.snippet {
                            Text(snippet)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if result.matchingMessageCount > 0 {
                            Text("\(result.matchingMessageCount) matching message\(result.matchingMessageCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    editingSessionID = result.id
                    labelsDraft = result.summary.labels.joined(separator: ", ")
                } label: {
                    Image(systemName: "tag")
                }
                .buttonStyle(.plain)
                .help("Edit labels")
            }
            if !result.summary.labels.isEmpty {
                HStack(spacing: 5) {
                    ForEach(result.summary.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
