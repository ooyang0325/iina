//
//  EqualizerAPOParser.swift
//  iina
//

import Foundation

enum EqualizerAPOParser {
  enum ParseError: Error, Equatable {
    case invalidLine(Int)
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
  private static let graphicEQ = try! NSRegularExpression(
    pattern: "^\\s*GraphicEQ\\s*:\\s*(.+)\\s*$",
    options: .caseInsensitive
  )

  static func filterGraph(contentsOf url: URL) throws -> String {
    return try filterGraph(String(contentsOf: url, encoding: .utf8))
  }

  static func filterGraph(_ text: String) throws -> String {
    var filters: [String] = []
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if let values = captures(preamp, in: line), Double(values[0]) != nil {
        filters.append("volume=volume=\(values[0])dB:precision=double")
        continue
      }
      if trimmed.lowercased().hasPrefix("preamp:") {
        throw ParseError.invalidLine(index + 1)
      }
      if let values = captures(graphicEQ, in: line) {
        let entries = values[0].split(separator: ";").map {
          $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        var lastFrequency = 0.0
        var gainEntries: [String] = []
        for entry in entries {
          guard entry.count == 2,
                let frequency = Double(entry[0]), frequency.isFinite,
                frequency > lastFrequency,
                let gain = Double(entry[1]), gain.isFinite else {
            throw ParseError.invalidLine(index + 1)
          }
          lastFrequency = frequency
          gainEntries.append("entry(\(entry[0]),\(entry[1]))")
        }
        guard gainEntries.count >= 2 else { throw ParseError.invalidLine(index + 1) }
        filters.append(
          "firequalizer=gain='cubic_interpolate(f)':gain_entry='" +
          gainEntries.joined(separator: ";") + "'"
        )
        continue
      }
      guard let values = captures(filter, in: line) else {
        if trimmed.range(of: "^Filter\\s+\\d+\\s*:\\s*OFF\\b",
                         options: [.regularExpression, .caseInsensitive]) != nil {
          continue
        }
        if trimmed.range(of: "^(Filter\\s+\\d+\\s*:|GraphicEQ\\s*:)",
                         options: [.regularExpression, .caseInsensitive]) != nil {
          throw ParseError.invalidLine(index + 1)
        }
        continue
      }
      if values[0].caseInsensitiveCompare("OFF") == .orderedSame { continue }
      guard let frequency = Double(values[2]), frequency.isFinite, frequency > 0,
            let gain = Double(values[3]), gain.isFinite,
            let q = Double(values[4]), q.isFinite, q > 0 else {
        throw ParseError.invalidLine(index + 1)
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
        "gain=\(values[3]):precision=f64"
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
