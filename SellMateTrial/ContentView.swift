import SwiftUI
import Combine
import StripeTerminal
import CoreBluetooth

// MARK: - Google Cloud backend trigger (prototype-only)
// NOTE: This is intentionally lightweight in SellMateTrial so we can mirror Android/Kotlin
// payment->backend behavior without over-hardening this prototype.
private struct CloudBackendService {
    struct TriggerResult {
        let statusCode: Int
        let responseText: String
    }

    enum TriggerError: LocalizedError {
        case missingBaseURL
        case invalidBaseURL(String)
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL:
                return "Missing CLOUD_BACKEND_BASE_URL in Info.plist."
            case .invalidBaseURL(let value):
                return "Invalid CLOUD_BACKEND_BASE_URL: \(value)"
            case .requestFailed(let reason):
                return reason
            }
        }
    }

    private let session = URLSession.shared

    func triggerVend(paymentIntent: PaymentIntent, reader: Reader?, slotId: String, pulseSeconds: Double) async throws -> TriggerResult {
        guard let baseURLValue = Bundle.main.object(forInfoDictionaryKey: "CLOUD_BACKEND_BASE_URL") as? String,
              !baseURLValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TriggerError.missingBaseURL
        }

        guard let baseURL = URL(string: baseURLValue) else {
            throw TriggerError.invalidBaseURL(baseURLValue)
        }

        let path = (Bundle.main.object(forInfoDictionaryKey: "CLOUD_BACKEND_VEND_PATH") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let vendPath = (path?.isEmpty == false ? path! : "vend")

        let url = baseURL.appendingPathComponent(vendPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = Bundle.main.object(forInfoDictionaryKey: "CLOUD_BACKEND_API_KEY") as? String, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let payload: [String: Any] = [
            "source": "sellmate_ios_prototype",
            "payment_intent_id": paymentIntent.stripeId,
            "amount": paymentIntent.amount,
            "currency": paymentIntent.currency,
            "reader_serial_number": reader?.serialNumber ?? "",
            "reader_device_type": reader.map { String(describing: $0.deviceType) } ?? "unknown",
            "slot_id": slotId,
            "pulse_seconds": pulseSeconds
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8>"

        guard (200..<300).contains(statusCode) else {
            throw TriggerError.requestFailed("Cloud backend failed (\(statusCode)): \(responseText)")
        }

        return TriggerResult(statusCode: statusCode, responseText: responseText)
    }
}

// MARK: - Bluetooth Permission Manager
final class BluetoothPermissionManager: NSObject, ObservableObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    @Published private(set) var authorization: CBManagerAuthorization = {
        if #available(iOS 13.0, *) {
            return CBCentralManager.authorization
        } else {
            return .allowedAlways
        }
    }()

    func start() {
        // Initialize CBCentralManager to trigger the permission prompt if needed.
        // Keep a strong reference to self.central so it isn't deallocated.
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [
                CBCentralManagerOptionShowPowerAlertKey: true
            ])
        }
        // Access authorization to ensure the system evaluates it.
        if #available(iOS 13.0, *) {
            authorization = CBCentralManager.authorization
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if #available(iOS 13.0, *) {
            authorization = CBCentralManager.authorization
        } else {
            authorization = .allowedAlways
        }
        // You can log or react to Bluetooth state changes here if desired.
        // print("Bluetooth state: \(central.state.rawValue), auth: \(authorization.rawValue)")
    }
}

// MARK: - Backend Token Provider (Stripe Terminal 5.x)
final class BackendTokenProvider: NSObject, ConnectionTokenProvider {
    let tokenURL: URL

    init(tokenURL: URL) {
        self.tokenURL = tokenURL
        super.init()
    }

    func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(nil, error)
                return
            }
            guard let data = data else {
                completion(nil, NSError(domain: "BackendTokenProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data from token endpoint"]))
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let secret = json["secret"] as? String {
                    completion(secret, nil)
                } else {
                    completion(nil, NSError(domain: "BackendTokenProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected token response format"]))
                }
            } catch {
                completion(nil, error)
            }
        }.resume()
    }
}

