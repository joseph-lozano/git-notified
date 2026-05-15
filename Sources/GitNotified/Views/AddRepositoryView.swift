import SwiftUI

struct AddRepositoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [GHRepoListing] = []
    @State private var pendingPaste: (owner: String, name: String)?
    @State private var loading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add repository").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            TextField("Search your repos or paste owner/name or URL", text: $query, onCommit: refresh)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, new in
                    pendingPaste = model.parseRepoString(new)
                    refresh()
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let paste = pendingPaste,
                       !results.contains(where: { $0.nameWithOwner.lowercased() == "\(paste.owner)/\(paste.name)".lowercased() }) {
                        Button {
                            confirm(owner: paste.owner, name: paste.name)
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard")
                                Text("\(paste.owner)/\(paste.name)")
                                Spacer()
                                Text("Use as entered").font(.caption).foregroundColor(.secondary)
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }

                    if loading {
                        ProgressView().padding()
                    }
                    ForEach(results, id: \.nameWithOwner) { repo in
                        Button {
                            confirm(owner: repo.owner.login, name: repo.name)
                        } label: {
                            HStack {
                                Image(systemName: "book.closed")
                                Text(repo.nameWithOwner)
                                Spacer()
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 240)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { refresh() }
    }

    private func refresh() {
        loading = true
        model.searchRepos(query) { items in
            self.results = items
            self.loading = false
        }
    }

    private func confirm(owner: String, name: String) {
        model.addRepo(owner: owner, name: name, mode: .participating)
        dismiss()
    }
}
