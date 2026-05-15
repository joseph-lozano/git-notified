// PROTOTYPE — throwaway. See PrototypeGrouping.swift.
// Variant A — Nested disclosure tree: collapsible repo → collapsible PR → flat events.

import SwiftUI
import AppKit

struct PrototypeVariantA: View {
    @EnvironmentObject var model: AppModel
    @State private var expandedRepos: Set<String> = []
    @State private var expandedPRs: Set<String> = []

    var body: some View {
        let buckets = PrototypeGrouping.group(model: model)
        VStack(alignment: .leading, spacing: 8) {
            if buckets.isEmpty {
                Text("No outstanding items.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(buckets) { repo in
                repoDisclosure(repo)
            }
        }
        .onAppear {
            // Default: expand all on first show so the user sees the full tree.
            if expandedRepos.isEmpty {
                expandedRepos = Set(buckets.map(\.slug))
            }
        }
    }

    @ViewBuilder
    private func repoDisclosure(_ repo: RepoBucket) -> some View {
        let isOpen = expandedRepos.contains(repo.slug)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isOpen { expandedRepos.remove(repo.slug) }
                else { expandedRepos.insert(repo.slug) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption)
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(repo.prs) { pr in
                        prDisclosure(pr)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func prDisclosure(_ pr: PRBucket) -> some View {
        let isOpen = expandedPRs.contains(pr.id)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isOpen { expandedPRs.remove(pr.id) }
                else { expandedPRs.insert(pr.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("#\(pr.pr.number)").font(.subheadline).bold()
                    Text(pr.pr.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    eventBadges(pr)
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pr.reviewRequests) { eventLine($0, kind: "review requested") }
                    ForEach(pr.ciRows) { eventLine($0, kind: "CI") }
                    ForEach(pr.commentRows) { eventLine($0, kind: "comment") }
                    ForEach(pr.reviewRows) { eventLine($0, kind: "review") }
                }
                .padding(.leading, 16)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func eventBadges(_ pr: PRBucket) -> some View {
        HStack(spacing: 4) {
            if !pr.reviewRequests.isEmpty { badge("R", color: .blue) }
            if !pr.ciRows.isEmpty { badge("CI", color: .red) }
            if !pr.commentRows.isEmpty { badge("\(pr.commentRows.count)c", color: .gray) }
            if !pr.reviewRows.isEmpty { badge("\(pr.reviewRows.count)rv", color: .green) }
        }
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func eventLine(_ row: DropdownRow, kind: String) -> some View {
        Button {
            if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack {
                Text(kind)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(row.summary).font(.caption)
                Spacer()
                Text(row.age).font(.caption2).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
