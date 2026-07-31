import Foundation

@main
struct CheckEqualizerAPO {
  static func main() throws {
    if CommandLine.arguments.count > 1 {
      for path in CommandLine.arguments.dropFirst() {
        print(try EqualizerAPOParser.filterGraph(contentsOf: URL(fileURLWithPath: path)))
      }
      return
    }
    try standardAutoEQ_ValidInput_GeneratesCompleteGraph()
    try aliasesAndWhitespace_ValidInput_GenerateSupportedFilters()
    try graphicEQ_ValidInput_GeneratesInterpolatedCurve()
    try fileInput_ValidText_ReadsAndParsesFile()
    try preampOnly_ValidInput_GeneratesHeadroomFilter()
    try invalidInputs_RejectRatherThanApplyPartialCorrection()
    dspGraphs_Parameters_GenerateExactFFmpegGraphs()
    convolution_SpecialPath_EscapesBothParserLevels()
    print("audiophile DSP unit checks passed")
  }

  private static func standardAutoEQ_ValidInput_GeneratesCompleteGraph() throws {
    let input = """
      Preamp: -6.7 dB
      Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 1.23
      Filter 2: OFF PK Fc 400 Hz Gain 2 dB Q 1
      Filter 3: ON LSC Fc 120 Hz Gain 1.5 dB Q 0.7
      Filter 4: ON HS 6dB Fc 8000 Hz Gain -2 dB Q 0.8
      """
    let expected = [
      "volume=volume=-6.7dB:precision=double",
      "equalizer=frequency=105:width_type=q:width=1.23:gain=-3.2:precision=f64",
      "lowshelf=frequency=120:width_type=q:width=0.7:gain=1.5:precision=f64",
      "highshelf=frequency=8000:width_type=q:width=0.8:gain=-2:precision=f64"
    ].joined(separator: ",")
    let actual = try EqualizerAPOParser.filterGraph(input)
    precondition(actual == expected)
  }

  private static func aliasesAndWhitespace_ValidInput_GenerateSupportedFilters() throws {
    let cases = [
      ("peq", "equalizer"),
      ("LS", "lowshelf"),
      ("hs", "highshelf")
    ]
    for (kind, expectedName) in cases {
      let input = "  filter 12: on \(kind) Fc 200.5 Hz Gain +2.25 dB Q .75  "
      let expected = "\(expectedName)=frequency=200.5:width_type=q:width=.75:" +
        "gain=+2.25:precision=f64"
      let actual = try EqualizerAPOParser.filterGraph(input)
      precondition(actual == expected)
    }
    let input = """
      # Disabled unsupported filters must not invalidate a usable preset.
      Filter 1: OFF HP Fc 80 Hz Q 0.7
      Filter 2: ON PK Fc 1000 Hz Gain -1 dB Q 2
      """
    let actual = try EqualizerAPOParser.filterGraph(input)
    precondition(actual ==
      "equalizer=frequency=1000:width_type=q:width=2:gain=-1:precision=f64")
  }

  private static func graphicEQ_ValidInput_GeneratesInterpolatedCurve() throws {
    let input = "GraphicEQ: 20 -10.1; 1000 0; 19871 -3.5"
    let actual = try EqualizerAPOParser.filterGraph(input)
    precondition(actual ==
      "firequalizer=gain='cubic_interpolate(f)':" +
      "gain_entry='entry(20,-10.1);entry(1000,0);entry(19871,-3.5)'")
  }

