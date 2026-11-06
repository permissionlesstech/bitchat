import BitFoundation
import Combine
import CoreLocation
import Foundation
import SwiftUI
#if SWIFT_PACKAGE
@testable import bitchat
#endif

@MainActor
func makeLayoutViewModel() -> (
  viewModel: ChatViewModel, transport: MockTransport, identityManager: MockIdentityManager
) {
  let keychain = MockKeychain()
  let keychainHelper = MockKeychainHelper()
  let idBridge = NostrIdentityBridge(keychain: keychainHelper)
  let identityManager = MockIdentityManager(keychain)
  let transport = MockTransport()
  let locationManager = makeLayoutLocationManager()
  let defaults = makeLayoutDefaults()
  var connectivityBindings = 0
  var deduplicationCreations = 0
  var geoCoordinatorCreations = 0
  var dependencies = ChatViewModelDependencies()
  dependencies.nostrTransport = NostrTransport.Dependencies(
    notificationCenter: NotificationCenter(),
    loadFavorites: { [:] },
    favoriteStatusForNoiseKey: { _ in nil },
    favoriteStatusForPeerID: { _ in nil },
    currentIdentity: { nil },
    registerPendingGiftWrap: { _ in preconditionFailure("Composer fixture attempted a gift wrap") },
    sendEvent: { _ in preconditionFailure("Composer fixture attempted a relay send") },
    scheduleAfter: { _, _ in preconditionFailure("Composer fixture attempted to schedule an ack") },
    relayConnectivity: {
      connectivityBindings += 1
      return Just(false).eraseToAnyPublisher()
    }
  )
  dependencies.makeDeduplicationService = {
    deduplicationCreations += 1
    return MessageDeduplicationService()
  }
  dependencies.relayManager = { nil }
  dependencies.favoritesService = FavoritesPersistenceService(keychain: keychain)
  dependencies.userDefaults = defaults
  dependencies.makeGeoCoordinator = { manager, context in
    geoCoordinatorCreations += 1
    return GeoChannelCoordinator(
      locationManager: manager,
      bookmarksStore: manager,
      isForeground: { false },
      notesRevealed: Just(false).eraseToAnyPublisher(),
      locationNotesEnabled: false,
      locationNotesSettings: Empty(completeImmediately: false).eraseToAnyPublisher(),
      context: context
    )
  }

  let viewModel = ChatViewModel(
    keychain: keychain,
    idBridge: idBridge,
    identityManager: identityManager,
    transport: transport,
    locationManager: locationManager,
    readReceiptsDefaults: defaults,
    dependencies: dependencies
  )

  precondition(connectivityBindings == 1 && deduplicationCreations == 1 && geoCoordinatorCreations == 1,
               "Composer fixture must use the injected service dependencies")
  precondition(viewModel.nostrRelayManager == nil, "Composer fixture must not acquire the live relay manager")
  precondition(transport.delegate === viewModel, "Composer fixture must retain production transport wiring")
  precondition(viewModel.privateChatManager.messageRouter === viewModel.messageRouter,
               "Composer fixture must retain production routing wiring")
  return (viewModel, transport, identityManager)
}

@MainActor
struct LayoutFeatureModels {
  let locationChannelsModel: LocationChannelsModel
  let privateConversationModel: PrivateConversationModel
  let conversationUIModel: ConversationUIModel
}

private func makeLayoutDefaults() -> UserDefaults {
  let suiteName = "ComposerLayoutTests.\(UUID().uuidString)"
  guard let storage = UserDefaults(suiteName: suiteName) else {
    preconditionFailure("Could not create isolated composer defaults")
  }
  storage.removePersistentDomain(forName: suiteName)
  return storage
}

@MainActor
func makeLayoutLocationManager() -> LocationChannelManager {
  LocationChannelManager(
    storage: makeLayoutDefaults(),
    locationManager: LayoutLocationAdapter(),
    geocoder: LayoutGeocoder(),
    shouldInitializeCoreLocation: false
  )
}

private final class LayoutLocationAdapter: LocationStateManaging {
  weak var delegate: CLLocationManagerDelegate?
  var desiredAccuracy: CLLocationAccuracy = 0
  var distanceFilter: CLLocationDistance = 0
  var authorizationStatus: CLAuthorizationStatus { .denied }
  func requestWhenInUseAuthorization() {
    preconditionFailure("Composer fixture attempted location authorization")
  }
  func requestLocation() { preconditionFailure("Composer fixture attempted location lookup") }
  func startUpdatingLocation() { preconditionFailure("Composer fixture attempted location updates") }
  func stopUpdatingLocation() {}
}

private final class LayoutGeocoder: LocationStateGeocoding {
  func cancelGeocode() {}
  func reverseGeocodeLocation(
    _ location: CLLocation,
    completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void
  ) {
    preconditionFailure("Composer fixture attempted geocoding")
  }
}

@MainActor
func makeLayoutFeatureModels(
  for viewModel: ChatViewModel, displayLocationManager: LocationChannelManager? = nil
) -> LayoutFeatureModels {
  let locationManager = viewModel.locationManager
  let conversations = viewModel.conversations
  let locationChannelsModel = LocationChannelsModel(manager: displayLocationManager ?? locationManager)
  let privateConversationModel = PrivateConversationModel(
    chatViewModel: viewModel,
    conversations: conversations,
    locationChannelsModel: locationChannelsModel
  )
  let conversationUIModel = ConversationUIModel(
    chatViewModel: viewModel,
    privateConversationModel: privateConversationModel,
    conversations: conversations
  )
  return LayoutFeatureModels(
    locationChannelsModel: locationChannelsModel,
    privateConversationModel: privateConversationModel,
    conversationUIModel: conversationUIModel
  )
}

@MainActor
func installLayoutEnvironment<V: View>(
  _ view: V,
  featureModels: LayoutFeatureModels
) -> some View {
  view
    .environmentObject(featureModels.locationChannelsModel)
    .environmentObject(featureModels.privateConversationModel)
    .environmentObject(featureModels.conversationUIModel)
}
