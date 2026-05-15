// PROTOTYPE — throwaway. Floating switcher inside the dropdown that flips between
// the original dropdown layout and three prototype variants. Persists across launches
// via @AppStorage. Delete this file (and the rest of Prototype/) when the layout
// question is answered.

import SwiftUI

enum PrototypeVariant: String, CaseIterable, Identifiable {
    case original = "Original"
    case a = "A: Nested tree"
    case b = "B: PR cards"
    case c = "C: Repo tabs"

    var id: String { rawValue }
    var key: String { String(rawValue.prefix(1)).lowercased() }
}

struct PrototypeSwitcher: View {
    @Binding var variant: PrototypeVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("PROTOTYPE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange)
                    .clipShape(Capsule())
                Text("Dropdown layout")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Picker("", selection: $variant) {
                ForEach(PrototypeVariant.allCases) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(6)
    }
}
