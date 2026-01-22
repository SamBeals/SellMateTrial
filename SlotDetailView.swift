import SwiftUI

struct SlotDetailView: View {
    @Binding var slot: Slot

    let isVending: Bool
    let onTestVend: (String) -> Void

    @State private var localEnabled: Bool = true
    @State private var localInventory: String = "0"
    @State private var localProductName: String = ""
    @State private var localPriceCents: String = "0"
    @State private var localProductId: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?

    var body: some View {
        Form {
            Section(header: Text("Slot")) {
                HStack {
                    Text("Slot ID")
                    Spacer()
                    Text(slot.slotId)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Toggle("Enabled", isOn: $localEnabled)

                TextField("Inventory", text: $localInventory)
                    .keyboardType(.numberPad)
            }

            Section(header: Text("Product")) {
                TextField("Product Name", text: $localProductName)
                TextField("Product ID (optional)", text: $localProductId)
                TextField("Price (cents)", text: $localPriceCents)
                    .keyboardType(.numberPad)
            }

            Section(header: Text("Actions")) {
                Button {
                    onTestVend(slot.slotId)
                } label: {
                    if isVending {
                        HStack {
                            ProgressView()
                            Text("Vending…")
                        }
                    } else {
                        Text("Test Vend")
                    }
                }
                .disabled(isVending || slot.enabled == false)
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                Button("Save Changes") {
                    if let err = validate() {
                        errorText = err
                    } else {
                        apply()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle(slot.slotId)
        .onAppear { loadFromBinding() }
    }

    private func loadFromBinding() {
        localEnabled = slot.enabled
        localInventory = String(slot.inventory)
        localProductName = slot.product?.name ?? ""
        localProductId = slot.product?.productId ?? ""
        localPriceCents = String(slot.product?.priceCents ?? 0)
    }

    private func validate() -> String? {
        if Int(localInventory) == nil || (Int(localInventory) ?? -1) < 0 {
            return "Inventory must be a non-negative integer."
        }
        if Int(localPriceCents) == nil || (Int(localPriceCents) ?? -1) < 0 {
            return "Price (cents) must be a non-negative integer."
        }
        return nil
    }

    private func apply() {
        slot.enabled = localEnabled
        slot.inventory = Int(localInventory) ?? 0
        slot.product = Product(
            productId: localProductId.trimmingCharacters(in: .whitespacesAndNewlines),
            name: localProductName.trimmingCharacters(in: .whitespacesAndNewlines),
            priceCents: Int(localPriceCents) ?? 0
        )
        // Slot ID + motor ID are intentionally immutable for MVP
    }
}

#Preview {
    // Minimal preview stub
    let p = Product(productId: "", name: "Test", priceCents: 199)
    let s = Slot(slotId: "S01", enabled: true, inventory: 3, product: p, motor: SlotMotor(motorId: "S01"))
    return NavigationStack {
        SlotDetailView(
            slot: .constant(s),
            isVending: false,
            onTestVend: { _ in }
        )
    }
}
