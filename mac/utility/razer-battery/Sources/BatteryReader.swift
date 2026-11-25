import Foundation
import IOKit.hid

struct BatteryScan: Sendable {
  let outcome: BatteryOutcome
  let diagnostics: [String]
  var failureKind: BatteryFailureKind = .transient
}

enum BatteryReader {
  static func read() -> BatteryScan {
    BatteryRetry.read { readOnce() }
  }

  private static func readOnce() -> BatteryScan {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(
      manager, [kIOHIDVendorIDKey: RazerProduct.vendorID] as CFDictionary)

    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    var diagnostics = ["Razer HID interfaces found: \(devices.count)"]
    var knownDeviceFound = false
    var accessDenied = false
    var accessibleInterfaceFound = false
    var queriedUSBDevices = Set<UInt64>()

    for device in devices.sorted(by: { registryID($0) < registryID($1) }) {
      let productID = integerProperty(device, key: kIOHIDProductIDKey)
      let usagePage = integerProperty(device, key: kIOHIDPrimaryUsagePageKey)
      let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
      diagnostics.append(
        String(
          format: "PID_%04X usage-page=0x%04X transport=%@", productID, usagePage,
          transport ?? "unknown"))

      guard let product = RazerProduct.products[productID] else {
        diagnostics.append("  Product ID is not in the device table.")
        continue
      }
      knownDeviceFound = true

      if let usbService = usbDevice(for: device) {
        defer { IOObjectRelease(usbService) }
        var usbID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(usbService, &usbID)
        if queriedUSBDevices.insert(usbID).inserted {
          var response = [UInt8](repeating: 0, count: BatteryProtocol.reportLength)
          var error = [CChar](repeating: 0, count: 256)
          let request = BatteryProtocol.request(transactionID: product.transactionID)
          let length = request.withUnsafeBufferPointer { requestBuffer in
            response.withUnsafeMutableBufferPointer { responseBuffer in
              error.withUnsafeMutableBufferPointer { errorBuffer in
                RazerReadUSBFeature(
                  usbService, requestBuffer.baseAddress!,
                  responseBuffer.baseAddress!, errorBuffer.baseAddress!,
                  errorBuffer.count)
              }
            }
          }
          if length == BatteryProtocol.reportLength {
            accessibleInterfaceFound = true
            if let percent = BatteryProtocol.percent(
              from: response, transactionID: product.transactionID)
            {
              let outcome = BatteryOutcome.reading(
                device: product.name, percent: percent)
              diagnostics.append("  USB control battery result: \(outcome.description)")
              return BatteryScan(outcome: outcome, diagnostics: diagnostics)
            }
            diagnostics.append(
              String(
                format: "  Invalid USB battery reply: status=0x%02X transaction=0x%02X",
                response[0], response[1]))
          } else {
            let message = String(
              decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
              as: UTF8.self)
            diagnostics.append("  \(message)")
          }
        }
      }

      let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
      guard openResult == kIOReturnSuccess else {
        diagnostics.append("  Open failed: \(format(openResult))")
        accessDenied =
          accessDenied || openResult == kIOReturnNotPermitted
          || openResult == kIOReturnNotPrivileged
        continue
      }
      accessibleInterfaceFound = true
      defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

      // IOHID passes report ID separately. Unlike Windows, report ID 0 has no prefix byte.
      let request = BatteryProtocol.request(transactionID: product.transactionID)
      let setResult = request.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
      }
      guard setResult == kIOReturnSuccess else {
        diagnostics.append("  Set feature failed: \(format(setResult))")
        continue
      }

      Thread.sleep(forTimeInterval: 0.5)

      var response = [UInt8](repeating: 0, count: BatteryProtocol.reportLength)
      var length = response.count
      let getResult = response.withUnsafeMutableBufferPointer {
        IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
      }
      guard getResult == kIOReturnSuccess else {
        diagnostics.append("  Get feature failed: \(format(getResult))")
        continue
      }
      guard length == BatteryProtocol.reportLength else {
        diagnostics.append("  Unexpected report length: \(length)")
        continue
      }
      guard
        let percent = BatteryProtocol.percent(
          from: response, transactionID: product.transactionID)
      else {
        diagnostics.append(
          String(
            format: "  Invalid battery reply: status=0x%02X transaction=0x%02X",
            response[0], response[1]))
        continue
      }

      let outcome = BatteryOutcome.reading(device: product.name, percent: percent)
      diagnostics.append("Battery result: \(outcome.description)")
      return BatteryScan(outcome: outcome, diagnostics: diagnostics)
    }

    let reason: String
    let failureKind: BatteryFailureKind
    if accessDenied && !accessibleInterfaceFound {
      reason = "Device access denied. Check macOS Input Monitoring permissions."
      failureKind = .accessDenied
    } else if knownDeviceFound {
      reason = "Razer device found, but no valid battery report was received."
      failureKind = .transient
    } else if devices.isEmpty {
      reason = "No Razer HID device found. Connect the USB receiver or device."
      failureKind = .disconnected
    } else {
      reason = "Connected Razer device is not in the device table."
      failureKind = .unsupported
    }
    diagnostics.append("Battery result: \(reason)")
    return BatteryScan(
      outcome: .unavailable(reason), diagnostics: diagnostics, failureKind: failureKind)
  }

  private static func usbDevice(for device: IOHIDDevice) -> io_service_t? {
    var service = IOHIDDeviceGetService(device)
    guard service != 0, IOObjectRetain(service) == kIOReturnSuccess else { return nil }
    while IOObjectConformsTo(service, "IOUSBHostDevice") == 0 {
      var parent: io_registry_entry_t = 0
      let result = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
      IOObjectRelease(service)
      guard result == kIOReturnSuccess else { return nil }
      service = parent
    }
    return service
  }

  private static func integerProperty(_ device: IOHIDDevice, key: String) -> Int {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
  }

  private static func registryID(_ device: IOHIDDevice) -> UInt64 {
    var identifier: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &identifier)
    return identifier
  }

  private static func format(_ result: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: result))
  }
}
