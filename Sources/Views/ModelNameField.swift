import SwiftUI

/// A model-name text field with a "browse" button that fetches the models
/// the provider actually offers and lets the user pick one from a searchable
/// list. Typing a name by hand still works (custom/fine-tuned models, or when
/// the list can't be fetched).
struct ModelNameField: View {
    let placeholder: String
    @Binding var text: String
    let source: ModelSource
    /// Chat/embeddings URL — only used for local servers.
    var localEndpoint: String = ""
    var kind: ModelListKind = .chat

    @State private var showPicker = false
    @State private var models: [AvailableModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var search = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)

            Button {
                showPicker = true
                load(forceRefresh: false)
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help("Browse the models \(source.rawValue) offers")
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                pickerContent
            }
        }
    }

    private var filteredModels: [AvailableModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(source.rawValue) Models")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        load(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh the list")
                }
            }

            TextField("Search models", text: $search)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isLoading && errorMessage == nil && models.isEmpty {
                Text("No models were returned.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !models.isEmpty {
                List(filteredModels) { model in
                    Button {
                        text = model.id
                        showPicker = false
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.id)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                if let name = model.name, name != model.id {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if let detail = model.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            if model.id == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)

                Text("\(filteredModels.count) of \(models.count) models")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 420, height: models.isEmpty ? 150 : 420)
    }

    private func load(forceRefresh: Bool) {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                models = try await ModelCatalogService.shared.models(
                    for: source,
                    localEndpoint: localEndpoint,
                    kind: kind,
                    forceRefresh: forceRefresh
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
