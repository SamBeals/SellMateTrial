import Foundation
import FirebaseFirestore

// MARK: - Errors
enum PlanogramServiceError: LocalizedError {
    case notFound
    case decodingFailed
    case encodingFailed
    case firestore(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Planogram document(s) not found."
        case .decodingFailed: return "Failed to decode planogram."
        case .encodingFailed: return "Failed to encode planogram."
        case .firestore(let msg): return "Firestore error: \(msg)"
        }
    }
}

// MARK: - Firestore Per-Slot Planogram Document Model
// NOTE: In your current schema split, planogramSlots is primarily wiring/position (motor/i2c/row/col).
// We still decode enabled/inventory/product defensively, but inventory is the source of truth for name/qty/price.
struct SlotPlanogramDoc: Equatable, Identifiable {
    var id: String { slotId }

    let slotId: String
    let enabled: Bool
    let inventory: Int
    let product: ProductDoc?
    let motorId: String

    let row: Int?
    let col: Int?

    let i2c: I2CDoc?

    struct ProductDoc: Equatable {
        let productId: String
        let name: String
        let priceCents: Int
    }

    struct I2CDoc: Equatable {
        let mask: Int?
        let bus: Int?
        let address: String?
        let channel: Int?
    }

    init?(documentID: String, data: [String: Any], machineId: String, collectionPath: String) {
        let sid =
            Self.coerceString(data["slotId"])
            ?? Self.coerceString(data["slot_id"])
            ?? documentID

        let trimmedSid = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSid.isEmpty else { return nil }
        self.slotId = trimmedSid

        self.enabled = Self.coerceBool(data["enabled"]) ?? true
        self.inventory = Self.coerceInt(data["inventory"]) ?? 0

        if let prodAny = data["product"] as? [String: Any] {
            let pid =
                Self.coerceString(prodAny["productId"])
                ?? Self.coerceString(prodAny["product_id"])
                ?? ""

            let name =
                Self.coerceString(prodAny["name"])
                ?? ""

            let price =
                Self.coerceInt(prodAny["priceCents"])
                ?? Self.coerceInt(prodAny["price_cents"])
                ?? 0

            if pid.isEmpty && name.isEmpty && price == 0 {
                self.product = nil
            } else {
                self.product = ProductDoc(productId: pid, name: name, priceCents: price)
            }
        } else {
            self.product = nil
        }

        // motorId MUST exist for vending
        if let mid = Self.coerceString(data["motorId"]) ?? Self.coerceString(data["motor_id"]) {
            self.motorId = mid
        } else if let motorMap = data["motor"] as? [String: Any],
                  let mid =
                    Self.coerceString(motorMap["motorId"])
                    ?? Self.coerceString(motorMap["motor_id"])
                    ?? Self.coerceString(motorMap["id"]) {
            self.motorId = mid
        } else {
            print("[PlanogramService] ERROR: missing motorId for doc \(documentID) in \(collectionPath) (machineId=\(machineId))")
            return nil
        }

        self.row = Self.coerceInt(data["row"])
        self.col = Self.coerceInt(data["col"])

        if let i2cAny = data["i2c"] as? [String: Any] {
            let mask = Self.coerceInt(i2cAny["mask"])
            let bus = Self.coerceInt(i2cAny["bus"])
            let channel = Self.coerceInt(i2cAny["channel"])
            let address = Self.coerceString(i2cAny["address"])

            if mask == nil && bus == nil && channel == nil && (address == nil || address?.isEmpty == true) {
                self.i2c = nil
            } else {
                self.i2c = I2CDoc(mask: mask, bus: bus, address: address, channel: channel)
            }
        } else {
            self.i2c = nil
        }
    }

    // MARK: - Coercion helpers
    static func coerceBool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool:
            return b
        case let n as NSNumber:
            return n.intValue != 0
        case let s as String:
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "t", "yes", "y", "1"].contains(lower) { return true }
            if ["false", "f", "no", "n", "0"].contains(lower) { return false }
            return nil
        default:
            return nil
        }
    }

    static func coerceString(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    static func coerceInt(_ any: Any?) -> Int? {
        switch any {
        case let i as Int:
            return i
        case let i64 as Int64:
            return Int(i64)
        case let d as Double:
            return Int(d)
        case let n as NSNumber:
            return n.intValue
        case let s as String:
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if cleaned.hasPrefix("0x") {
                return Int(cleaned.dropFirst(2), radix: 16)
            }
            return Int(cleaned)
        default:
            return nil
        }
    }
}

// MARK: - Inventory Document Model (subcollection)
// This is where your editable "name" must live for Option A.
struct InventoryDoc: Equatable, Identifiable {
    var id: String { slotId }

    let slotId: String
    let enabled: Bool?
    let qty: Int?
    let priceCents: Int?
    let skuId: String?
    let capacity: Int?
    let name: String?   // ✅ the field you added

