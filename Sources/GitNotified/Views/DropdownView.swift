import SwiftUI
import AppKit

struct DropdownView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.setup.pendingStep != nil {
                SetupChecklistView(setup: model.setup)
                    .padding(12)
                Divider()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ReviewsRequestedSection(rows: model.reviewRows)
                    Divider()
                    CIFailingSection(rows: model.ciFailingRows)
                    Divider()
                    ActivitySection(rows: model.activityRows)
                }
                .padding(12)
                Divider()
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.showingAddRepo = true
                } label: {
                    Label("Add repository…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Divider()

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()
            FooterView()
                .padding(8)
        }
        .sheet(isPresented: $model.showingAddRepo) {
            AddRepositoryView()
                .environmentObject(model)
        }
    }
}

struct SetupChecklistView: View {
    let setup: SetupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup").font(.headline)
            checklistRow(done: setup.ghInstalled, label: "Install `gh`", pending: setup.pendingStep == .installGh, detail: setup.pendingStep == .installGh ? "Download from cli.github.com" : nil)
            checklistRow(done: setup.signedIn, label: "Sign in with `gh auth login`", pending: setup.pendingStep == .signIn, detail: setup.pendingStep == .signIn ? "Run `gh auth login` in your terminal" : nil)
            checklistRow(done: setup.hasRepo, label: "Add a repository", pending: setup.pendingStep == .addRepo, detail: nil)
        }
    }

    @ViewBuilder
    private func checklistRow(done: Bool, label: String, pending: Bool, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : (pending ? "circle.dashed" : "circle"))
                .foregroundColor(done ? .green : (pending ? .accentColor : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(done ? .secondary : .primary)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct ReviewsRequestedSection: View {
    let rows: [DropdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviews requested").font(.headline)
            if rows.isEmpty {
                Text("No pending review requests.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    RowView(row: row)
                }
            }
        }
    }
}

struct CIFailingSection: View {
    let rows: [DropdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CI failing").font(.headline)
            if rows.isEmpty {
                Text("No failing CI.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    RowView(row: row)
                }
            }
        }
    }
}

struct ActivitySection: View {
    let rows: [DropdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New comments & reviews").font(.headline)
            if rows.isEmpty {
                Text("No recent activity in the last 24 hours.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    RowView(row: row)
                }
            }
            Text("Showing activity from the last 24 hours.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
    }
}

struct RowView: View {
    let row: DropdownRow

    var body: some View {
        Button {
            if let url = URL(string: row.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.pr.displayRef) — \(row.pr.title)")
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(row.summary) · \(row.age)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Text(footerText)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var footerText: String {
        if model.lastError != nil {
            return "Last check failed"
        }
        guard let date = model.lastCheckedAt else {
            return "Not checked yet"
        }
        return "Last checked \(Poller.ageString(from: date))"
    }
}
