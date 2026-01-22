import Foundation

struct PiVendClient {
    struct VendError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // TODO: move these to Info.plist or a config screen later
    let baseURL: URL = URL(string: "http://192.168.0.134:8787")!
    let apiKey: String = "CHANGE_ME" // must match your FastAPI X-API-Key

    // ✅ Updated: send mask instead of slot_id
    func testVend(mask: Int, pulseSeconds: Double = 2.0) async throws {
        let url = baseURL.appendingPathComponent("vend_mask")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let payload: [String: Any] = [
            "mask": mask,
            "pulse_seconds": pulseSeconds
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        req.httpBody = bodyData

        // 🔍 DEBUG LOGGING — KEEP FOR NOW
        print("========== PI VEND REQUEST ==========")
        print("URL:", req.url?.absoluteString ?? "<nil>")
        print("METHOD:", req.httpMethod ?? "<nil>")
        print("HEADERS:")
        req.allHTTPHeaderFields?.forEach { key, value in
            print("  \(key): \(value)")
        }
        if let bodyString = String(data: bodyData, encoding: .utf8) {
            print("BODY:")
            print(bodyString)
        } else {
            print("BODY: <non-utf8>")
        }
        print("====================================")

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw VendError(message: "No HTTP response from Pi.")
        }

        if !(200...299).contains(http.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("========== PI VEND RESPONSE ==========")
            print("STATUS:", http.statusCode)
            print("BODY:")
            print(responseBody)
            print("====================================")
            throw VendError(message: "Pi vend failed (\(http.statusCode))")
        }

        print("[PiVendClient] Vend succeeded (status \(http.statusCode))")
    }
}
