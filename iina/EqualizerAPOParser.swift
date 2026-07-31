//
//  EqualizerAPOParser.swift
//  iina
//

import Foundation

enum EqualizerAPOParser {
  enum ParseError: Error {
    case noSupportedFilters
  }

  private static let number = "[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)"
  private static let preamp = try! NSRegularExpression(
    pattern: "^\\s*Preamp\\s*:\\s*(\(number))\\s*dB\\s*$",
    options: .caseInsensitive
  )
  private static let filter = try! NSRegularExpression(
    pattern: "^\\s*Filter\\s+\\d+\\s*:\\s*(ON|OFF)\\s+(PK|PEQ|LS|LSC|HS|HSC)" +
      "(?:\\s+\\d+dB)?\\s+Fc\\s+(\(number))\\s*Hz\\s+Gain\\s+(\(number))" +
      "\\s*dB\\s+Q\\s+(\(number))(?:\\s.*)?$",
    options: .caseInsensitive
  )

  static func filterGraph(contentsOf url: URL) throws -> String {
    return try filterGraph(String(contentsOf: url, encoding: .utf8))
  }

  static func filterGraph(_ text: String) throws -> String {
    var filters: [String] = []
    for line in text.components(separatedBy: .newlines) {
      if let values = captures(preamp, in: line), Double(values[0]) != nil {
        filters.append("volume=volume=\(values[0])dB:precision=double")
        continue
      }
      guard let values = captures(filter, in: line),
            values[0].caseInsensitiveCompare("ON") == .orderedSame,
            let frequency = Double(values[2]), frequency > 0,
            Double(values[3]) != nil,
            let q = Double(values[4]), q > 0 else {
        continue
      }
      let name: String
      switch values[1].uppercased() {
      case "PK", "PEQ": name = "equalizer"
      case "LS", "LSC": name = "lowshelf"
      case "HS", "HSC": name = "highshelf"
      default: continue
      }
      filters.append(
        "\(name)=frequency=\(values[2]):width_type=q:width=\(values[4]):" +
        "gain=\(values[3]):precision=double"
      )
    }
    guard !filters.isEmpty else { throw ParseError.noSupportedFilters }
    return filters.joined(separator: ",")
  }

  private static func captures(_ expression: NSRegularExpression, in string: String) -> [String]? {
    let source = string as NSString
    guard let match = expression.firstMatch(in: string, range: NSRange(location: 0, length: source.length)) else {
      return nil
    }
    return (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
  }
}
