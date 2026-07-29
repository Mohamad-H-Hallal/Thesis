import Flutter
import FirebaseCore
import UIKit

enum LocalDataBackupProtection {
  private static let errorDomain = "com.terraleb.mobile.backup-protection"

  static func excludeApplicationData(
    fileManager: FileManager = .default
  ) throws {
    let directories: [FileManager.SearchPathDirectory] = [
      .documentDirectory,
      .applicationSupportDirectory,
    ]
    let urls = try directories.map { directory in
      try fileManager.url(
        for: directory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    }
    try excludeFromBackup(urls)
  }

  static func excludeFromBackup(_ urls: [URL]) throws {
    for sourceURL in urls {
      var url = sourceURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)

      let verified = try url.resourceValues(
        forKeys: [.isExcludedFromBackupKey]
      ).isExcludedFromBackup
      guard verified == true else {
        throw NSError(
          domain: errorDomain,
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Could not verify local-data backup exclusion."
          ]
        )
      }
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      try LocalDataBackupProtection.excludeApplicationData()
    } catch {
      NSLog("TerraLeb refused startup because backup exclusion failed: \(error)")
      return false
    }
    if FirebaseApp.app() == nil,
      Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
      FirebaseApp.configure()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