// MARK: - View Model for Terminal 5.1.1
@MainActor
final class TerminalViewModel: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case discovering
        case discovered([Reader])
        case connecting(Reader)
        case connected(Reader)
        case paymentReady
        case collecting
        case processing
        case succeeded(PaymentIntent)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.discovering, .discovering),
                 (.paymentReady, .paymentReady),
                 (.collecting, .collecting),
                 (.processing, .processing):
                return true
            case (.discovered(let l), .discovered(let r)):
                return l.map(\.serialNumber) == r.map(\.serialNumber)
            case (.connecting(let l), .connecting(let r)):
                return l.serialNumber == r.serialNumber
            case (.connected(let l), .connected(let r)):
                return l.serialNumber == r.serialNumber
            case (.succeeded(let l), .succeeded(let r)):
                return l.stripeId == r.stripeId
            case (.failed(let l), .failed(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    @Published var state: State = .idle
    @Published var statusMessage: String = "Ready"
    @Published var isBusy: Bool = false

    private var discoveryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectedReader: Reader?

    // Replace with your backend endpoint for connection tokens
    private let tokenURL = URL(string: "http://192.168.0.134:4242/connection_token")!

    // You must set this to a valid Stripe Terminal Location ID for your account for real readers.
    // Leave as "" ONLY if you are using simulated readers exclusively.
    private let defaultLocationId: String = "tml_GV9bCglOApaios" // live location id

    // Test payment settings (smallest currency unit)
    private let testAmount: Int = 50 // $1.00
    private let testCurrency: String = "usd"

    // Vend API configuration (fill in your real API key)
    // NOTE: kept as prototype defaults; expected to align with SellMateCustomer config during migration.
    private let vendSlotId: String = "shelf1_lane3"
    private let vendPulseSeconds: Double = 6.0
    private let cloudBackend = CloudBackendService()

    override init() {
        super.init()
        Task { @MainActor in
            await configureTerminal()
        }
    }

    // Configure Terminal 5.x
    private func configureTerminal() async {
        if !Terminal.isInitialized() {
            let provider = BackendTokenProvider(tokenURL: tokenURL)
            Terminal.initWithTokenProvider(
                provider,
                delegate: self,
                offlineDelegate: nil,
                logLevel: LogLevel.verbose
            )
            statusMessage = "Terminal configured."
        } else {
            Terminal.shared.delegate = self
        }
    }

    func startDiscovery(simulated: Bool) {
        guard discoveryTask == nil else { return }
        isBusy = true
        state = .discovering
        statusMessage = simulated ? "Discovering simulated readers..." : "Discovering Bluetooth readers..."

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Build Bluetooth scan discovery configuration
                let builder = BluetoothScanDiscoveryConfigurationBuilder()
                    .setSimulated(simulated)
                let config = try builder.build()

                // Use async sequence discovery to stream updates
                for try await readers in Terminal.shared.discoverReaders(config) {
                    // Temporarily remove device filter to ensure we see everything
                    await MainActor.run {
                        self.state = .discovered(readers)
                    }
                }

                await MainActor.run {
                    self.isBusy = false
                    if let reader = self.connectedReader {
                        self.state = .connected(reader)
                    } else {
                        self.state = .idle
                    }
                    self.statusMessage = "Discovery finished."
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = "Discovery canceled."
                    if let reader = self.connectedReader {
                        self.state = .connected(reader)
                    } else {
                        self.state = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.state = .failed("Discovery failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run { self.discoveryTask = nil }
        }
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    func connect(to reader: Reader) {
        guard connectionTask == nil else { return }
        isBusy = true
        state = .connecting(reader)
        statusMessage = "Connecting to \(reader.serialNumber)..."

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Prefer the reader's existing location if present; otherwise use your configured one
                let locationIdToUse: String
                if let loc = reader.locationId, !loc.isEmpty {
                    locationIdToUse = loc
                } else if !self.defaultLocationId.isEmpty {
                    locationIdToUse = self.defaultLocationId
                } else {
                    throw NSError(domain: "Terminal", code: -1001, userInfo: [NSLocalizedDescriptionKey: "No Location ID. Set defaultLocationId or use a reader with a locationId."])
                }

                // Build Bluetooth connection configuration
                let connBuilder = BluetoothConnectionConfigurationBuilder(
                    delegate: self,
                    locationId: locationIdToUse
                )
                .setAutoReconnectOnUnexpectedDisconnect(true)

                let connectionConfig = try connBuilder.build()

                let connected = try await Terminal.shared.connectReader(reader, connectionConfig: connectionConfig)
                await MainActor.run {
                    self.connectedReader = connected
                    self.state = .connected(connected)
                    self.statusMessage = "Connected to \(connected.serialNumber)."
                    self.isBusy = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = "Connection canceled."
                    if let r = self.connectedReader {
                        self.state = .connected(r)
                    } else {
                        self.state = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.state = .failed("Connect failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run { self.connectionTask = nil }
        }
    }

    func disconnect() {
        guard Terminal.shared.connectedReader != nil else { return }
        isBusy = true
        statusMessage = "Disconnecting..."
        Task { @MainActor in
            do {
                try await Terminal.shared.disconnectReader()
                self.connectedReader = nil
                self.state = .idle
                self.statusMessage = "Disconnected."
            } catch {
                self.state = .failed("Disconnect failed: \(error.localizedDescription)")
            }
            self.isBusy = false
        }
    }

    func preparePayment() {
        guard Terminal.shared.connectedReader != nil else {
            statusMessage = "Connect a reader first."
            return
        }
        state = .paymentReady
        statusMessage = "Ready to collect a test payment of $\(String(format: "%.2f", Double(testAmount)/1.0))"
    }

    func collectAndProcessPayment() {
        guard Terminal.shared.connectedReader != nil else {
            statusMessage = "Connect a reader first."
            return
        }

        isBusy = true
        state = .collecting
        statusMessage = "Creating PaymentIntent..."

        Task { @MainActor in
            do {
                // Build PaymentIntentParameters using the builder API
                let paramsBuilder = PaymentIntentParametersBuilder(
                    amount: UInt(testAmount),
                    currency: testCurrency
                )
                // Optional tweaks:
                // .setCaptureMethod(.automatic)
                let params = try paramsBuilder.build()

                let intent = try await Terminal.shared.createPaymentIntent(params)

                statusMessage = "Present card on reader..."
                let collected = try await Terminal.shared.collectPaymentMethod(intent)

                state = .processing
                statusMessage = "Processing payment..."
                let processed = try await Terminal.shared.confirmPaymentIntent(collected)

                state = .succeeded(processed)
                statusMessage = "Payment succeeded"

                // Immediately trigger vend call; do not block UI
                triggerVendAfterSuccess(processed)

            } catch {
                state = .failed("Payment failed: \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    private func triggerVendAfterSuccess(_ paymentIntent: PaymentIntent) {
        // Fire-and-forget cloud call that mirrors Android/Kotlin payment success behavior.
        Task.detached { [vendSlotId, vendPulseSeconds, cloudBackend] in
            do {
                let result = try await cloudBackend.triggerVend(
                    paymentIntent: paymentIntent,
                    reader: Terminal.shared.connectedReader,
                    slotId: vendSlotId,
                    pulseSeconds: vendPulseSeconds
                )
                print("[CloudVend] Success \(result.statusCode): \(result.responseText)")
            } catch {
                print("[CloudVend] Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Delegates (Stripe Terminal 5.x)
extension TerminalViewModel: TerminalDelegate {
    func terminal(_ terminal: Terminal, didChangeConnectionStatus status: ConnectionStatus) {
        // Optional: reflect connection status changes
    }

    func terminal(_ terminal: Terminal, didReportUnexpectedReaderDisconnect reader: Reader) {
        Task { @MainActor in
            self.connectedReader = nil
            self.statusMessage = "Reader unexpectedly disconnected."
            self.state = .idle
        }
    }
}

// Discovery delegate for completion-based discovery (not used with async sequence here)
extension TerminalViewModel: DiscoveryDelegate {
    func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        // If you use the completion-based discoverReaders API, update state here.
    }
}

extension TerminalViewModel: ReaderDelegate, MobileReaderDelegate {
    func reader(_ reader: Reader, didReportAvailableUpdate update: ReaderSoftwareUpdate) {}
    func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {}
    func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {}
    func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {}
    func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions = []) {}
    func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {}

    // MobileReaderDelegate (for Bluetooth)
    func reader(_ reader: Reader, didStartReconnect cancelable: Cancelable?) {}
    func reader(_ reader: Reader, didFinishReconnect result: Result<Void, Error>) {}
}

// MARK: - UI
private func deviceTypeName(_ type: DeviceType) -> String {
    switch type {
    case .chipper2X: return "Chipper 2X"
    case .wisePad3: return "WisePad 3"
    case .stripeM2: return "Stripe Reader M2"
    case .wisePosE: return "WisePOS E"
    case .wisePosEDevKit: return "WisePOS E DevKit"
    case .etna: return "Etna"
    case .chipper1X: return "Chipper 1X"
    case .wiseCube: return "WiseCube"
    case .stripeS700: return "Stripe Reader S700"
    case .stripeS700DevKit: return "Stripe Reader S700 DevKit"
    case .stripeS710: return "Stripe Reader S710"
    case .stripeS710DevKit: return "Stripe Reader S710 DevKit"
    case .verifoneV660p: return "Verifone V660p"
    case .verifoneV660pDevKit: return "Verifone V660p DevKit"
    case .verifoneM425: return "Verifone M425"
    case .verifoneM450: return "Verifone M450"
    case .verifoneP630: return "Verifone P630"
    case .verifoneUX700: return "Verifone UX700"
    case .verifoneUX700DevKit: return "Verifone UX700 DevKit"
    case .verifoneVM100: return "Verifone VM100"
    case .verifoneVP100: return "Verifone VP100"
    case .tapToPay: return "Tap To Pay"
    case .stripeT600: return "Stripe Reader T600"
    case .stripeT600DevKit: return "Stripe Reader T600 DevKit"
    @unknown default: return "Unknown Reader"
    }
}

struct ContentView: View {
    @StateObject private var vm = TerminalViewModel()
    @StateObject private var btPermission = BluetoothPermissionManager()
    @State private var useSimulation: Bool = false // default to real Bluetooth M2

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Stripe Terminal Payment Test")
                    .font(.title2).bold()

                Toggle("Use Simulated Reader", isOn: $useSimulation)
                    .padding(.horizontal)

                Text(vm.statusMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if #available(iOS 13.0, *) {
                    Text("Bluetooth Authorization: \(String(describing: btPermissionAuthorizationString(btPermission.authorization)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                content

                Spacer()
            }
            .padding()
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if vm.isBusy { ProgressView() }
                }
            }
        }
        .onAppear {
            // Trigger Bluetooth permission prompt at launch
            btPermission.start()
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func btPermissionAuthorizationString(_ auth: CBManagerAuthorization) -> String {
        switch auth {
        case .allowedAlways: return "Allowed"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            Button {
                vm.startDiscovery(simulated: useSimulation)
            } label: {
                Label("Discover Readers", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)

        case .discovering:
            VStack(spacing: 8) {
                ProgressView("Scanning for readers...")
                Button("Cancel") { vm.cancelDiscovery() }
                    .buttonStyle(.bordered)
            }

        case .discovered(let readers):
            if readers.isEmpty {
                Text("No readers found.")
                Button("Rescan") { vm.startDiscovery(simulated: useSimulation) }
                    .buttonStyle(.bordered)
            } else {
                List(readers, id: \.serialNumber) { reader in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(deviceTypeName(reader.deviceType))
                            Text(reader.serialNumber)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Connect") { vm.connect(to: reader) }
                    }
                }
                .frame(maxHeight: 280)
                Button("Rescan") { vm.startDiscovery(simulated: useSimulation) }
                    .buttonStyle(.bordered)
            }

        case .connecting(let reader):
            VStack(spacing: 8) {
                ProgressView("Connecting to \(reader.serialNumber)...")
                Button("Cancel") { vm.cancelDiscovery() } // No direct cancel-connect; discovery cancel is safe
                    .buttonStyle(.bordered)
            }

        case .connected(let reader):
            VStack(spacing: 8) {
                Text("Connected to \(deviceTypeName(reader.deviceType)) \(reader.serialNumber)")
                HStack {
                    Button("Prepare $1.00 Payment") { vm.preparePayment() }
                        .buttonStyle(.borderedProminent)
                    Button("Disconnect") { vm.disconnect() }
                        .buttonStyle(.bordered)
                }
            }

        case .paymentReady:
            VStack(spacing: 8) {
                Text("Ready to collect $1.00")
                Button("Collect and Process") { vm.collectAndProcessPayment() }
                    .buttonStyle(.borderedProminent)
                Button("Back") {
                    if let reader = Terminal.shared.connectedReader {
                        vm.state = .connected(reader)
                    } else {
                        vm.state = .idle
                    }
                }
                .buttonStyle(.bordered)
            }

        case .collecting:
            ProgressView("Present card...")

        case .processing:
            ProgressView("Processing payment...")

        case .succeeded(let intent):
            VStack(spacing: 8) {
                Text("Payment Succeeded ✅")
                    .font(.headline)
                Text("Intent: \(intent.stripeId)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("New Payment") {
                    if let reader = Terminal.shared.connectedReader {
                        vm.state = .connected(reader)
                    } else {
                        vm.state = .idle
                    }
                }
                .buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            VStack(spacing: 8) {
                Text("Error")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                Button("Back") {
                    if let reader = Terminal.shared.connectedReader {
                        vm.state = .connected(reader)
                    } else {
                        vm.state = .idle
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
