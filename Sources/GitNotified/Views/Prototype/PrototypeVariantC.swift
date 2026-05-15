// PROTOTYPE — throwaway. See PrototypeGrouping.swift.
// Variant C — Repo segmented control on top; selected repo's PR list fills the body
// with per-PR event subsections rendered inline. Only one repo visible at a time.

import SwiftUI
import AppKit

struct PrototypeVariantC: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedSlug: String?

    var body: some View {
        let buckets = PrototypeGrouping.group(model: model)
        VStack(alignment: .leading, spacing: 8) {
            if buckets.isEmpty {
                Text("No outstanding items.")
                    .font(.subheadline).foregroundColor(.secondary)
            } else {
                repoStrip(buckets)
                Divider()
                let active = buckets.first { $0.slug == selectedSlug } ?? buckets.first!
                repoBody(active)
            }
        }
        .onAppear {
            if selectedSlug == nil { selectedSlug = buckets.first?.slug }
        }
    }

    @ViewBuilder
    private func repoStrip(_ buckets: [RepoBucket]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(buckets) { repo in
                    let selected = (repo.slug == (selectedSlug ?? buckets.first?.slug))
                    Button {
                        selectedSlug = repo.slug
                    } label: {
                        HStack(spacing: 4) {
                            Text(repo.slug).font(.caption)
                            Text("\(repo.totalCount)")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.white.opacity(0.3))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(selected ? Color.accentColor : Color.gray.opacity(0.15))
                        .foregroundColor(selected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func repoBody(_ repo: RepoBucket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(repo.prs) { pr in
                prBlock(pr)
            }
        }
    }

    @ViewBuilder
    private func prBlock(_ pr: PRBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let url = URL(string: pr.pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                HStack {
                    Text("#\(pr.pr.number)").font(.subheadline).bold()
                    Text(pr.pr.title).font(.subheadline).lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            subsection("Review requested", rows: pr.reviewRequests, accent: .blue)
            subsection("CI failing", rows: pr.ciRows, accent: .red)
            subsection("Comments", rows: pr.commentRows, accent: .gray)
            subsection("Reviews", rows: pr.reviewRows, accent: .green)
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func subsection(_ title: String, rows: [DropdownRow], accent: Color) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(title).font(.caption).foregroundColor(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack {
                            Text(row.summary).font(.caption)
                            Spacer()
                            Text(row.age).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                }
            }
        }
    }
}
