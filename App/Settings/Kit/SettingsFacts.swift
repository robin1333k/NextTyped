import SwiftUI

/// A two-column grid of disclosure facts ("Reads", "Stored", "Not guaranteed"). The text wraps.
struct SettingsFacts: View {
    let rows: [(label: String, text: String)]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    Text(rows[index].label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(rows[index].text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
