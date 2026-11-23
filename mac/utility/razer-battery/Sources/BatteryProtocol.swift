import Foundation

struct RazerProduct: Sendable {
  let name: String
  let transactionID: UInt8

  static let vendorID = 0x1532
  static let products: [Int: RazerProduct] = [
    0x00A4: .init(name: "Razer Mouse Dock Pro", transactionID: 0x1f),
    0x00AA: .init(name: "Razer Basilisk V3 Pro Wired", transactionID: 0x1f),
    0x00AB: .init(name: "Razer Basilisk V3 Pro Wireless", transactionID: 0x1f),
    0x00B9: .init(name: "Razer Basilisk V3 X HyperSpeed", transactionID: 0x1f),
    0x007C: .init(name: "Razer DeathAdder V2 Pro Wired", transactionID: 0x3f),
    0x007D: .init(name: "Razer DeathAdder V2 Pro Wireless", transactionID: 0x3f),
    0x009C: .init(name: "Razer DeathAdder V2 X HyperSpeed", transactionID: 0x1f),
    0x00B3: .init(name: "Razer HyperPolling Wireless Dongle", transactionID: 0x1f),
    0x00B6: .init(name: "Razer DeathAdder V3 Pro Wired", transactionID: 0x1f),
    0x00B7: .init(name: "Razer DeathAdder V3 Pro Wireless", transactionID: 0x1f),
    0x0083: .init(name: "Razer Basilisk X HyperSpeed", transactionID: 0xff),
    0x0086: .init(name: "Razer Basilisk Ultimate", transactionID: 0x1f),
    0x0088: .init(name: "Razer Basilisk Ultimate Dongle", transactionID: 0x1f),
    0x008F: .init(name: "Razer Naga Pro Wired", transactionID: 0x1f),
    0x0090: .init(name: "Razer Naga Pro Wireless", transactionID: 0x1f),
    0x00A7: .init(name: "Razer Naga V2 Pro Wired", transactionID: 0x1f),
    0x00A8: .init(name: "Razer Naga V2 Pro Wireless", transactionID: 0x1f),
    0x00A5: .init(name: "Razer Viper V2 Pro Wired", transactionID: 0x1f),
    0x00A6: .init(name: "Razer Viper V2 Pro Wireless", transactionID: 0x1f),
    0x007A: .init(name: "Razer Viper Ultimate Wired", transactionID: 0xff),
    0x007B: .init(name: "Razer Viper Ultimate Wireless", transactionID: 0xff),
    0x0555: .init(name: "Razer BlackShark V2 Pro RZ04-0453", transactionID: 0x3f),
    0x0528: .init(name: "Razer BlackShark V2 Pro RZ04-0322", transactionID: 0x3f),
    0x00AF: .init(name: "Razer Cobra Pro Wired", transactionID: 0x1f),
    0x00B0: .init(name: "Razer Cobra Pro Wireless", transactionID: 0x1f),
  ]
}

enum BatteryOutcome: Equatable, Sendable {
  case reading(device: String, percent: Int)
  case unavailable(String)

  var description: String {
    switch self {
    case .reading(let device, let percent):
      return "\(device): \(percent)%"
    case .unavailable(let reason):
      return reason
    }
  }
}

enum BatteryProtocol {
  static let reportLength = 90

  static func request(transactionID: UInt8) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: reportLength)
    report[1] = transactionID
    report[5] = 0x02
    report[6] = 0x07
    report[7] = 0x80
    report[88] = checksum(report)
    return report
  }

  static func percent(from report: [UInt8], transactionID: UInt8) -> Int? {
    guard report.count == reportLength,
      report[0] == 0x02,
      report[1] == transactionID,
      report[2] == 0,
      report[3] == 0,
      report[4] == 0,
      report[5] == 0x02,
      report[6] == 0x07,
      report[7] == 0x80,
      report[88] == checksum(report)
    else {
      return nil
    }

    return Int((Double(report[9]) / 255.0 * 100.0).rounded())
  }

  static func checksum(_ report: [UInt8]) -> UInt8 {
    report[2..<88].reduce(0, ^)
  }
}
