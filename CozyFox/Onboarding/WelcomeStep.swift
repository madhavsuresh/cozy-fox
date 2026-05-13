import ChicagoTheme
import SwiftUI

struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: ChicagoSpacing.lg) {
            Spacer(minLength: ChicagoSpacing.lg)

            // Chicago flag hero: blue / white stripes with the four stars
            flagHero
                .frame(height: 160)

            VStack(spacing: ChicagoSpacing.xs) {
                Text("Cozy Fox")
                    .font(ChicagoTypography.displayXL())
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Text("Chicago Transit, Glanceable")
                    .font(ChicagoTypography.displayMD())
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(ChicagoPalette.bahama)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                bullet("Trains and buses on your home screen")
                bullet("Nearest Divvy e-bikes with good range")
                bullet("Auto-surfaces your usual commute")
            }
            .padding(.horizontal, ChicagoSpacing.md)

            VStack(spacing: ChicagoSpacing.xs) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(ChicagoPalette.green)
                Text("Your data goes from this phone straight to CTA and Divvy. Cozy Fox has no server.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            .padding(.top, ChicagoSpacing.xs)

            Spacer()

            Button(action: next) {
                Text("Get Started")
                    .font(ChicagoTypography.displayMD(relativeTo: .headline))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ChicagoSpacing.md)
                    .background(ChicagoPalette.flagBlue,
                                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
            }
            .buttonStyle(.plain)
        }
        .padding(ChicagoSpacing.md)
    }

    /// A faithful (compact) Chicago flag: two pale-blue stripes
    /// enclosing a white field carrying four red six-pointed stars.
    private var flagHero: some View {
        GeometryReader { geo in
            let bandH = geo.size.height * 0.18
            let starSize = geo.size.height * 0.30
            VStack(spacing: 0) {
                Rectangle().fill(ChicagoPalette.flagBlue).frame(height: bandH)
                ZStack {
                    Rectangle().fill(Color.white)
                    HStack(spacing: ChicagoSpacing.md) {
                        ForEach(0..<4) { _ in
                            ChicagoStar()
                                .fill(ChicagoPalette.starRed)
                                .frame(width: starSize, height: starSize)
                        }
                    }
                }
                Rectangle().fill(ChicagoPalette.flagBlue).frame(height: bandH)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
        .accessibilityLabel("Cozy Fox — Chicago transit dashboard")
        .accessibilityAddTraits(.isImage)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.sm) {
            ChicagoStar()
                .fill(ChicagoPalette.starRed)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(ChicagoTypography.body(.medium, relativeTo: .callout))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
        }
    }
}
