import Foundation
import TransitModels

public protocol MetraClientProtocol: Sendable {
    func fetchTripUpdates() async throws -> [MetraRealtimeUpdate]
    func fetchPositions(routes: [String]) async throws -> [VehiclePosition]
    func fetchAlerts() async throws -> [ServiceAlert]
}

/// Metra GTFS-realtime client. The public realtime feeds use standard GTFS-RT
/// protobuf messages authenticated with a bearer token.
public actor MetraClient: MetraClientProtocol {
    private let http: HTTPClient
    private let apiKeyProvider: @Sendable () -> String?

    private static let realtimeBaseURL = URL(string: "https://gtfspublic.metrarr.com/gtfs/public")!
    private static let legacyBaseURL = URL(string: "https://gtfsapi.metrarail.com/gtfs/raw")!

    public init(
        http: HTTPClient = LiveHTTPClient(),
        apiKey: @Sendable @escaping () -> String?
    ) {
        self.http = http
        self.apiKeyProvider = apiKey
    }

    public func fetchTripUpdates() async throws -> [MetraRealtimeUpdate] {
        let data = try await fetchData(paths: [
            Self.realtimeBaseURL.appendingPathComponent("tripupdates"),
            Self.legacyBaseURL.appendingPathComponent("tripUpdates.dat"),
        ])
        return GTFSRealtimeParser.tripUpdates(from: data)
    }

    public func fetchPositions(routes: [String]) async throws -> [VehiclePosition] {
        let routeFilter = Set(routes)
        let data = try await fetchData(paths: [
            Self.realtimeBaseURL.appendingPathComponent("positions"),
            Self.legacyBaseURL.appendingPathComponent("positionUpdates.dat"),
        ])
        let positions = GTFSRealtimeParser.vehiclePositions(from: data)
        guard !routeFilter.isEmpty else { return positions }
        return positions.filter { routeFilter.contains($0.route) }
    }

    public func fetchAlerts() async throws -> [ServiceAlert] {
        let data = try await fetchData(paths: [
            Self.realtimeBaseURL.appendingPathComponent("alerts"),
            Self.legacyBaseURL.appendingPathComponent("alerts.dat"),
        ])
        return GTFSRealtimeParser.alerts(from: data)
    }

    private func fetchData(paths: [URL]) async throws -> Data {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        var lastError: Error = APIError.invalidURL
        for url in paths {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await http.data(for: request)
                guard (200..<300).contains(response.statusCode) else {
                    throw APIError.http(status: response.statusCode)
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }
}

private enum GTFSRealtimeParser {
    static func tripUpdates(from data: Data) -> [MetraRealtimeUpdate] {
        let root = ProtoReader.fields(in: data)
        let feedTimestamp = root
            .first(where: { $0.number == 1 })?
            .bytes
            .flatMap { headerTimestamp(from: $0) }

        return root
            .filter { $0.number == 2 }
            .compactMap(\.bytes)
            .flatMap { entityData -> [MetraRealtimeUpdate] in
                let entity = ProtoReader.fields(in: entityData)
                guard let tripUpdateData = entity.first(where: { $0.number == 3 })?.bytes else {
                    return []
                }
                return parseTripUpdate(tripUpdateData, feedTimestamp: feedTimestamp)
            }
    }

    static func vehiclePositions(from data: Data) -> [VehiclePosition] {
        ProtoReader.fields(in: data)
            .filter { $0.number == 2 }
            .compactMap(\.bytes)
            .compactMap { entityData -> VehiclePosition? in
                let entity = ProtoReader.fields(in: entityData)
                let entityId = entity.first(where: { $0.number == 1 })?.stringValue
                guard let vehicleData = entity.first(where: { $0.number == 4 })?.bytes else {
                    return nil
                }
                return parseVehiclePosition(vehicleData, fallbackId: entityId)
            }
    }

    static func alerts(from data: Data) -> [ServiceAlert] {
        let root = ProtoReader.fields(in: data)
        return root
            .filter { $0.number == 2 }
            .compactMap(\.bytes)
            .compactMap { entityData -> ServiceAlert? in
                let entity = ProtoReader.fields(in: entityData)
                let entityId = entity.first(where: { $0.number == 1 })?.stringValue ?? UUID().uuidString
                guard let alertData = entity.first(where: { $0.number == 5 })?.bytes else {
                    return nil
                }
                return parseAlert(alertData, entityId: entityId)
            }
    }

    private static func parseTripUpdate(_ data: Data, feedTimestamp: Date?) -> [MetraRealtimeUpdate] {
        let fields = ProtoReader.fields(in: data)
        let trip = fields.first(where: { $0.number == 1 })?.bytes.map(parseTripDescriptor)
        let vehicle = fields.first(where: { $0.number == 3 })?.bytes.map(parseVehicleDescriptor)
        let timestamp = fields.first(where: { $0.number == 4 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let generatedAt = timestamp ?? feedTimestamp ?? Date()
        guard let tripId = trip?.tripId, !tripId.isEmpty else { return [] }
        let tripRelationship = trip?.relationship ?? .scheduled

        return fields
            .filter { $0.number == 2 }
            .compactMap(\.bytes)
            .compactMap { stopData -> MetraRealtimeUpdate? in
                let stop = parseStopTimeUpdate(stopData)
                guard let stopId = stop.stopId, !stopId.isEmpty else { return nil }
                let relationship: MetraRealtimeUpdate.ScheduleRelationship
                if tripRelationship == .canceled {
                    relationship = .canceled
                } else {
                    relationship = stop.relationship
                }
                return MetraRealtimeUpdate(
                    tripId: tripId,
                    routeId: trip?.routeId,
                    directionId: trip?.directionId,
                    stopId: stopId,
                    arrivalAt: stop.arrival?.time,
                    departureAt: stop.departure?.time,
                    delaySeconds: stop.arrival?.delay ?? stop.departure?.delay,
                    vehicleId: vehicle?.id,
                    vehicleLabel: vehicle?.label,
                    scheduleRelationship: relationship,
                    generatedAt: generatedAt
                )
            }
    }

    private static func parseVehiclePosition(_ data: Data, fallbackId: String?) -> VehiclePosition? {
        let fields = ProtoReader.fields(in: data)
        let trip = fields.first(where: { $0.number == 1 })?.bytes.map(parseTripDescriptor)
        let position = fields.first(where: { $0.number == 2 })?.bytes.flatMap(parsePosition)
        let currentStopId = fields.first(where: { $0.number == 7 })?.stringValue
        let timestamp = fields.first(where: { $0.number == 5 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        let vehicle = fields.first(where: { $0.number == 8 })?.bytes.map(parseVehicleDescriptor)
        guard let position, let routeId = trip?.routeId else { return nil }
        return VehiclePosition(
            id: vehicle?.id ?? vehicle?.label ?? fallbackId ?? trip?.tripId ?? UUID().uuidString,
            mode: .metra,
            route: routeId,
            latitude: Double(position.latitude),
            longitude: Double(position.longitude),
            heading: position.bearing.map { Int($0.rounded()) },
            destinationName: nil,
            nextStopId: currentStopId.flatMap(Int.init),
            observedAt: timestamp
        )
    }

    private static func parseAlert(_ data: Data, entityId: String) -> ServiceAlert? {
        let fields = ProtoReader.fields(in: data)
        let periods = fields
            .filter { $0.number == 1 }
            .compactMap(\.bytes)
            .map(parseTimeRange)
        let routes = fields
            .filter { $0.number == 5 }
            .compactMap(\.bytes)
            .compactMap(parseEntitySelectorRoute)
        let effect = fields.first(where: { $0.number == 7 })?.varintValue.map(Int.init)
        let headline = fields.first(where: { $0.number == 10 })?.bytes
            .flatMap(parseTranslatedText)
            ?? "Metra service alert"
        let description = fields.first(where: { $0.number == 11 })?.bytes
            .flatMap(parseTranslatedText)
            ?? headline
        let beginsAt = periods.compactMap(\.start).min() ?? Date()
        let endsAt = periods.compactMap(\.end).max()
        let severity = severityForAlertEffect(effect)
        return ServiceAlert(
            id: "metra-\(entityId)",
            headline: headline,
            shortDescription: description,
            severity: severity,
            impactedRoutes: Array(Set(routes)).sorted(),
            impactedLineColors: [],
            beginsAt: beginsAt,
            endsAt: endsAt,
            isMajor: severity == .high,
            detailURL: ServiceAlert.metraDetailsURL
        )
    }

    private static func parseTripDescriptor(_ data: Data) -> TripDescriptor {
        let fields = ProtoReader.fields(in: data)
        return TripDescriptor(
            tripId: fields.first(where: { $0.number == 1 })?.stringValue,
            routeId: fields.first(where: { $0.number == 5 })?.stringValue,
            directionId: fields.first(where: { $0.number == 6 })?.varintValue.map(Int.init),
            relationship: scheduleRelationship(fields.first(where: { $0.number == 4 })?.varintValue)
        )
    }

    private static func parseStopTimeUpdate(_ data: Data) -> StopTimeUpdate {
        let fields = ProtoReader.fields(in: data)
        return StopTimeUpdate(
            stopId: fields.first(where: { $0.number == 4 })?.stringValue,
            arrival: fields.first(where: { $0.number == 2 })?.bytes.map(parseStopTimeEvent),
            departure: fields.first(where: { $0.number == 3 })?.bytes.map(parseStopTimeEvent),
            relationship: stopRelationship(fields.first(where: { $0.number == 5 })?.varintValue)
        )
    }

    private static func parseStopTimeEvent(_ data: Data) -> StopTimeEvent {
        let fields = ProtoReader.fields(in: data)
        let delay = fields.first(where: { $0.number == 1 })?.varintValue.map(protoInt32)
        let time = fields.first(where: { $0.number == 2 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return StopTimeEvent(delay: delay, time: time)
    }

    private static func parseVehicleDescriptor(_ data: Data) -> VehicleDescriptor {
        let fields = ProtoReader.fields(in: data)
        return VehicleDescriptor(
            id: fields.first(where: { $0.number == 1 })?.stringValue,
            label: fields.first(where: { $0.number == 2 })?.stringValue
        )
    }

    private static func parsePosition(_ data: Data) -> Position? {
        let fields = ProtoReader.fields(in: data)
        guard let lat = fields.first(where: { $0.number == 1 })?.floatValue,
              let lon = fields.first(where: { $0.number == 2 })?.floatValue
        else { return nil }
        return Position(
            latitude: lat,
            longitude: lon,
            bearing: fields.first(where: { $0.number == 3 })?.floatValue
        )
    }

    private static func parseTimeRange(_ data: Data) -> (start: Date?, end: Date?) {
        let fields = ProtoReader.fields(in: data)
        let start = fields.first(where: { $0.number == 1 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let end = fields.first(where: { $0.number == 2 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return (start, end)
    }

    private static func parseEntitySelectorRoute(_ data: Data) -> String? {
        ProtoReader.fields(in: data).first(where: { $0.number == 2 })?.stringValue
    }

    private static func parseTranslatedText(_ data: Data) -> String? {
        ProtoReader.fields(in: data)
            .filter { $0.number == 1 }
            .compactMap(\.bytes)
            .compactMap { translationData in
                ProtoReader.fields(in: translationData)
                    .first(where: { $0.number == 1 })?
                    .stringValue
            }
            .first(where: { !$0.isEmpty })
    }

    private static func headerTimestamp(from data: Data) -> Date? {
        ProtoReader.fields(in: data)
            .first(where: { $0.number == 3 })?
            .varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private static func scheduleRelationship(_ raw: UInt64?) -> MetraRealtimeUpdate.ScheduleRelationship {
        switch raw {
        case 0, nil: .scheduled
        case 1: .added
        case 2: .unscheduled
        case 3: .canceled
        default: .unknown
        }
    }

    private static func stopRelationship(_ raw: UInt64?) -> MetraRealtimeUpdate.ScheduleRelationship {
        switch raw {
        case 0, nil: .scheduled
        case 1: .skipped
        default: .unknown
        }
    }

    private static func severityForAlertEffect(_ effect: Int?) -> AlertSeverity {
        switch effect {
        case 1, 3: .high
        case 2, 4, 6, 9: .medium
        default: .low
        }
    }

    private static func protoInt32(_ raw: UInt64) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
    }

    private struct TripDescriptor {
        let tripId: String?
        let routeId: String?
        let directionId: Int?
        let relationship: MetraRealtimeUpdate.ScheduleRelationship
    }

    private struct StopTimeUpdate {
        let stopId: String?
        let arrival: StopTimeEvent?
        let departure: StopTimeEvent?
        let relationship: MetraRealtimeUpdate.ScheduleRelationship
    }

    private struct StopTimeEvent {
        let delay: Int?
        let time: Date?
    }

    private struct VehicleDescriptor {
        let id: String?
        let label: String?
    }

    private struct Position {
        let latitude: Float
        let longitude: Float
        let bearing: Float?
    }
}

private struct ProtoField {
    let number: Int
    let wireType: Int
    let varintValue: UInt64?
    let bytes: Data?
    let fixed32: UInt32?

    var stringValue: String? {
        guard let bytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    var floatValue: Float? {
        guard let fixed32 else { return nil }
        return Float(bitPattern: fixed32)
    }
}

private enum ProtoReader {
    static func fields(in data: Data) -> [ProtoField] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [ProtoField] = []

        while index < bytes.count {
            guard let key = readVarint(bytes, index: &index) else { break }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)

            switch wireType {
            case 0:
                guard let value = readVarint(bytes, index: &index) else { return fields }
                fields.append(ProtoField(number: number, wireType: wireType, varintValue: value, bytes: nil, fixed32: nil))
            case 1:
                guard index + 8 <= bytes.count else { return fields }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index) else { return fields }
                let end = index + Int(length)
                guard end <= bytes.count else { return fields }
                fields.append(ProtoField(number: number, wireType: wireType, varintValue: nil, bytes: Data(bytes[index..<end]), fixed32: nil))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return fields }
                let value = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                fields.append(ProtoField(number: number, wireType: wireType, varintValue: nil, bytes: nil, fixed32: value))
                index += 4
            default:
                return fields
            }
        }

        return fields
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var shift: UInt64 = 0
        var result: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }
}
