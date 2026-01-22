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

// MARK: - Firestore Per-Slot Document Model
struct SlotPlanogramDoc: Equatable, Identifiable {
    var id: String { slotId }

    // Required MVP fields
    let slotId: String
    let enabled: Bool
    let inventory: Int
    let product: ProductDoc?
    let motorId: String

    // Optional positional fields
    let row: Int?
    let col: Int?

    // Optional I2C metadata
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
        let channel: Int?   // tolerate if present
    }

    init?(documentID: String, data: [String: Any], machineId: String, collectionPath: String) {
        // slotId (accept snake_case and camelCase; fallback to doc id)
        let sid =
            Self.coerceString(data["slotId"])
            ?? Self.coerceString(data["slot_id"])
            ?? documentID

        let trimmedSid = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSid.isEmpty else { return nil }
        self.slotId = trimmedSid

        // enabled
        self.enabled = Self.coerceBool(data["enabled"]) ?? true

        // inventory
        self.inventory = Self.coerceInt(data["inventory"]) ?? 0

        // product (accept snake_case + camelCase)
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

        // motorId (accept snake_case and camelCase; allow nested "motor" map too)
        if let mid = Self.coerceString(data["motorId"]) ?? Self.coerceString(data["motor_id"]) {
            self.motorId = mid
        } else if let motorMap = data["motor"] as? [String: Any],
                  let mid = Self.coerceString(motorMap["motorId"]) ?? Self.coerceString(motorMap["motor_id"]) ?? Self.coerceString(motorMap["id"]) {
            self.motorId = mid
        } else {
            self.motorId = ""
            print("[PlanogramService] Warning: missing motorId for doc \(documentID) in \(collectionPath) (machineId=\(machineId))")
        }

        // row/col
        self.row = Self.coerceInt(data["row"])
        self.col = Self.coerceInt(data["col"])

        // i2c (accept channel too if present)
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

    // Encoding back to Firestore (strict camelCase)
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "slotId": slotId,
            "enabled": enabled,
            "inventory": inventory,
            "motorId": motorId
        ]
        if let product {
            dict["product"] = [
                "productId": product.productId,
                "name": product.name,
                "priceCents": product.priceCents
            ]
        }
        if let row { dict["row"] = row }
        if let col { dict["col"] = col }
        if let i2c {
            var i2cDict: [String: Any] = [:]
            if let mask = i2c.mask { i2cDict["mask"] = mask }
            if let bus = i2c.bus { i2cDict["bus"] = bus }
            if let channel = i2c.channel { i2cDict["channel"] = channel }
            if let address = i2c.address, !address.isEmpty { i2cDict["address"] = address }
            if !i2cDict.isEmpty { dict["i2c"] = i2cDict }
        }
        return dict
    }

    // MARK: - Coercion helpers (Firestore-safe)

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

// MARK: - Inventory Document Model (snake_case)
struct InventoryDoc: Equatable, Identifiable {
    var id: String { slotId }

    let slotId: String
    let enabled: Bool?
    let qty: Int?
    let priceCents: Int?
    let skuId: String?
    let capacity: Int?

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
        self.priceCents =
            SlotPlanogramDoc.coerceInt(data["price_cents"])
            ?? SlotPlanogramDoc.coerceInt(data["priceCents"])
        self.skuId = SlotPlanogramDoc.coerceString(data["sku_id"]) ?? SlotPlanogramDoc.coerceString(data["skuId"])
        self.capacity = SlotPlanogramDoc.coerceInt(data["capacity"])

        if self.qty == nil && self.priceCents == nil && self.skuId == nil && self.enabled == nil && self.capacity == nil {
            print("[PlanogramService] Warning: empty inventory doc for \(documentID) in \(collectionPath) (machineId=\(machineId))")
        }
    }
}

