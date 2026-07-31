//
//  AudiophileDSP.swift
//  iina
//

import Foundation

enum AudiophileDSP {
  static func convolution(file: String, dry: String, wet: String,
                          irNormalization: String, precision: String) -> String {
    let path = escapeFilterGraphValue(escapeFilterGraphValue(file))
    return "amovie=filename=\(path)[ir];[in][ir]afir=dry=\(dry):wet=\(wet):" +
      "irnorm=\(irNormalization):precision=\(precision)[out]"
  }

  static func dynamicEqualizer(detectionFrequency: String, detectionQ: String,
                               threshold: String, targetFrequency: String,
                               targetQ: String, mode: String, filterType: String,
                               ratio: String, range: String, attack: String,
                               release: String) -> String {
    return "adynamicequalizer=dfrequency=\(detectionFrequency):dqfactor=\(detectionQ):" +
      "threshold=\(threshold):tfrequency=\(targetFrequency):tqfactor=\(targetQ):" +
      "mode=\(mode):tftype=\(filterType):ratio=\(ratio):range=\(range):" +
      "attack=\(attack):release=\(release):precision=double"
  }

  static func bassManagement(frequency: String, order: String,
                             mainGain: String, subGain: String) -> String {
    return "[in]acrossover=split=\(frequency):order=\(order):precision=double[low][high];" +
      "[low]pan=mono|c0=0.5*c0+0.5*c1,volume=volume=\(subGain)dB:precision=double[sub];" +
      "[high]volume=volume=\(mainGain)dB:precision=double[mains];" +
      "[mains][sub]join=inputs=2:channel_layout=2.1:" +
      "map=0.FL-FL|0.FR-FR|1.FC-LFE[out]"
  }

  static func stereoCorrection(mode: String, width: String, balance: String,
                               leftPolarity: String, rightPolarity: String,
                               phase: String, delay: String) -> String {
    return "stereotools=mode=\(mode):slev=\(width):balance_out=\(balance):" +
      "phasel=\(leftPolarity):phaser=\(rightPolarity):phase=\(phase):delay=\(delay)"
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
