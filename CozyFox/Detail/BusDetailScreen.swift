import SwiftUI
import TransitDomain
import TransitModels

struct BusDetailScreen: View {
    let route: String
    let stopId: Int
    @Environment(AppViewModel.self) private var model

    var predictions: [BusPrediction] {
        model.snapshot.busPredictions.filter {
            ($0.route == route || route.isEmpty)
            && ($0.stopId == stopId || stopId == 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if predictions.isEmpty {
                    Text("No predictions").foregroundStyle(.secondary)
                }
                ForEach(predictions, id: \.id) { p in
                    HStack {
                        Text("#\(p.route)").font(.subheadline.weight(.bold))
                        VStack(alignment: .leading) {
                            Text(p.destinationName).font(.subheadline)
                            Text(p.stopName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ArrivalFormatter.label(for: p).shortText)
                            .font(.callout.monospacedDigit())
                    }
                }
            }
            .navigationTitle("#\(route)")
        }
    }
}
