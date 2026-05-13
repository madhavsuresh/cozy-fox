import SwiftUI

struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "tram.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("Cozy Fox")
                .font(.largeTitle.weight(.bold))
            Text("Chicago transit, glanceable.")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                bullet("Trains and buses on your home screen")
                bullet("Nearest Divvy e-bikes with good range")
                bullet("Auto-surfaces your usual commute")
            }
            .padding(.horizontal)
            VStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.green)
                Text("All data goes from your phone directly to CTA and Divvy. Cozy Fox has no server.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Spacer()
            Button("Get Started", action: next)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.callout)
        }
    }
}
