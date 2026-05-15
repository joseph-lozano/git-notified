import SwiftUI

struct ManageReposView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    isPresented = false
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Manage repositories").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
            }

            if model.state.repos.isEmpty {
                Text("No repositories yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.state.repos) { repo in
                            ManageRow(repo: repo)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
        .padding(12)
    }
}

struct ManageRow: View {
    @EnvironmentObject var model: AppModel
    let repo: WatchedRepo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.slug).font(.subheadline)
                Text(modeDescription).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { repo.mode },
                set: { model.setMode(slug: repo.id, mode: $0) }
            )) {
                ForEach(RepoMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Button(role: .destructive) {
                model.removeRepo(slug: repo.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Remove from watch")
        }
        .padding(.vertical, 2)
    }

    private var modeDescription: String {
        switch repo.mode {
        case .off: return "silenced — no GitHub calls"
        case .participating: return "PRs you're involved in"
        case .all: return "every open PR in the repo"
        }
    }
}
