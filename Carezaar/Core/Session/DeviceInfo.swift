import Foundation
import UIKit

/// `auth/login` sends device telemetry. The Android client fills
/// version_app / os / version_os / device / version_device / browser / version_browser.
/// Android passes `null` for browser/version_browser, which Retrofit omits from the
/// form entirely. iOS does the same.
enum DeviceInfo {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    static var os: String { "iOS" }
    static var osVersion: String { UIDevice.current.systemVersion }
    /// Hardware identifier, e.g. "iPhone16,2".
    static var device: String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "iPhone" }
        }
    }
    static var deviceVersion: String { UIDevice.current.model }

    static var loginFields: [String: FormValue?] {
        ["version_app": .string(appVersion),
         "os": .string(os),
         "version_os": .string(osVersion),
         "device": .string(device),
         "version_device": .string(deviceVersion)]
    }
}
