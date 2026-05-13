import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppViewModel.self) private var model
    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep(next: { path.append(.apiKeys) })
                .navigationDestination(for: OnboardingStep.self) { step in
                    switch step {
                    case .apiKeys:
                        APIKeysStep(next: { path.append(.home) })
                    case .home:
                        HomeLocationStep(next: { path.append(.work) })
                    case .work:
                        WorkLocationStep(next: { path.append(.stations) })
                    case .stations:
                        StationsPickerStep(done: {
                            model.completeOnboarding()
                        })
                    }
                }
        }
    }
}

enum OnboardingStep: Hashable {
    case apiKeys
    case home
    case work
    case stations
}
