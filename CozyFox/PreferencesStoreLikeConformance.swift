import Foundation
import TransitCache
import TransitLocation

/// Bridge: `PreferencesStore` (TransitCache) conforms to `PreferencesStoreLike`
/// (TransitLocation) so the LocationCoordinator can read/write through it
/// without TransitLocation needing to depend on TransitCache.
extension PreferencesStore: PreferencesStoreLike {}
