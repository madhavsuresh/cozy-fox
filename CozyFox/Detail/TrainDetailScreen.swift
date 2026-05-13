import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct TrainDetailScreen: View {
    let stationId: Int
    @Environment(AppViewModel.self) private var model

    var arrivals: [Arrival] {
        model.snapshot.trainArrivals.filter { $0.stationId == stationId || stationId == 0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if arrivals.isEmpty {
                    Text("No predictions").foregroundStyle(.secondary)
                }
                ForEach(arrivals, id: \.id) { arrival in
                    HStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(arrival.line.swiftUIColor)
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading) {
                            Text(arrival.destinationName).font(.subheadline.weight(.semibold))
                            Text(arrival.stationName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ArrivalFormatter.label(for: arrival).shortText)
                            .font(.callout.monospacedDigit())
                    }
                }
            }
            .navigationTitle(arrivals.first?.stationName ?? "Train")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { refreshButton } }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshIfNeeded(force: true) }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
    }
}
