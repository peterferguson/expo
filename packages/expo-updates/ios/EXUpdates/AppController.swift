//  Copyright © 2019 650 Industries. All rights reserved.

// swiftlint:disable line_length
// swiftlint:disable type_body_length
// swiftlint:disable closure_body_length
// swiftlint:disable force_unwrapping

import Foundation
import ExpoModulesCore

public struct UpdatesModuleConstants {
  let launchedUpdate: Update?
  let embeddedUpdate: Update?
  let isEmergencyLaunch: Bool
  let isEnabled: Bool
  let releaseChannel: String
  let isUsingEmbeddedAssets: Bool
  let runtimeVersion: String?
  let checkOnLaunch: CheckAutomaticallyConfig
  let requestHeaders: [String: String]

  /**
   A dictionary of the locally downloaded assets for the current update. Keys are the remote URLs
   of the assets and values are local paths. This should be exported by the Updates JS module and
   can be used by `expo-asset` or a similar module to override React Native's asset resolution and
   use the locally downloaded assets.
   */
  let assetFilesMap: [String: Any]?
  
  let isMissingRuntimeVersion: Bool
}

public enum FetchUpdateResult {
  case success(manifest: [String: Any])
  case failure
  case rollBackToEmbedded
  case error(error: Error)
}

@objc(EXUpdatesAppControllerInterface)
public protocol AppControllerInterface {
  /**
   The RCTBridge for which EXUpdates is providing the JS bundle and assets.
   This is optional, but required in order for `Updates.reload()` and Updates module events to work.
   */
  @objc weak var bridge: AnyObject? { get set }

  /**
   Delegate which will be notified when EXUpdates has an update ready to launch and
   `launchAssetUrl` is nonnull.
   */
  @objc weak var delegate: AppControllerDelegate? { get set }

  /**
   The URL on disk to source asset for the RCTBridge.
   Will be null until the AppController delegate method is called.
   This should be provided in the `sourceURLForBridge:` method of RCTBridgeDelegate.
   */
  @objc func launchAssetUrl() -> URL?

  @objc var isStarted: Bool { get }

  /**
   Starts the update process to launch a previously-loaded update and (if configured to do so)
   check for a new update from the server. This method should be called as early as possible in
   the application's lifecycle.

   Note that iOS may stop showing the app's splash screen in case the update is taking a while
   to load. If your splash screen setup is simple, you may want to use the
   `startAndShowLaunchScreen:` method instead.
   */
  @objc func start()
}

public protocol InternalAppControllerInterface: AppControllerInterface {
  var updatesDirectory: URL? { get }

  func getConstantsForModule() -> UpdatesModuleConstants
  func requestRelaunch(
    success successBlockArg: @escaping () -> Void,
    error errorBlockArg: @escaping (_ error: Exception) -> Void
  )
  func checkForUpdate(
    success successBlockArg: @escaping (_ remoteCheckResult: RemoteCheckResult) -> Void,
    error errorBlockArg: @escaping (_ error: Exception) -> Void
  )
  func fetchUpdate(
    success successBlockArg: @escaping (_ fetchUpdateResult: FetchUpdateResult) -> Void,
    error errorBlockArg: @escaping (_ error: Exception) -> Void
  )
  func getExtraParams(
    success successBlockArg: @escaping (_ extraParams: [String: String]?) -> Void,
    error errorBlockArg: @escaping (_ error: Exception) -> Void
  )
  func setExtraParam(
    key: String,
    value: String?,
    success successBlockArg: @escaping () -> Void,
    error errorBlockArg: @escaping (_ error: Exception) -> Void
  )
  func getNativeStateMachineContext(
    success successBlockArg: @escaping (_ stateMachineContext: UpdatesStateContext) -> Void,
    error errorBlockArg: @escaping (_ error: Exception) -> Void
  )
}

@objc(EXUpdatesAppControllerDelegate)
public protocol AppControllerDelegate: AnyObject {
  func appController(_ appController: AppControllerInterface, didStartWithSuccess success: Bool)
}

