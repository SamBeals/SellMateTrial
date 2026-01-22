import Foundation

struct Planogram: Codable, Equatable, Identifiable {
    var id: String { machineId }
    var schemaVersion: Int
    var machineId: String
    var name: String
    var motors: [Motor]
    var shelves: [Shelf]

    static func empty(machineId: String) -> Planogram {
        // Fixed template: 20 slots S01..S20 (4 rows x 5 cols)
        let slotIds: [String] = (1...20).map { String(format: "S%02d", $0) }

        var slots: [Slot] = []
        var motors: [Motor] = []

        // Placeholder pins 1..20 (MVP only)
        for (idx, slotId) in slotIds.enumerated() {
            let motorId = slotId // derived identity for MVP

            let slot = Slot(
                slotId: slotId,
                enabled: true,
                inventory: 0,
                product: Product(productId: "", name: "", priceCents: 0),
                motor: SlotMotor(motorId: motorId),
                i2c: nil
            )
            slots.append(slot)

            let motor = Motor.gpio(
                motorId: motorId,
                pin: idx + 1,
                activeHigh: true,
                pulseSeconds: 3.0
            )
            motors.append(motor)
        }

        let shelf = Shelf(shelfId: "S1", type: "coil", name: "Shelf 1", slots: slots)

        return Planogram(
            schemaVersion: 1,
            machineId: machineId,
            name: "Machine \(machineId)",
            motors: motors,
            shelves: [shelf]
        )
    }

    var allSlots: [Slot] {
        shelves.flatMap { $0.slots }
    }
}

struct Shelf: Codable, Equatable, Identifiable {
    var id: String { shelfId }
    var shelfId: String
    var type: String
    var name: String
    var slots: [Slot]
}

struct Slot: Codable, Equatable, Identifiable {
    var id: String { slotId }
    var slotId: String
    var enabled: Bool
    var inventory: Int
    var product: Product?
    var motor: SlotMotor
    var i2c: SlotI2C? // Optional I2C metadata for vending masks/bus/address

    static func new(slotId: String) -> Slot {
        Slot(
            slotId: slotId,
            enabled: true,
            inventory: 0,
            product: Product(productId: "", name: "", priceCents: 0),
            motor: SlotMotor(motorId: slotId),
            i2c: nil
        )
    }
}

struct SlotI2C: Codable, Equatable {
    var mask: Int?
    var bus: Int?
    var address: String?
}

struct Product: Codable, Equatable {
    var productId: String
    var name: String
    var priceCents: Int
}

struct SlotMotor: Codable, Equatable {
    var motorId: String
}

struct Motor: Codable, Equatable, Identifiable {
    var id: String { motorId }
    var motorId: String
    var driver: MotorDriver
    var address: MotorAddress
    var pulseSeconds: Double

    static func gpio(motorId: String, pin: Int, activeHigh: Bool = true, pulseSeconds: Double = 3.0) -> Motor {
        Motor(motorId: motorId, driver: .gpio, address: .gpio(GPIOAddress(pin: pin, activeHigh: activeHigh)), pulseSeconds: pulseSeconds)
    }
}

enum MotorDriver: String, Codable {
    case gpio
}

enum MotorAddress: Codable, Equatable {
    case gpio(GPIOAddress)

    enum CodingKeys: String, CodingKey { case type, value }
    enum AddressType: String, Codable { case gpio }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gpio(let addr):
            try container.encode(AddressType.gpio, forKey: .type)
            try container.encode(addr, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AddressType.self, forKey: .type)
        switch type {
        case .gpio:
            let addr = try container.decode(GPIOAddress.self, forKey: .value)
            self = .gpio(addr)
        }
    }
}

struct GPIOAddress: Codable, Equatable {
    var pin: Int
    var activeHigh: Bool
}