// MARK: - Service (subcollection-based)
final class FirestorePlanogramService {
    private let db: Firestore
    private let machines = "machines"
    private let slotsCollection = "planogramSlots"
    private let inventoryCollection = "inventory"

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func load(machineId: String) async throws -> Planogram {
        let slotsRef = db.collection(machines)
            .document(machineId)
            .collection(slotsCollection)
        let inventoryRef = db.collection(machines)
            .document(machineId)
            .collection(inventoryCollection)

        do {
            async let slotsSnapshot = slotsRef.getDocuments()
            async let inventorySnapshot = inventoryRef.getDocuments()

            let slotsDocs = try await slotsSnapshot
            let inventoryDocs = try await inventorySnapshot

            print("[PlanogramService] load() fetched \(slotsDocs.documents.count) planogramSlots docs for machineId=\(machineId)")
            if slotsDocs.documents.isEmpty {
                throw PlanogramServiceError.notFound
            }

            var decodedDocs: [SlotPlanogramDoc] = []
            decodedDocs.reserveCapacity(slotsDocs.documents.count)

            for doc in slotsDocs.documents {
                let data = doc.data()
                if let slotDoc = SlotPlanogramDoc(
                    documentID: doc.documentID,
                    data: data,
                    machineId: machineId,
                    collectionPath: "\(machines)/\(machineId)/\(slotsCollection)"
                ) {
                    decodedDocs.append(slotDoc)
                } else {
                    print("[PlanogramService] Decode failed for machineId=\(machineId) path=\(machines)/\(machineId)/\(slotsCollection) docId=\(doc.documentID)")
                    Self.logTypes(for: data)
                }
            }

            if decodedDocs.isEmpty {
                throw PlanogramServiceError.decodingFailed
            }

            let inventoryBySlotId = Self.decodeInventoryDocs(
                docs: inventoryDocs.documents,
                machineId: machineId,
                collectionPath: "\(machines)/\(machineId)/\(inventoryCollection)"
            )

            decodedDocs.sort { a, b in
                if let ar = a.row, let ac = a.col, let br = b.row, let bc = b.col {
                    if ar != br { return ar < br }
                    return ac < bc
                } else {
                    return a.slotId.localizedStandardCompare(b.slotId) == .orderedAscending
                }
            }

            let canonicalSlots: [Slot] = decodedDocs.map { d in
                let product: Product?
                if let p = d.product, !(p.productId.isEmpty && p.name.isEmpty && p.priceCents == 0) {
                    product = Product(productId: p.productId, name: p.name, priceCents: p.priceCents)
                } else {
                    product = nil
                }

                let i2c: SlotI2C?
                if let i = d.i2c, (i.mask != nil || i.bus != nil || (i.address?.isEmpty == false)) {
                    // SlotI2C in your app currently supports (mask,bus,address). Channel is ignored for now.
                    i2c = SlotI2C(mask: i.mask, bus: i.bus, address: i.address)
                } else {
                    i2c = nil
                }

                var slot = Slot(
                    slotId: d.slotId,
                    enabled: d.enabled,
                    inventory: d.inventory,
                    product: product,
                    motor: SlotMotor(motorId: d.motorId),
                    i2c: i2c
                )

                if let inventoryDoc = inventoryBySlotId[slot.slotId] {
                    slot.enabled = inventoryDoc.enabled ?? slot.enabled
                    slot.inventory = inventoryDoc.qty ?? slot.inventory
                    let existingName = slot.product?.name ?? ""
                    let productId = inventoryDoc.skuId ?? slot.product?.productId ?? ""
                    let priceCents = inventoryDoc.priceCents ?? slot.product?.priceCents ?? 0
                    if productId.isEmpty && existingName.isEmpty && priceCents == 0 {
                        slot.product = nil
                    } else {
                        slot.product = Product(
                            productId: productId,
                            name: existingName,
                            priceCents: priceCents
                        )
                    }
                }

                return slot
            }

            // 🔎 Helpful one-time debug (safe to keep during MVP)
            if let s01 = canonicalSlots.first(where: { $0.slotId.uppercased() == "S01" }) {
                print("[PlanogramService] S01 i2c=\(String(describing: s01.i2c)) mask=\(String(describing: s01.i2c?.mask))")
            }

            let shelf = Shelf(shelfId: "S1", type: "coil", name: "Shelf 1", slots: canonicalSlots)

            let uniqueMotorIds = Array(Set(canonicalSlots.map { $0.motor.motorId })).sorted()
            let motors: [Motor] = uniqueMotorIds.map { mid in
                Motor.gpio(motorId: mid, pin: 0, activeHigh: true, pulseSeconds: 2.0)
            }

            let planogram = Planogram(
                schemaVersion: 1,
                machineId: machineId,
                name: "Machine \(machineId)",
                motors: motors,
                shelves: [shelf]
            )

            return planogram
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

            var planogramDict: [String: Any] = [
                "slot_id": slot.slotId,
                "motor_id": slot.motor.motorId
            ]

            if let row { planogramDict["row"] = row }
            if let col { planogramDict["col"] = col }

            if let i2c = slot.i2c {
                var i2cDict: [String: Any] = [:]
                if let mask = i2c.mask { i2cDict["mask"] = mask }
                if let bus = i2c.bus { i2cDict["bus"] = bus }
                if let addr = i2c.address, !addr.isEmpty { i2cDict["address"] = addr }
                if !i2cDict.isEmpty { planogramDict["i2c"] = i2cDict }
            }

            let slotDoc = slotsRef.document(slot.slotId)
            batch.setData(planogramDict, forDocument: slotDoc, merge: true)
            print("[PlanogramService] Will write \(machines)/\(machineId)/\(slotsCollection)/\(slot.slotId) -> \(planogramDict)")

            var inventoryDict: [String: Any] = [
                "slot_id": slot.slotId,
                "enabled": slot.enabled,
                "qty": slot.inventory
            ]

            if let p = slot.product, !(p.productId.isEmpty && p.name.isEmpty && p.priceCents == 0) {
                inventoryDict["sku_id"] = p.productId
                inventoryDict["price_cents"] = p.priceCents
            }

            let inventoryDoc = inventoryRef.document(slot.slotId)
            batch.setData(inventoryDict, forDocument: inventoryDoc, merge: true)
            print("[PlanogramService] Will write \(machines)/\(machineId)/\(inventoryCollection)/\(slot.slotId) -> \(inventoryDict)")
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

    private static func logTypes(for data: [String: Any]) {
        var lines: [String] = []
        for (k, v) in data {
            lines.append("  \(k): \(type(of: v)) -> \(v)")
        }
        print("[PlanogramService] Raw doc data types:\n" + lines.sorted().joined(separator: "\n"))
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
            if let inventoryDoc = InventoryDoc(
                documentID: doc.documentID,
                data: data,
                machineId: machineId,
                collectionPath: collectionPath
            ) {
                output[inventoryDoc.slotId] = inventoryDoc
            } else {
                print("[PlanogramService] Decode failed for inventory doc machineId=\(machineId) path=\(collectionPath) docId=\(doc.documentID)")
                logTypes(for: data)
            }
        }

        return output
    }
}