/**
 * Main entry point to expo-updates. Singleton that keeps track of updates state, holds references
 * to instances of other updates classes, and is the central hub for all updates-related tasks.
 *
 * The `start` method in the singleton instance of [IUpdatesController] should be invoked early in
 * the application lifecycle, via [UpdatesPackage]. It delegates to an instance of [LoaderTask] to
 * start the process of loading and launching an update, then responds appropriately depending on
 * the callbacks that are invoked.
 *
 * This class also optionally holds a reference to the app's [ReactNativeHost], which allows
 * expo-updates to reload JS and send events through the bridge.
 */
@objc(EXUpdatesAppController)
@objcMembers
public class AppController: NSObject {
  private static var _sharedInstance: InternalAppControllerInterface?
  public static var sharedInstance: InternalAppControllerInterface {
    assert(_sharedInstance != nil, "AppController.sharedInstace was called before the module was initialized")
    return _sharedInstance!
  }

  public static func initializeWithoutStarting(configuration: [String: Any]?) {
    if _sharedInstance != nil {
      return
    }

    if UpdatesConfig.canCreateValidConfiguration(mergingOtherDictionary: configuration) {
      var config: UpdatesConfig?
      do {
        config = try UpdatesConfig.configWithExpoPlist(mergingOtherDictionary: configuration)
      } catch {
        NSException(
          name: .internalInconsistencyException,
          reason: "Cannot load configuration from Expo.plist. Please ensure you've followed the setup and installation instructions for expo-updates to create Expo.plist and add it to your Xcode project."
        )
        .raise()
      }

      let updatesDatabase = UpdatesDatabase()
      do {
        let directory = try initializeUpdatesDirectory()
        try initializeUpdatesDatabase(updatesDatabase: updatesDatabase, inUpdatesDirectory: directory)
        _sharedInstance = EnabledAppController(config: config!, database: updatesDatabase, updatesDirectory: directory)
      } catch {
        _sharedInstance = DisabledAppController(error: error, isMissingRuntimeVersion: UpdatesConfig.isMissingRuntimeVersion(mergingOtherDictionary: configuration))
        return
      }
    } else {
      _sharedInstance = DisabledAppController(error: nil, isMissingRuntimeVersion: UpdatesConfig.isMissingRuntimeVersion(mergingOtherDictionary: configuration))
    }
  }

  public static func initializeAsDevLauncherWithoutStarting() -> DevLauncherAppController {
    assert(_sharedInstance == nil, "UpdatesController must not be initialized prior to calling initializeAsDevLauncherWithoutStarting")

    var config: UpdatesConfig?
    if UpdatesConfig.canCreateValidConfiguration(mergingOtherDictionary: nil) {
      config = try? UpdatesConfig.configWithExpoPlist(mergingOtherDictionary: nil)
    }

    var updatesDirectory: URL?
    let updatesDatabase = UpdatesDatabase()
    var directoryDatabaseException: Error?
    do {
      updatesDirectory = try initializeUpdatesDirectory()
      try initializeUpdatesDatabase(updatesDatabase: updatesDatabase, inUpdatesDirectory: updatesDirectory!)
    } catch {
      directoryDatabaseException = error
    }

    let appController = DevLauncherAppController(
      initialUpdatesConfiguration: config,
      updatesDirectory: updatesDirectory,
      updatesDatabase: updatesDatabase,
      directoryDatabaseException: directoryDatabaseException,
      isMissingRuntimeVersion: UpdatesConfig.isMissingRuntimeVersion(mergingOtherDictionary: nil)
    )
    _sharedInstance = appController
    return appController
  }

  private static func initializeUpdatesDirectory() throws -> URL {
    return try UpdatesUtils.initializeUpdatesDirectory()
  }

  private static func initializeUpdatesDatabase(updatesDatabase: UpdatesDatabase, inUpdatesDirectory updatesDirectory: URL) throws {
    var dbError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    updatesDatabase.databaseQueue.async {
      do {
        try updatesDatabase.openDatabase(inDirectory: updatesDirectory)
      } catch {
        dbError = error
      }
      semaphore.signal()
    }

    _ = semaphore.wait(timeout: .distantFuture)

    if let dbError = dbError {
      throw dbError
    }
  }
}

// swiftlint:enable force_unwrapping
// swiftlint:enable closure_body_length
// swiftlint:enable line_length
// swiftlint:enable type_body_length
