// PROTOTYPE — throwaway. See PrototypeGrouping.swift.
// Variant A — Collapsible repos, PRs always expanded inline. More breathable spacing.

import SwiftUI
import AppKit

struct PrototypeVariantA: View {
    @EnvironmentObject var model: AppModel
    @State private var collapsedRepos: Set<String> = []

    var body: some View {
        let buckets = PrototypeGrouping.group(model: model)
        VStack(alignment: .leading, spacing: 14) {
            if buckets.isEmpty {
                Text("No outstanding items.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(buckets) { repo in
                repoBlock(repo)
            }
        }
    }

    @ViewBuilder
    private func repoBlock(_ repo: RepoBucket) -> some View {
        let isOpen = !collapsedRepos.contains(repo.slug)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isOpen { collapsedRepos.insert(repo.slug) }
                else { collapsedRepos.remove(repo.slug) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(repo.slug).font(.headline)
                    Text("\(repo.totalCount)")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(repo.prs) { pr in
                        prBlock(pr)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func prBlock(_ pr: PRBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let url = URL(string: pr.pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(pr.pr.number)")
                        .font(.subheadline).bold()
                        .foregroundColor(.secondary)
                    Text(pr.pr.title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(pr.reviewRequests) { eventLine($0, kind: "review requested", accent: .blue) }
                ForEach(pr.ciRows) { eventLine($0, kind: "CI failing", accent: .red) }
                ForEach(pr.commentRows) { eventLine($0, kind: "comment", accent: .gray) }
                ForEach(pr.reviewRows) { eventLine($0, kind: "review", accent: .green) }
            }
            .padding(.leading, 6)
        }
    }

    @ViewBuilder
    private func eventLine(_ row: DropdownRow, kind: String, accent: Color) -> some View {
        Button {
            if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(kind)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)
                Text(row.summary).font(.caption)
                Spacer()
                Text(row.age).font(.caption2).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
