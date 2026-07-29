import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLocalDataDirectoryIsExcludedFromBackup() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    try LocalDataBackupProtection.excludeFromBackup([directory])

    let values = try directory.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

}
