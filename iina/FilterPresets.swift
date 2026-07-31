//
//  FilterPresets.swift
//  iina
//
//  Created by lhc on 25/8/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

fileprivate typealias PM = FilterParameter

fileprivate func ffmpegEscape(_ value: String) -> String {
  return value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "'", with: "\\'")
    .replacingOccurrences(of: ":", with: "\\:")
    .replacingOccurrences(of: ";", with: "\\;")
    .replacingOccurrences(of: ",", with: "\\,")
    .replacingOccurrences(of: "[", with: "\\[")
    .replacingOccurrences(of: "]", with: "\\]")
}

fileprivate extension String {
  var ffmpegFilterGraphEscaped: String {
    return ffmpegEscape(ffmpegEscape(self))
  }
}

/**
 A filter preset or template, which contains the filter name and definitions of all parameters.
 */
class FilterPreset {
  typealias Transformer = (FilterPresetInstance) -> MPVFilter

  private static let defaultTransformer: Transformer = { instance in
    return MPVFilter(lavfiFilterFromPresetInstance: instance)
  }

  var name: String
  var params: [String: FilterParameter]

  /// Order of the filter parameters.
  ///
  /// This dictates the order of parameters when the filter string is assembled as well as the order of controls presented to the user
  /// when adding a filter.
  var paramOrder: [String]
  /** Given an instance, create the corresponding `MPVFilter`. */
  var transformer: Transformer

  var localizedName: String {
    return FilterPreset.l10nDic[name] ?? FilterPreset.baseL10nDic[name] ?? name
  }

  init(_ name: String,
       params: [String: FilterParameter],
       paramOrder: String,
       transformer: @escaping Transformer = FilterPreset.defaultTransformer) {
    self.name = name
    self.params = params
    self.paramOrder = paramOrder.isEmpty ? [] : paramOrder.components(separatedBy: ":")
    self.transformer = transformer
  }

  func localizedParamName(_ param: String) -> String {
    let key = "\(name).\(param)"
    return FilterPreset.l10nDic[key] ?? FilterPreset.baseL10nDic[key] ?? param
  }
}

/**
 An instance of a filter preset, with concrete values for each parameter.
 */
class FilterPresetInstance {
  var preset: FilterPreset
  var params: [String: FilterParameterValue] = [:]

  init(from preset: FilterPreset) {
    self.preset = preset
  }

  func value(for name: String) -> FilterParameterValue {
    return params[name] ?? preset.params[name]!.defaultValue
  }
}

/**
 Definition of a filter parameter. It can be one of several types:
 - `text`: A generic string value.
 - `int`: An int value with range. It will be rendered as a slider.
 - `float`: A float value with range. It will be rendered as a slider.
 */
class FilterParameter {
  enum ParamType {
    case text, file, int, float, choose
  }
  var type: ParamType
  var defaultValue: FilterParameterValue
  // for float
  var min: Float?
  var max: Float?
  // for int
  var minInt: Int?
  var maxInt: Int?
  var step: Int?
  // for choose
  var choices: [String] = []

  static func text(defaultValue: String = "") -> FilterParameter {
    return FilterParameter(.text, defaultValue: FilterParameterValue(string: defaultValue))
  }

  static func file() -> FilterParameter {
    return FilterParameter(.file, defaultValue: FilterParameterValue(string: ""))
  }

  static func int(min: Int, max: Int, step: Int = 1, defaultValue: Int = 0) -> FilterParameter {
    let pm = FilterParameter(.int, defaultValue: FilterParameterValue(int: defaultValue))
    pm.minInt = min
    pm.maxInt = max
    pm.step = step
    return pm
  }

  static func float(min: Float, max: Float, defaultValue: Float = 0) -> FilterParameter {
    let pm = FilterParameter(.float, defaultValue: FilterParameterValue(float: defaultValue))
    pm.min = min
    pm.max = max
    return pm
  }

  static func choose(from choices: [String], defaultChoiceIndex: Int = 0) -> FilterParameter {
    guard !choices.isEmpty else { fatalError("FilterParameter: Choices cannot be empty") }
    let pm = FilterParameter(.choose, defaultValue: FilterParameterValue(string: choices[defaultChoiceIndex]))
    pm.choices = choices
    return pm
  }

  private init(_ type: ParamType, defaultValue: FilterParameterValue) {
    self.type = type
    self.defaultValue = defaultValue
  }
}

/**
 The structure to store values of different param types.
 */
struct FilterParameterValue {
  private var _stringValue: String?
  private var _intValue: Int?
  private var _floatValue: Float?

