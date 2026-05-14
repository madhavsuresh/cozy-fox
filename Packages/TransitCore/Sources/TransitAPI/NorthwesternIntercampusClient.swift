import Foundation
import TransitModels

public protocol NorthwesternIntercampusClientProtocol: Sendable {
    func fetchArrivals(stopIds: Set<String>?, now: Date) async throws -> [IntercampusArrival]
}

public actor NorthwesternIntercampusClient: NorthwesternIntercampusClientProtocol {
    private let http: HTTPClient
    private static let tripUpdateURL = URL(string: "https://northwestern.tripshot.com/v1/gtfs/realtime/tripUpdate")!

    public init(http: HTTPClient = LiveHTTPClient()) {
        self.http = http
    }

    public func fetchArrivals(
        stopIds: Set<String>? = nil,
        now: Date = .now
    ) async throws -> [IntercampusArrival] {
        var request = URLRequest(url: Self.tripUpdateURL)
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        return TripShotIntercampusParser.arrivals(
            from: data,
            stopIds: stopIds,
            now: now
        )
    }
}

private enum TripShotIntercampusParser {
    static func arrivals(
        from data: Data,
        stopIds: Set<String>?,
        now: Date
    ) -> [IntercampusArrival] {
        let root = TripShotProtoReader.fields(in: data)
        let feedTimestamp = root
            .first(where: { $0.number == 1 })?
            .bytes
            .flatMap { headerTimestamp(from: $0) }

        var seen: Set<String> = []
        return root
            .filter { $0.number == 2 }
            .compactMap(\.bytes)
            .flatMap { entityData -> [IntercampusArrival] in
                let entity = TripShotProtoReader.fields(in: entityData)
                guard let tripUpdateData = entity.first(where: { $0.number == 3 })?.bytes else {
                    return []
                }
                return parseTripUpdate(
                    tripUpdateData,
                    stopIds: stopIds,
                    feedTimestamp: feedTimestamp,
                    now: now
                )
            }
            .filter { $0.arrivalAt > now.addingTimeInterval(-120) }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .filter { seen.insert($0.id).inserted }
    }

