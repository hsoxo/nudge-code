import Foundation

protocol RelayClient: Sendable {
    func claimBinding(code: String, relayURL: URL) async throws -> BindingClaim
    func fetchBindingStatus(binding: MachineBinding, relayURL: URL) async throws -> BindingClaim
    func connect(machine: Machine) async throws
}

struct HTTPRelayClient: RelayClient {
    var urlSession: URLSession = .shared
    var identityStore: any PhoneIdentityStore = KeychainPhoneIdentityStore()

    func claimBinding(code: String, relayURL: URL) async throws -> BindingClaim {
        let identity = try identityStore.loadOrCreate()
        let device = try await registerPhone(relayURL: relayURL, phonePublicKey: identity.publicKey)
        var request = URLRequest(url: relayURL.appending(path: "/api/bind/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClaimRequest(code: code, phoneDeviceId: device.id))
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        return try decodeBindingClaim(from: data)
    }

    func fetchBindingStatus(binding: MachineBinding, relayURL: URL) async throws -> BindingClaim {
        var components = URLComponents(url: relayURL.appending(path: "/api/bind/status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bindingId", value: binding.bindingID),
            URLQueryItem(name: "deviceId", value: binding.phoneDeviceID)
        ]
        guard let url = components?.url else {
            throw RelayClientError.badURL
        }
        let (data, response) = try await urlSession.data(from: url)
        try validate(response: response)
        return try decodeBindingClaim(from: data)
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }

    private func registerPhone(relayURL: URL, phonePublicKey: String) async throws -> DeviceResponse.Device {
        var request = URLRequest(url: relayURL.appending(path: "/api/devices/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceRequest(kind: "phone", publicKey: phonePublicKey))
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        return try JSONDecoder().decode(DeviceResponse.self, from: data).device
    }

    private func decodeBindingClaim(from data: Data) throws -> BindingClaim {
        let binding = try JSONDecoder().decode(BindingResponse.self, from: data).binding
        guard let phoneDeviceID = binding.phoneDeviceId else {
            throw RelayClientError.missingPhoneDeviceID
        }
        return BindingClaim(
            bindingID: binding.id,
            daemonDeviceID: binding.daemonDeviceId,
            phoneDeviceID: phoneDeviceID,
            status: binding.status,
            expiresAt: binding.expiresAt
        )
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
    case badURL
    case badStatus
    case missingPhoneDeviceID
}

struct BindingClaim: Equatable, Sendable {
    var bindingID: String
    var daemonDeviceID: String
    var phoneDeviceID: String
    var status: BindingStatus
    var expiresAt: String
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

private struct BindingResponse: Decodable {
    struct Binding: Decodable {
        var id: String
        var daemonDeviceId: String
        var phoneDeviceId: String?
        var status: BindingStatus
        var expiresAt: String
    }

    var binding: Binding
}

private struct ClaimRequest: Encodable {
    var code: String
    var phoneDeviceId: String
}