    init?(documentID: String, data: [String: Any], machineId: String, collectionPath: String) {
        let sid =
            SlotPlanogramDoc.coerceString(data["slot_id"])
            ?? SlotPlanogramDoc.coerceString(data["slotId"])
            ?? documentID

        let trimmedSid = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSid.isEmpty else { return nil }
        self.slotId = trimmedSid

        self.enabled = SlotPlanogramDoc.coerceBool(data["enabled"])
        self.qty = SlotPlanogramDoc.coerceInt(data["qty"]) ?? SlotPlanogramDoc.coerceInt(data["inventory"])
        self.priceCents = SlotPlanogramDoc.coerceInt(data["price_cents"]) ?? SlotPlanogramDoc.coerceInt(data["priceCents"])
        self.skuId = SlotPlanogramDoc.coerceString(data["sku_id"]) ?? SlotPlanogramDoc.coerceString(data["skuId"])
        self.capacity = SlotPlanogramDoc.coerceInt(data["capacity"])
        self.name = SlotPlanogramDoc.coerceString(data["name"]) ?? SlotPlanogramDoc.coerceString(data["product_name"])

        if self.enabled == nil, self.qty == nil, self.priceCents == nil, self.skuId == nil, self.capacity == nil, self.name == nil {
            print("[PlanogramService] Warning: empty inventory doc for \(documentID) in \(collectionPath) (machineId=\(machineId))")
        }
    }
}

