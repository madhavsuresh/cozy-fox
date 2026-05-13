import CoreText
import Foundation
import os

/// Registers the Chicago Design System typefaces (Big Shoulders Display,
/// Big Shoulders Text, Roboto) for the current process.
///
/// Call `ChicagoTheme.bootstrap()` once from each binary's entry point —
/// the app, the widget extension, and the live activity extension. The
/// call is idempotent and cheap on re-entry.
public enum ChicagoTheme {
    private static let didBootstrap = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: "net.thoughtbison.cozyfox", category: "ChicagoTheme")

    public static func bootstrap() {
        didBootstrap.withLock { done in
            guard !done else { return }
            registerFonts()
            done = true
        }
    }

    private static func registerFonts() {
        let names = ["BigShouldersDisplay", "BigShouldersText", "Roboto"]
        for name in names {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                log.error("Font resource missing: \(name).ttf")
                assertionFailure("ChicagoTheme: missing font resource \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok, let err = error?.takeRetainedValue() {
                let code = CFErrorGetCode(err)
                // 105 == kCTFontManagerErrorAlreadyRegistered — fine on re-entry.
                if code != 105 {
                    log.error("Font registration failed for \(name): \(err.localizedDescription)")
                    assertionFailure("ChicagoTheme: font registration failed for \(name)")
                }
            }
        }
    }
}
