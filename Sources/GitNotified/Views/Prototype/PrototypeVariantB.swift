// PROTOTYPE — throwaway. See PrototypeGrouping.swift.
// Variant B — Flat per-PR cards, newest-first, with inline event-type badges and
// up-to-2 most-recent events surfaced below the title. Repo shown as small label.

import SwiftUI
import AppKit

struct PrototypeVariantB: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let buckets = PrototypeGrouping.group(model: model)
        let allPRs = buckets
            .flatMap { repo in repo.prs.map { (repo.slug, $0) } }
            .sorted { $0.1.newestActivity > $1.1.newestActivity }

        VStack(alignment: .leading, spacing: 8) {
            if allPRs.isEmpty {
                Text("No outstanding items.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            ForEach(allPRs, id: \.1.id) { repoSlug, pr in
                card(repoSlug: repoSlug, pr: pr)
            }
        }
    }

    @ViewBuilder
    private func card(repoSlug: String, pr: PRBucket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(repoSlug).font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(Capsule())
                Text("#\(pr.pr.number)").font(.subheadline).bold()
                Spacer()
                eventBadges(pr)
            }
            Button {
                if let url = URL(string: pr.pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                Text(pr.pr.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Surface up to 2 most-recent events inline.
            let recent = mostRecentEvents(pr, limit: 2)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent, id: \.id) { e in
                        eventLine(e)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(6)
    }

    private func mostRecentEvents(_ pr: PRBucket, limit: Int) -> [DropdownRow] {
        let all = pr.reviewRequests + pr.ciRows + pr.commentRows + pr.reviewRows
        return Array(all.sorted { $0.sortKey > $1.sortKey }.prefix(limit))
    }

    @ViewBuilder
    private func eventBadges(_ pr: PRBucket) -> some View {
        HStack(spacing: 4) {
            if !pr.reviewRequests.isEmpty {
                badge("review needed", color: .blue, count: pr.reviewRequests.count)
            }
            if !pr.ciRows.isEmpty {
                badge("CI ❌", color: .red, count: nil)
            }
            if !pr.commentRows.isEmpty {
                badge("comments", color: .gray, count: pr.commentRows.count)
            }
            if !pr.reviewRows.isEmpty {
                badge("reviews", color: .green, count: pr.reviewRows.count)
            }
        }
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color, count: Int?) -> some View {
        HStack(spacing: 3) {
            Text(text)
            if let count, count > 1 { Text("·").opacity(0.5); Text("\(count)") }
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(color.opacity(0.2))
        .foregroundColor(color)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func eventLine(_ row: DropdownRow) -> some View {
        Button {
            if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack {
                Text(row.summary).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(row.age).font(.caption2).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