  var stringValue: String {
    return _stringValue ?? _intValue?.description ?? _floatValue?.description ?? ""
  }

  var intValue: Int {
    return _intValue ?? 0
  }

  var floatValue: Float {
    return _floatValue ?? 0
  }

  init(string: String) {
    self._stringValue = string
  }

  init(int: Int) {
    self._intValue = int
  }

  init(float: Float) {
    self._floatValue = float
  }
}

/** Related data. */

extension FilterPreset {
  /** Preloaded localization. */
  static let l10nDic: [String: String] = {
    guard let filePath = Bundle.main.path(forResource: "FilterPresets", ofType: "strings"),
      let dic = NSDictionary(contentsOfFile: filePath) as? [String : String] else {
        return [:]
    }
    return dic
  }()

  static let baseL10nDic: [String: String] = {
    guard let filePath = Bundle.main.path(forResource: "FilterPresets", ofType: "strings",
                                          inDirectory: nil, forLocalization: "Base"),
          let dic = NSDictionary(contentsOfFile: filePath) as? [String: String] else {
      return [:]
    }
    return dic
  }()

  static private let customMPVFilterPreset = FilterPreset("custom_mpv", params: ["name": PM.text(defaultValue: ""), "string": PM.text(defaultValue: "")], paramOrder: "name:string") { instance in
      return MPVFilter(rawString: instance.value(for: "name").stringValue + "=" + instance.value(for: "string").stringValue)!
  }
  // custom ffmpeg
  static private let customFFmpegFilterPreset = FilterPreset("custom_ffmpeg", params: [ "name": PM.text(defaultValue: ""), "string": PM.text(defaultValue: "") ], paramOrder: "name:string") { instance in
    return MPVFilter(name: "lavfi", label: nil, paramString: "[\(instance.value(for: "name").stringValue)=\(instance.value(for: "string").stringValue)]")
  }

  /** All filter presets. */
  static let vfPresets: [FilterPreset] = [
    // crop
    FilterPreset("crop", params: [
      "x": PM.text(), "y": PM.text(),
      "w": PM.text(), "h": PM.text()
    ], paramOrder: "w:h:x:y") { instance in
      return MPVFilter(mpvFilterFromPresetInstance: instance)
    },
    // expand
    FilterPreset("expand", params: [
      "x": PM.text(), "y": PM.text(),
      "w": PM.text(), "h": PM.text(),
      "aspect": PM.text(defaultValue: "0"),
      "round": PM.text(defaultValue: "1")
    ], paramOrder: "w:h:x:y:aspect:round") { instance in
      return MPVFilter(mpvFilterFromPresetInstance: instance)
    },
    // From the FFmpeg 6.0 documentation for the unsharp filter you would expect the luma matrix
    // horizontal and vertical size parameters to be limited to a maximum of 23. This is clearly
    // spelled out in the documentation. However FFmpeg imposes an additional restriction on the
    // combined size of these two parameters that is not currently mentioned in the documentation.
    // If this size is exceeded FFmpeg will reject the filter reporting the error message
    // "luma or chroma or alpha matrix size too big". To adhere to this restriction the matrix size
    // maximum must be 13. See issue #4259 for details.
    // sharpen
    FilterPreset("sharpen", params: [
      "amount": PM.float(min: 0, max: 1.5),
      "msize": PM.int(min: 3, max: 13, step: 2, defaultValue: 5)
    ], paramOrder: "msize:amount") { instance in
      return MPVFilter.unsharp(amount: instance.value(for: "amount").floatValue,
                               msize: instance.value(for: "msize").intValue)
    },
    // blur
    FilterPreset("blur", params: [
      "amount": PM.float(min: 0, max: 1.5),
      "msize": PM.int(min: 3, max: 13, step: 2, defaultValue: 5)
    ], paramOrder: "msize:amount") { instance in
      return MPVFilter.unsharp(amount: -instance.value(for: "amount").floatValue,
                               msize: instance.value(for: "msize").intValue)
    },
    // delogo
    FilterPreset("delogo", params: [
      "x": PM.text(defaultValue: "1"),
      "y": PM.text(defaultValue: "1"),
      "w": PM.text(defaultValue: "1"),
      "h": PM.text(defaultValue: "1")
    ], paramOrder: "x:y:w:h"),
    // invert color
    FilterPreset("negative", params: [:], paramOrder: "") { instance in
      return MPVFilter(lavfiName: "lutrgb", label: nil, paramDict: [
          "r": "negval", "g": "negval", "b": "negval"
        ])
    },
    // flip
    FilterPreset("vflip", params: [:], paramOrder: "") { instance in
      return MPVFilter(mpvFilterFromPresetInstance: instance)
    },
    // mirror
    FilterPreset("hflip", params: [:], paramOrder: "") { instance in
      return MPVFilter(mpvFilterFromPresetInstance: instance)
    },
    // 3d lut
    FilterPreset("lut3d", params: [
      "file": PM.text(),
      "interp": PM.choose(from: ["nearest", "trilinear", "tetrahedral"], defaultChoiceIndex: 0)
    ], paramOrder: "file:interp") { instance in
      return MPVFilter(lavfiName: "lut3d", label: nil, paramDict: [
        "file": instance.value(for: "file").stringValue,
        "interp": instance.value(for: "interp").stringValue,
        ])
    },
    // custom
    customMPVFilterPreset,
    customFFmpegFilterPreset
  ]

