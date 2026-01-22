import SwiftUI

struct PlanogramGridView: View {
    @Binding var planogram: Planogram
    @Binding var selectedSlotId: String?

    var body: some View {
        let slots = planogram.shelves.first?.slots ?? []
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(slots) { slot in
                    Button {
                        selectedSlotId = slot.slotId
                    } label: {
                        VStack(spacing: 6) {
                            Text(slot.slotId)
                                .font(.headline)
                            Text(slot.product?.name.isEmpty == false ? slot.product!.name : "Empty")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            HStack(spacing: 8) {
                                Text("Inv: \(slot.inventory)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("$\(String(format: "%.2f", Double(slot.product?.priceCents ?? 0) / 100.0))")
                                    .font(.caption2)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(slot.enabled ? Color.blue.opacity(0.1) : Color.gray.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(slot.enabled ? Color.blue : Color.gray, lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
    }
}