    private static func parseTripUpdate(
        _ data: Data,
        stopIds: Set<String>?,
        feedTimestamp: Date?,
        now: Date
    ) -> [IntercampusArrival] {
        let fields = TripShotProtoReader.fields(in: data)
        let trip = fields.first(where: { $0.number == 1 })?.bytes.map(parseTripDescriptor)
        let vehicle = fields.first(where: { $0.number == 3 })?.bytes.map(parseVehicleDescriptor)
        let timestamp = fields.first(where: { $0.number == 4 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let generatedAt = timestamp ?? feedTimestamp ?? now

        guard let tripId = trip?.tripId, !tripId.isEmpty,
              let routeId = trip?.routeId,
              let route = IntercampusCatalog.route(id: routeId),
              trip?.relationship != .canceled
        else { return [] }

        return fields
            .filter { $0.number == 2 }
            .compactMap(\.bytes)
            .compactMap { stopData -> IntercampusArrival? in
                let stopUpdate = parseStopTimeUpdate(stopData)
                guard stopUpdate.relationship != .skipped,
                      let stopId = stopUpdate.stopId,
                      stopIds?.contains(stopId) ?? true,
                      let stop = IntercampusCatalog.stop(id: stopId),
                      stop.servedDirections.contains(route.direction)
                else { return nil }

                let event = stopUpdate.arrival ?? stopUpdate.departure
                guard let arrivalAt = event?.time else { return nil }
                let delay = event?.delay
                return IntercampusArrival(
                    id: "intercampus-\(tripId)-\(stopId)-\(Int(arrivalAt.timeIntervalSince1970))",
                    routeId: routeId,
                    direction: route.direction,
                    tripId: tripId,
                    vehicleId: vehicle?.id,
                    vehicleLabel: vehicle?.label,
                    stopId: stopId,
                    stopName: stop.name,
                    destinationName: route.destinationName,
                    generatedAt: generatedAt,
                    arrivalAt: arrivalAt,
                    delaySeconds: delay,
                    isDelayed: abs(delay ?? 0) >= 60
                )
            }
    }

    private static func parseTripDescriptor(_ data: Data) -> TripDescriptor {
        let fields = TripShotProtoReader.fields(in: data)
        return TripDescriptor(
            tripId: fields.first(where: { $0.number == 1 })?.stringValue,
            routeId: fields.first(where: { $0.number == 5 })?.stringValue,
            relationship: tripRelationship(fields.first(where: { $0.number == 4 })?.varintValue)
        )
    }

    private static func parseStopTimeUpdate(_ data: Data) -> StopTimeUpdate {
        let fields = TripShotProtoReader.fields(in: data)
        return StopTimeUpdate(
            stopId: fields.first(where: { $0.number == 4 })?.stringValue,
            arrival: fields.first(where: { $0.number == 2 })?.bytes.map(parseStopTimeEvent),
            departure: fields.first(where: { $0.number == 3 })?.bytes.map(parseStopTimeEvent),
            relationship: stopRelationship(fields.first(where: { $0.number == 5 })?.varintValue)
        )
    }

    private static func parseStopTimeEvent(_ data: Data) -> StopTimeEvent {
        let fields = TripShotProtoReader.fields(in: data)
        let delay = fields.first(where: { $0.number == 1 })?.varintValue.map(protoInt32)
        let time = fields.first(where: { $0.number == 2 })?.varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return StopTimeEvent(delay: delay, time: time)
    }

    private static func parseVehicleDescriptor(_ data: Data) -> VehicleDescriptor {
        let fields = TripShotProtoReader.fields(in: data)
        return VehicleDescriptor(
            id: fields.first(where: { $0.number == 1 })?.stringValue,
            label: fields.first(where: { $0.number == 2 })?.stringValue
        )
    }

    private static func headerTimestamp(from data: Data) -> Date? {
        TripShotProtoReader.fields(in: data)
            .first(where: { $0.number == 3 })?
            .varintValue
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private static func tripRelationship(_ raw: UInt64?) -> TripRelationship {
        switch raw {
        case 3: .canceled
        default: .scheduled
        }
    }

    private static func stopRelationship(_ raw: UInt64?) -> StopRelationship {
        switch raw {
        case 1: .skipped
        default: .scheduled
        }
    }

    private static func protoInt32(_ raw: UInt64) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
    }

    private struct TripDescriptor {
        let tripId: String?
        let routeId: String?
        let relationship: TripRelationship
    }

    private struct StopTimeUpdate {
        let stopId: String?
        let arrival: StopTimeEvent?
        let departure: StopTimeEvent?
        let relationship: StopRelationship
    }

    private struct StopTimeEvent {
        let delay: Int?
        let time: Date?
    }

    private struct VehicleDescriptor {
        let id: String?
        let label: String?
    }

    private enum TripRelationship {
        case scheduled
        case canceled
    }

    private enum StopRelationship {
        case scheduled
        case skipped
    }
}

private struct TripShotProtoField {
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

private enum TripShotProtoReader {
    static func fields(in data: Data) -> [TripShotProtoField] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [TripShotProtoField] = []

        while index < bytes.count {
            guard let key = readVarint(bytes, index: &index) else { break }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)

            switch wireType {
            case 0:
                guard let value = readVarint(bytes, index: &index) else { return fields }
                fields.append(TripShotProtoField(number: number, wireType: wireType, varintValue: value, bytes: nil, fixed32: nil))
            case 1:
                guard index + 8 <= bytes.count else { return fields }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index) else { return fields }
                let end = index + Int(length)
                guard end <= bytes.count else { return fields }
                fields.append(TripShotProtoField(number: number, wireType: wireType, varintValue: nil, bytes: Data(bytes[index..<end]), fixed32: nil))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return fields }
                let value = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                fields.append(TripShotProtoField(number: number, wireType: wireType, varintValue: nil, bytes: nil, fixed32: value))
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
