//
//  AudiophileDSP.swift
//  iina
//

import Foundation

enum AudiophileDSP {
  static func convolution(file: String, dry: String, wet: String,
                          irNormalization: String, precision: String) -> String? {
    guard let dry = number(dry), let wet = number(wet),
          let irNormalization = number(irNormalization),
          let precision = token(precision) else { return nil }
    let path = escapeFilterGraphValue(escapeFilterGraphValue(file))
    return "amovie=filename=\(path)[ir];[in][ir]afir=dry=\(dry):wet=\(wet):" +
      "irnorm=\(irNormalization):precision=\(precision)[out]"
  }

  static func dynamicEqualizer(detectionFrequency: String, detectionQ: String,
                               threshold: String, targetFrequency: String,
                               targetQ: String, mode: String, filterType: String,
                               ratio: String, range: String, attack: String,
                               release: String) -> String? {
    guard let detectionFrequency = number(detectionFrequency),
          let detectionQ = number(detectionQ), let threshold = number(threshold),
          let targetFrequency = number(targetFrequency), let targetQ = number(targetQ),
          let ratio = number(ratio), let range = number(range),
          let attack = number(attack), let release = number(release),
          let mode = token(mode), let filterType = token(filterType) else { return nil }
    return "adynamicequalizer=dfrequency=\(detectionFrequency):dqfactor=\(detectionQ):" +
      "threshold=\(threshold):tfrequency=\(targetFrequency):tqfactor=\(targetQ):" +
      "mode=\(mode):tftype=\(filterType):ratio=\(ratio):range=\(range):" +
      "attack=\(attack):release=\(release):precision=double"
  }

  static func bassManagement(frequency: String, order: String,
                             mainGain: String, subGain: String) -> String? {
    guard let frequency = number(frequency), let mainGain = number(mainGain),
          let subGain = number(subGain), let order = token(order) else { return nil }
    return "[in]acrossover=split=\(frequency):order=\(order):precision=double[low][high];" +
      "[low]pan=mono|c0=0.5*c0+0.5*c1,volume=volume=\(subGain)dB:precision=double[sub];" +
      "[high]volume=volume=\(mainGain)dB:precision=double[mains];" +
      "[mains][sub]join=inputs=2:channel_layout=2.1:" +
      "map=0.FL-FL|0.FR-FR|1.FC-LFE[out]"
  }

  static func stereoCorrection(mode: String, width: String, balance: String,
                               leftPolarity: String, rightPolarity: String,
                               phase: String, delay: String) -> String? {
    guard let width = number(width), let balance = number(balance),
          let phase = number(phase), let delay = number(delay),
          let mode = token(mode), let leftPolarity = token(leftPolarity),
          let rightPolarity = token(rightPolarity) else { return nil }
    return "stereotools=mode=\(mode):slev=\(width):balance_out=\(balance):" +
      "phasel=\(leftPolarity):phaser=\(rightPolarity):phase=\(phase):delay=\(delay)"
  }

  /// Numeric parameters reach here as free text typed into the filter window. Interpolating
  /// them raw let a stray `,` or `:` close the current filter and open another one, so a
  /// value like `0,volume=volume=-20dB` installed a second, working filter. Parse the text
  /// and emit the *parsed* number, never the original string: that rejects the injection and
  /// also normalises literals FFmpeg would refuse, such as Swift-parseable hex floats.
  private static func number(_ value: String) -> String? {
    guard let parsed = Double(value.trimmingCharacters(in: .whitespaces)),
          parsed.isFinite else { return nil }
    // Keep whole numbers whole; "6000.0" is uglier and no more correct than "6000".
    if parsed == parsed.rounded() && abs(parsed) < 1e15 {
      return String(Int64(parsed))
    }
    return String(parsed)
  }

  /// Enumerated parameters come from popup controls, but a saved filter file can be edited
  /// by hand, so they are still an input boundary. Allow only the shapes the real options
  /// use — `bell`, `8th`, `lr>rl`, `true` — and nothing that can terminate a filter.
  private static func token(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          trimmed.range(of: "^[A-Za-z0-9_>.-]+$", options: .regularExpression) != nil else {
      return nil
    }
    return trimmed
  }

  private static func escapeFilterGraphValue(_ value: String) -> String {
    return value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: ":", with: "\\:")
      .replacingOccurrences(of: ";", with: "\\;")
      .replacingOccurrences(of: ",", with: "\\,")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
  }
}
