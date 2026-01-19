//
//  PulseService.swift
//  SellMateTrial
//
//  Created by Sam on 12/18/25.
//

import Foundation

struct PulseResult: Decodable {
    let ok: Bool
    let pin: Int
    let ms: Int
}

enum PulseError: LocalizedError {
    case badURL
    case badResponse(Int)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid base URL"
        case .badResponse(let code): return "HTTP \(code)"
        case .invalidData: return "Invalid response"
        }
    }
}

final class PulseService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config)
    }

    func pins(baseURL: String, apiKey: String) async throws -> [Int] {
        guard let url = URL(string: baseURL + "/pins") else { throw PulseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PulseError.invalidData }
        guard (200..<300).contains(http.statusCode) else { throw PulseError.badResponse(http.statusCode) }
        struct PinsDTO: Decodable { let pins: [Int] }
        return try JSONDecoder().decode(PinsDTO.self, from: data).pins
    }

    func pulse(baseURL: String, apiKey: String, pin: Int, ms: Int) async throws -> PulseResult {
        guard let url = URL(string: baseURL + "/pulse") else { throw PulseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin, "ms": ms], options: [])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PulseError.invalidData }
        guard (200..<300).contains(http.statusCode) else { throw PulseError.badResponse(http.statusCode) }
        return try JSONDecoder().decode(PulseResult.self, from: data)
    }
}
