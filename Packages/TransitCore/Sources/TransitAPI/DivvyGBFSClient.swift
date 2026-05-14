import Foundation
import TransitModels

public protocol DivvyGBFSClientProtocol: Sendable {
    func fetchStations() async throws -> [BikeStation]
    func fetchEBikes() async throws -> [EBike]
}

/// Reads Divvy GBFS v2.3 feeds. No auth required.
///
/// We merge `station_information.json` (static-ish data) with `station_status.json`
/// (live counts) to produce `BikeStation`. The `free_bike_status.json` feed gives
/// per-bike range; we filter to e-bikes (vehicle_type_id == 2 in Chicago).
public actor DivvyGBFSClient: DivvyGBFSClientProtocol {
    public static let baseURL = URL(string: "https://gbfs.lyft.com/gbfs/2.3/chi/en")!

    private let http: HTTPClient
    /// Vehicle type id for e-bikes in the Divvy GBFS feed. Refreshed lazily.
    private var eBikeVehicleTypeId: String = "2"

    public init(http: HTTPClient = LiveHTTPClient()) {
        self.http = http
    }

    public func fetchStations() async throws -> [BikeStation] {
        async let info = fetch(StationInformationFeed.self, path: "station_information.json")
        async let status = fetch(
            StationStatusFeed.self,
            path: "station_status.json",
            bypassLocalCache: true
        )
        let (infoFeed, statusFeed) = try await (info, status)
        return merge(info: infoFeed.data.stations, status: statusFeed.data.stations)
    }

    public func fetchEBikes() async throws -> [EBike] {
        async let bikes = fetch(
            FreeBikeStatusFeed.self,
            path: "free_bike_status.json",
            bypassLocalCache: true
        )
        // The vehicle_types feed is small and rarely changes, but we read it once
        // so we don't hardcode the "2" mapping forever.
        async let types = fetchVehicleTypes()
        let (bikesFeed, electricId) = try await (bikes, types)
        return bikesFeed.data.bikes.compactMap { raw in
            guard !raw.is_disabled, raw.vehicle_type_id == electricId else { return nil }
            return EBike(
                id: raw.bike_id,
                latitude: raw.lat,
                longitude: raw.lon,
                currentRangeMeters: raw.current_range_meters ?? 0,
                isReserved: raw.is_reserved,
                isDisabled: raw.is_disabled,
                stationId: raw.station_id
            )
        }
    }

    private func fetchVehicleTypes() async -> String {
        do {
            let feed = try await fetch(VehicleTypesFeed.self, path: "vehicle_types.json")
            if let electric = feed.data.vehicle_types.first(where: {
                $0.propulsion_type == "electric_assist" && $0.form_factor == "bicycle"
            }) {
                eBikeVehicleTypeId = electric.vehicle_type_id
            }
        } catch {
            // keep last known id; default "2" is correct as of May 2026
        }
        return eBikeVehicleTypeId
    }

    private func merge(
        info: [StationInformationFeed.Data.Station],
        status: [StationStatusFeed.Data.Station]
    ) -> [BikeStation] {
        let infoById = Dictionary(uniqueKeysWithValues: info.map { ($0.station_id, $0) })
        return status.compactMap { s in
            guard let i = infoById[s.station_id] else { return nil }
            return BikeStation(
                id: s.station_id,
                name: i.name,
                latitude: i.lat,
                longitude: i.lon,
                capacity: i.capacity ?? (s.num_docks_available + s.num_bikes_available),
                eBikesAvailable: s.num_ebikes_available ?? 0,
                classicBikesAvailable: max(0, s.num_bikes_available - (s.num_ebikes_available ?? 0)),
                docksAvailable: s.num_docks_available,
                isRenting: (s.is_renting ?? 1) == 1,
                isReturning: (s.is_returning ?? 1) == 1,
                lastReported: Date(timeIntervalSince1970: TimeInterval(s.last_reported))
            )
        }
    }

    private func fetch<T: Decodable>(
        _ type: T.Type,
        path: String,
        bypassLocalCache: Bool = false
    ) async throws -> T {
        let url = Self.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        if bypassLocalCache {
            // Availability feeds are already polled on the app refresh cadence;
            // do not let URLCache reuse a response until the GBFS TTL expires.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            return try JSONDecoder.gbfs.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

extension JSONDecoder {
    static let gbfs: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()
}

// MARK: - GBFS wire types

struct StationInformationFeed: Decodable {
    let data: Data
    struct Data: Decodable {
        let stations: [Station]
        struct Station: Decodable {
            let station_id: String
            let name: String
            let lat: Double
            let lon: Double
            let capacity: Int?
        }
    }
}

struct StationStatusFeed: Decodable {
    let data: Data
    struct Data: Decodable {
        let stations: [Station]
        struct Station: Decodable {
            let station_id: String
            let num_bikes_available: Int
            let num_ebikes_available: Int?
            let num_docks_available: Int
            let is_renting: Int?
            let is_returning: Int?
            let last_reported: Int
        }
    }
}

struct FreeBikeStatusFeed: Decodable {
    let data: Data
    struct Data: Decodable {
        let bikes: [Bike]
        struct Bike: Decodable {
            let bike_id: String
            let lat: Double
            let lon: Double
            let vehicle_type_id: String
            let is_reserved: Bool
            let is_disabled: Bool
            let current_range_meters: Double?
            let station_id: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                bike_id = try c.decode(String.self, forKey: .bike_id)
                lat = try c.decode(Double.self, forKey: .lat)
                lon = try c.decode(Double.self, forKey: .lon)
                vehicle_type_id = try c.decode(String.self, forKey: .vehicle_type_id)
                if let b = try? c.decode(Bool.self, forKey: .is_reserved) {
                    is_reserved = b
                } else {
                    is_reserved = (try? c.decode(Int.self, forKey: .is_reserved)) == 1
                }
                if let b = try? c.decode(Bool.self, forKey: .is_disabled) {
                    is_disabled = b
                } else {
                    is_disabled = (try? c.decode(Int.self, forKey: .is_disabled)) == 1
                }
                current_range_meters = try c.decodeIfPresent(Double.self, forKey: .current_range_meters)
                station_id = try c.decodeIfPresent(String.self, forKey: .station_id)
            }

            enum CodingKeys: String, CodingKey {
                case bike_id, lat, lon, vehicle_type_id, is_reserved, is_disabled
                case current_range_meters, station_id
            }
        }
    }
}

struct VehicleTypesFeed: Decodable {
    let data: Data
    struct Data: Decodable {
        let vehicle_types: [VehicleType]
        struct VehicleType: Decodable {
            let vehicle_type_id: String
            let form_factor: String
            let propulsion_type: String
            let max_range_meters: Double?
            let name: String?
        }
    }
}