  private static func fileInput_ValidText_ReadsAndParsesFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("IINA AutoEQ \(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try "Filter 1: ON PK Fc 1000 Hz Gain -1 dB Q 2".write(to: url, atomically: true,
                                                          encoding: .utf8)
    let actual = try EqualizerAPOParser.filterGraph(contentsOf: url)
    precondition(actual ==
      "equalizer=frequency=1000:width_type=q:width=2:gain=-1:precision=f64")
  }

  private static func preampOnly_ValidInput_GeneratesHeadroomFilter() throws {
    let actual = try EqualizerAPOParser.filterGraph("Preamp: -3 dB")
    precondition(actual == "volume=volume=-3dB:precision=double")
  }

  private static func invalidInputs_RejectRatherThanApplyPartialCorrection() throws {
    let cases: [(String, EqualizerAPOParser.ParseError)] = [
      ("", .noSupportedFilters),
      ("GraphicEQ: 20 0", .invalidLine(1)),
      ("GraphicEQ: 20 0; 19 -1", .invalidLine(1)),
      ("GraphicEQ: 20 0; nope -1", .invalidLine(1)),
      ("GraphicEQ: 20 nan; 30 0", .invalidLine(1)),
      ("GraphicEQ: 20 0; inf -1", .invalidLine(1)),
      ("Preamp: loud", .invalidLine(1)),
      ("Filter 1: ON HP Fc 80 Hz Q 0.7", .invalidLine(1)),
      ("Filter 1: ON PK Fc 0 Hz Gain 2 dB Q 1", .invalidLine(1)),
      ("Filter 1: ON PK Fc 100 Hz Gain 2 dB Q 0", .invalidLine(1)),
      ("""
       Filter 1: ON PK Fc 100 Hz Gain -2 dB Q 1
       Filter 2: ON PK Fc nope Hz Gain 3 dB Q 2
       """, .invalidLine(2))
    ]
    for (input, expected) in cases {
      do {
        _ = try EqualizerAPOParser.filterGraph(input)
        preconditionFailure("invalid input was accepted: \(input)")
      } catch let error as EqualizerAPOParser.ParseError {
        precondition(error == expected, "expected \(expected), got \(error)")
      }
    }
  }

  private static func dspGraphs_Parameters_GenerateExactFFmpegGraphs() {
    let dynamic = AudiophileDSP.dynamicEqualizer(
      detectionFrequency: "6000", detectionQ: "3", threshold: "45",
      targetFrequency: "6500", targetQ: "2", mode: "cutabove",
      filterType: "bell", ratio: "3", range: "8", attack: "5", release: "120"
    )
    precondition(dynamic ==
      "adynamicequalizer=dfrequency=6000:dqfactor=3:threshold=45:" +
      "tfrequency=6500:tqfactor=2:mode=cutabove:tftype=bell:ratio=3:" +
      "range=8:attack=5:release=120:precision=double")

    let bass = AudiophileDSP.bassManagement(
      frequency: "90", order: "8th", mainGain: "-1", subGain: "2.5"
    )
    precondition(bass ==
      "[in]acrossover=split=90:order=8th:precision=double[low][high];" +
      "[low]pan=mono|c0=0.5*c0+0.5*c1,volume=volume=2.5dB:precision=double[sub];" +
      "[high]volume=volume=-1dB:precision=double[mains];" +
      "[mains][sub]join=inputs=2:channel_layout=2.1:" +
      "map=0.FL-FL|0.FR-FR|1.FC-LFE[out]")

    let stereo = AudiophileDSP.stereoCorrection(
      mode: "lr>rl", width: "0.8", balance: "-0.1", leftPolarity: "true",
      rightPolarity: "false", phase: "15", delay: "-0.25"
    )
    precondition(stereo ==
      "stereotools=mode=lr>rl:slev=0.8:balance_out=-0.1:" +
      "phasel=true:phaser=false:phase=15:delay=-0.25")
  }

  private static func convolution_SpecialPath_EscapesBothParserLevels() {
    let graph = AudiophileDSP.convolution(
      file: "/tmp/IINA's [left], IR.wav", dry: "0", wet: "1",
      irNormalization: "-1", precision: "double"
    )
    precondition(graph ==
      #"amovie=filename=/tmp/IINA\\\'s \\\[left\\\]\\\, IR.wav[ir];[in][ir]afir=dry=0:wet=1:irnorm=-1:precision=double[out]"#)
  }
}
