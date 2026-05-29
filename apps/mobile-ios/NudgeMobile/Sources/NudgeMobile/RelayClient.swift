import Foundation

protocol RelayClient: Sendable {
    func claimBinding(code: String, relayURL: URL, phonePublicKey: String) async throws
    func connect(machine: Machine) async throws
}

struct HTTPRelayClient: RelayClient {
    var urlSession: URLSession = .shared

    func claimBinding(code: String, relayURL: URL, phonePublicKey: String) async throws {
        let device = try await registerPhone(relayURL: relayURL, phonePublicKey: phonePublicKey)
        var request = URLRequest(url: relayURL.appending(path: "/api/bind/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClaimRequest(code: code, phoneDeviceId: device.id))
        let (_, response) = try await urlSession.data(for: request)
        try validate(response: response)
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }

    private func registerPhone(relayURL: URL, phonePublicKey: String) async throws -> DeviceResponse.Device {
        var request = URLRequest(url: relayURL.appending(path: "/api/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceRequest(kind: "phone", publicKey: phonePublicKey))
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        return try JSONDecoder().decode(DeviceResponse.self, from: data).device
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              200 ..< 300 ~= http.statusCode
        else {
            throw RelayClientError.badStatus
        }
    }
}

enum RelayClientError: Error {
    case badStatus
}

private struct DeviceRequest: Encodable {
    var kind: String
    var publicKey: String
}

private struct DeviceResponse: Decodable {
    struct Device: Decodable {
        var id: String
    }

    var device: Device
}

private struct ClaimRequest: Encodable {
    var code: String
    var phoneDeviceId: String
}
