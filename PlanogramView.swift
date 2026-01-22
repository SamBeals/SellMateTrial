import SwiftUI
import FirebaseFirestore
import Combine

@MainActor
final class PlanogramViewModel: ObservableObject {
    @Published var planogram: Planogram
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var isVending = false
    @Published var errorText: String?
    @Published var selectedSlotId: String?

    private let service: FirestorePlanogramService
    private let machineId: String

    // Pi vend client (planogram "Test Vend" uses this)
    private let vendClient: PiVendClient

    init(
        machineId: String,
        service: FirestorePlanogramService = FirestorePlanogramService(),
        vendClient: PiVendClient = PiVendClient()
    ) {
        self.machineId = machineId
        self.service = service
        self.vendClient = vendClient
        self.planogram = .empty(machineId: machineId)
    }

    func load() {
        Task {
            print("[PlanogramVM] load() start for machineId=\(machineId)")
            isLoading = true
            defer {
                isLoading = false
                print("[PlanogramVM] load() done")
            }
            do {
                let loaded = try await service.load(machineId: machineId)
                self.planogram = loaded
                print("[PlanogramVM] load() success: slots=\(loaded.allSlots.count) motors=\(loaded.motors.count)")
            } catch PlanogramServiceError.notFound {
                self.errorText = nil
                print("[PlanogramVM] load() notFound, keeping template")
            } catch {
                self.errorText = error.localizedDescription
                print("[PlanogramVM] load() error: \(error.localizedDescription)")
            }
        }
    }

    func save() {
        if let err = validate() {
            self.errorText = err
            print("[PlanogramVM] save() validation failed: \(err)")
            return
        }

        if let s01 = planogram.allSlots.first(where: { $0.slotId.uppercased() == "S01" }) {
            print("[PlanogramVM] Will save snapshot for S01 -> enabled=\(s01.enabled) inv=\(s01.inventory) name=\(s01.product?.name ?? "<nil>") price=\(s01.product?.priceCents ?? -1) motorId=\(s01.motor.motorId)")
        } else if let first = planogram.allSlots.first {
            print("[PlanogramVM] Will save snapshot for FIRST(\(first.slotId)) -> enabled=\(first.enabled) inv=\(first.inventory) name=\(first.product?.name ?? "<nil>") price=\(first.product?.priceCents ?? -1) motorId=\(first.motor.motorId)")
        } else {
            print("[PlanogramVM] Will save: no slots in current planogram")
        }

        Task {
            print("[PlanogramVM] save() start with slots: \(planogram.allSlots.count), motors: \(planogram.motors.count)")
            isSaving = true
            defer {
                isSaving = false
                print("[PlanogramVM] save() done")
            }
            do {
                try await service.save(machineId: machineId, planogram: planogram)
                self.errorText = nil
                print("[PlanogramVM] save() success")
            } catch {
                self.errorText = error.localizedDescription
                print("[PlanogramVM] save() error: \(error.localizedDescription)")
            }
        }
    }

    // ✅ Test Vend now uses the slot's Firestore i2c.mask instead of slotId string.
    func testVend(slotId: String) {
        Task {
            isVending = true
            defer { isVending = false }

            // Optional: guard against vending disabled slot
            if let slot = planogram.allSlots.first(where: { $0.slotId == slotId }), slot.enabled == false {
                self.errorText = "Slot \(slotId) is disabled."
                print("[PlanogramVM] testVend blocked: slot disabled \(slotId)")
                return
            }

            guard let slot = planogram.allSlots.first(where: { $0.slotId == slotId }) else {
                self.errorText = "Slot \(slotId) not found."
                print("[PlanogramVM] testVend error: slot not found \(slotId)")
                return
            }

            // Unwrap i2c and mask safely
            guard let i2c = slot.i2c, let mask = i2c.mask else {
                self.errorText = "Slot \(slotId) is missing i2c.mask in Firestore."
                print("[PlanogramVM] testVend blocked: missing i2c.mask for \(slotId)")
                return
            }

            print("[PlanogramVM] testVend start for slotId=\(slotId) using mask=\(mask)")
            do {
                try await vendClient.testVend(mask: mask, pulseSeconds: 2.0)
                print("[PlanogramVM] testVend success for slotId=\(slotId) mask=\(mask)")
            } catch {
                self.errorText = error.localizedDescription
                print("[PlanogramVM] testVend error: \(error.localizedDescription)")
            }
        }
    }

    private func validate() -> String? {
        let all = planogram.allSlots
        let ids = all.map { $0.slotId.trimmingCharacters(in: .whitespacesAndNewlines) }
        if ids.contains(where: { $0.isEmpty }) { return "All slots must have a Slot ID." }
        if Set(ids).count != ids.count { return "Duplicate Slot IDs found." }

        if all.contains(where: { $0.motor.motorId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "All slots must have a Motor ID."
        }

        for s in all {
            if let p = s.product?.priceCents, p < 0 { return "Price must be non-negative." }
            if s.inventory < 0 { return "Inventory must be non-negative." }
        }
        return nil
    }
}

struct PlanogramView: View {
    @StateObject private var vm = PlanogramViewModel(machineId: "machine_001")
    @State private var segment: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if let error = vm.errorText {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            Picker("", selection: $segment) {
                Text("Grid").tag(0)
                Text("List").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if vm.isLoading {
                ProgressView("Loading planogram…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle("Planogram")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    print("[PlanogramView] Toolbar Save tapped")
                    vm.save()
                } label: {
                    if vm.isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(vm.isSaving || vm.isVending)
            }
        }
        .onAppear {
            print("[PlanogramView] onAppear -> load()")
            vm.load()
        }
        .sheet(isPresented: Binding(
            get: { vm.selectedSlotId != nil },
            set: { isPresented in
                if !isPresented { vm.selectedSlotId = nil }
            }
        )) {
            if let slotId = vm.selectedSlotId,
               let idx = vm.planogram.shelves.first?.slots.firstIndex(where: { $0.slotId == slotId }) {
                NavigationView {
                    SlotDetailView(
                        slot: $vm.planogram.shelves[0].slots[idx],
                        isVending: vm.isVending,
                        onTestVend: { sid in vm.testVend(slotId: sid) }
                    )
                }
            } else {
                Text("Slot not found.")
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case 0:
            PlanogramGridView(planogram: $vm.planogram, selectedSlotId: $vm.selectedSlotId)
        default:
            listEditor
        }
    }

    private var listEditor: some View {
        List {
            Section(header: Text("Machine")) {
                Text(vm.planogram.name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("ID: \(vm.planogram.machineId)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Slots")) {
                if let shelf = vm.planogram.shelves.first {
                    ForEach(shelf.slots) { slot in
                        Button {
                            print("[PlanogramView] Slot tapped: \(slot.slotId)")
                            vm.selectedSlotId = slot.slotId
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(slot.slotId)
                                        .font(.headline)
                                    Text(slot.product?.name.isEmpty == false ? slot.product!.name : "Empty")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("$\(String(format: "%.2f", Double(slot.product?.priceCents ?? 0)/100.0))")
                                        .font(.caption)
                                    Text("Inv: \(slot.inventory)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text("No shelf defined.")
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Motors")) {
                if vm.planogram.motors.isEmpty {
                    Text("Motors are currently derived from slots for MVP.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(vm.planogram.motors) { motor in
                        HStack {
                            Text(motor.motorId)
                            Spacer()
                            switch motor.address {
                            case .gpio(let addr):
                                Text("GPIO \(addr.pin)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

#Preview("PlanogramView Preview") {
    NavigationStack {
        PlanogramView()
    }
}