// MARK: - Service (planogramSlots + inventory)
final class FirestorePlanogramService {
    private let db: Firestore
    private let machines = "machines"
    private let slotsCollection = "planogramSlots"
    private let inventoryCollection = "inventory"

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func load(machineId: String) async throws -> Planogram {
        let machineRef = db.collection(machines).document(machineId)
        let slotsRef = machineRef.collection(slotsCollection)
        let inventoryRef = machineRef.collection(inventoryCollection)

        do {
            async let slotsSnapshot = slotsRef.getDocuments()
            async let inventorySnapshot = inventoryRef.getDocuments()

            let slotsDocs = try await slotsSnapshot
            let inventoryDocs = try await inventorySnapshot

            print("[PlanogramService] load() fetched \(slotsDocs.documents.count) planogramSlots docs and \(inventoryDocs.documents.count) inventory docs for machineId=\(machineId)")

            if slotsDocs.documents.isEmpty {
                throw PlanogramServiceError.notFound
            }

            var decodedSlots: [SlotPlanogramDoc] = []
            decodedSlots.reserveCapacity(slotsDocs.documents.count)

            for doc in slotsDocs.documents {
                let data = doc.data()
                if let slotDoc = SlotPlanogramDoc(
                    documentID: doc.documentID,
                    data: data,
                    machineId: machineId,
                    collectionPath: "\(machines)/\(machineId)/\(slotsCollection)"
                ) {
                    decodedSlots.append(slotDoc)
                } else {
                    print("[PlanogramService] Decode failed for slot doc machineId=\(machineId) path=\(machines)/\(machineId)/\(slotsCollection) docId=\(doc.documentID)")
                    Self.logTypes(for: data)
                }
            }

            if decodedSlots.isEmpty {
                throw PlanogramServiceError.decodingFailed
            }

            let inventoryBySlotId = Self.decodeInventoryDocs(
                docs: inventoryDocs.documents,
                machineId: machineId,
                collectionPath: "\(machines)/\(machineId)/\(inventoryCollection)"
            )

            decodedSlots.sort { a, b in
                if let ar = a.row, let ac = a.col, let br = b.row, let bc = b.col {
                    if ar != br { return ar < br }
                    return ac < bc
                }
                return a.slotId.localizedStandardCompare(b.slotId) == .orderedAscending
            }

            let canonicalSlots: [Slot] = decodedSlots.map { d in
                // Start with what's in planogramSlots
                let initialProduct: Product?
                if let p = d.product, !(p.productId.isEmpty && p.name.isEmpty && p.priceCents == 0) {
                    initialProduct = Product(productId: p.productId, name: p.name, priceCents: p.priceCents)
                } else {
                    initialProduct = nil
                }

                let i2c: SlotI2C?
                if let i = d.i2c, (i.mask != nil || i.bus != nil || (i.address?.isEmpty == false)) {
                    i2c = SlotI2C(mask: i.mask, bus: i.bus, address: i.address)
                } else {
                    i2c = nil
                }

                var slot = Slot(
                    slotId: d.slotId,
                    enabled: d.enabled,
                    inventory: d.inventory,
                    product: initialProduct,
                    motor: SlotMotor(motorId: d.motorId),
                    i2c: i2c
                )

                // Merge inventory doc (Option A: name is stored in inventory)
                if let inv = inventoryBySlotId[slot.slotId] {
                    slot.enabled = inv.enabled ?? slot.enabled
                    slot.inventory = inv.qty ?? slot.inventory

                    let mergedName = (inv.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? slot.product?.name
                        ?? ""

                    let mergedSku = inv.skuId ?? slot.product?.productId ?? ""
                    let mergedPrice = inv.priceCents ?? slot.product?.priceCents ?? 0

                    // Keep product if any meaningful field exists (name/sku/price)
                    if mergedName.isEmpty && mergedSku.isEmpty && mergedPrice == 0 {
                        slot.product = nil
                    } else {
                        slot.product = Product(productId: mergedSku, name: mergedName, priceCents: mergedPrice)
                    }
                }

                return slot
            }

            let shelf = Shelf(shelfId: "S1", type: "coil", name: "Shelf 1", slots: canonicalSlots)

            // Keep this if your app expects motors to exist, but be aware pin=0 is placeholder.
            let uniqueMotorIds = Array(Set(canonicalSlots.map { $0.motor.motorId })).sorted()
            let motors: [Motor] = uniqueMotorIds.map { mid in
                Motor.gpio(motorId: mid, pin: 0, activeHigh: true, pulseSeconds: 2.0)
            }

            return Planogram(
                schemaVersion: 1,
                machineId: machineId,
                name: "Machine \(machineId)",
                motors: motors,
                shelves: [shelf]
            )
        } catch let err as PlanogramServiceError {
            throw err
        } catch {
            throw PlanogramServiceError.firestore(error.localizedDescription)
        }
    }

    func save(machineId: String, planogram: Planogram) async throws {
        let machineRef = db.collection(machines).document(machineId)
        let slotsRef = machineRef.collection(slotsCollection)
        let inventoryRef = machineRef.collection(inventoryCollection)

        let batch = db.batch()

        let slots = planogram.shelves.first?.slots ?? []
        let total = slots.count
        let hasFixedGrid = (total == 20)
        let cols = 5

        for (idx, slot) in slots.enumerated() {
            let row: Int?
            let col: Int?
            if hasFixedGrid {
                row = idx / cols
                col = idx % cols
            } else {
                row = nil
                col = nil
            }

            // 1) Write planogramSlots doc (mapping/wiring/position)
            var slotDict: [String: Any] = [
                "slot_id": slot.slotId,
                "motor_id": slot.motor.motorId
            ]
            if let row { slotDict["row"] = row }
            if let col { slotDict["col"] = col }

            if let i2c = slot.i2c {
                var i2cDict: [String: Any] = [:]
                if let mask = i2c.mask { i2cDict["mask"] = mask }
                if let bus = i2c.bus { i2cDict["bus"] = bus }
                if let addr = i2c.address, !addr.isEmpty { i2cDict["address"] = addr }
                if !i2cDict.isEmpty { slotDict["i2c"] = i2cDict }
            }

            let slotDoc = slotsRef.document(slot.slotId)
            let debugName = slot.product?.name ?? "(nil product)"
            print("[PlanogramService] save() slot=\(slot.slotId) productName=\(debugName)")

            batch.setData(slotDict, forDocument: slotDoc, merge: true)

            // 2) Write inventory doc (this is where Option A "name" must be saved)
            var invDict: [String: Any] = [
                "slot_id": slot.slotId,
                "enabled": slot.enabled,
                "qty": slot.inventory
            ]

            if let p = slot.product {
                let trimmedName = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    invDict["name"] = trimmedName          // ✅ persist name
                }
                if !p.productId.isEmpty {
                    invDict["sku_id"] = p.productId
                }
                // Write price even if 0 if you want explicitness; otherwise keep your existing rule.
                invDict["price_cents"] = p.priceCents
            }

            // Debug print AFTER invDict is constructed
            print("[PlanogramService] writing inventory path machines/\(machineId)/inventory/\(slot.slotId) payload=\(invDict)")

            let invDoc = inventoryRef.document(slot.slotId)
            batch.setData(invDict, forDocument: invDoc, merge: true)
        }

        batch.setData(
            ["updated_at": FieldValue.serverTimestamp()],
            forDocument: machineRef,
            merge: true
        )

        do {
            try await batch.commit()
            print("[PlanogramService] Batch commit success for machineId=\(machineId)")
        } catch {
            print("[PlanogramService] Batch commit failed for machineId=\(machineId): \(error)")
            throw PlanogramServiceError.firestore(error.localizedDescription)
        }
    }

    private static func decodeInventoryDocs(
        docs: [QueryDocumentSnapshot],
        machineId: String,
        collectionPath: String
    ) -> [String: InventoryDoc] {
        var output: [String: InventoryDoc] = [:]
        output.reserveCapacity(docs.count)

        for doc in docs {
            let data = doc.data()
            if let inv = InventoryDoc(
                documentID: doc.documentID,
                data: data,
                machineId: machineId,
                collectionPath: collectionPath
            ) {
                output[inv.slotId] = inv
            } else {
                print("[PlanogramService] Decode failed for inventory doc machineId=\(machineId) path=\(collectionPath) docId=\(doc.documentID)")
                logTypes(for: data)
            }
        }

        return output
    }

    private static func logTypes(for data: [String: Any]) {
        var lines: [String] = []
        for (k, v) in data {
            lines.append("  \(k): \(type(of: v)) -> \(v)")
        }
        print("[PlanogramService] Raw doc data types:\n" + lines.sorted().joined(separator: "\n"))
    }
}