  static let afPresets: [FilterPreset] = [
    FilterPreset("dsp_headroom", params: [
      "gain": PM.text(defaultValue: "-3")
    ], paramOrder: "gain") { instance in
      return MPVFilter(lavfiName: "volume", label: nil, paramDict: [
        "volume": "\(instance.value(for: "gain").stringValue)dB",
        "precision": "double"
      ])
    },
    FilterPreset("dsp_parametric_eq", params: [
      "frequency": PM.text(defaultValue: "1000"),
      "gain": PM.text(defaultValue: "0"),
      "q": PM.text(defaultValue: "1"),
      "channels": PM.text(defaultValue: "all")
    ], paramOrder: "frequency:gain:q:channels") { instance in
      return MPVFilter(lavfiName: "equalizer", label: nil, paramDict: [
        "frequency": instance.value(for: "frequency").stringValue,
        "gain": instance.value(for: "gain").stringValue,
        "width_type": "q",
        "width": instance.value(for: "q").stringValue,
        "channels": instance.value(for: "channels").stringValue,
        "precision": "double"
      ])
    },
    FilterPreset("dsp_convolution", params: [
      "file": PM.file(),
      "dry": PM.text(defaultValue: "0"),
      "wet": PM.text(defaultValue: "1"),
      "irnorm": PM.text(defaultValue: "1"),
      "precision": PM.choose(from: ["double", "float", "auto"])
    ], paramOrder: "file:dry:wet:irnorm:precision") { instance in
      let file = instance.value(for: "file").stringValue.ffmpegFilterGraphEscaped
      let graph = """
        amovie=filename=\(file)[ir];[in][ir]afir=dry=\(instance.value(for: "dry").stringValue):\
        wet=\(instance.value(for: "wet").stringValue):irnorm=\(instance.value(for: "irnorm").stringValue):\
        precision=\(instance.value(for: "precision").stringValue)[out]
        """
      return MPVFilter(name: "lavfi", label: nil, paramString: "[\(graph)]")
    },
    FilterPreset("dsp_crossfeed", params: [
      "strength": PM.text(defaultValue: "0.2"),
      "range": PM.text(defaultValue: "0.5"),
      "slope": PM.text(defaultValue: "0.5"),
      "level_in": PM.text(defaultValue: "0.9"),
      "level_out": PM.text(defaultValue: "1")
    ], paramOrder: "strength:range:slope:level_in:level_out"),
    FilterPreset("dsp_speaker_mix", params: [
      "matrix": PM.text(defaultValue: "stereo|c0=c0|c1=c1")
    ], paramOrder: "matrix") { instance in
      return MPVFilter(lavfiName: "pan", label: nil,
                       params: [instance.value(for: "matrix").stringValue])
    },
    FilterPreset("dsp_speaker_delay", params: [
      "delays": PM.text(defaultValue: "0|0"),
      "all": PM.choose(from: ["false", "true"])
    ], paramOrder: "delays:all") { instance in
      return MPVFilter(lavfiName: "adelay", label: nil, paramDict: [
        "delays": instance.value(for: "delays").stringValue,
        "all": instance.value(for: "all").stringValue
      ])
    },
    FilterPreset("dsp_limiter", params: [
      "ceiling": PM.text(defaultValue: "0.891251"),
      "attack": PM.text(defaultValue: "5"),
      "release": PM.text(defaultValue: "50")
    ], paramOrder: "ceiling:attack:release") { instance in
      return MPVFilter(lavfiName: "alimiter", label: nil, paramDict: [
        "limit": instance.value(for: "ceiling").stringValue,
        "attack": instance.value(for: "attack").stringValue,
        "release": instance.value(for: "release").stringValue,
        "level": "false",
        "latency": "true"
      ])
    },
    customMPVFilterPreset,
    customFFmpegFilterPreset
  ]
}
