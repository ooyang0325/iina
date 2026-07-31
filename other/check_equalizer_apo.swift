import Foundation

@main
struct CheckEqualizerAPO {
  static func main() throws {
    let source = """
      Preamp: -6.7 dB
      Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 1.23
      Filter 2: OFF PK Fc 400 Hz Gain 2 dB Q 1
      Filter 3: ON LSC Fc 120 Hz Gain 1.5 dB Q 0.7
      Filter 4: ON HS 6dB Fc 8000 Hz Gain -2 dB Q 0.8
      """
    let expected = [
      "volume=volume=-6.7dB:precision=double",
      "equalizer=frequency=105:width_type=q:width=1.23:gain=-3.2:precision=double",
      "lowshelf=frequency=120:width_type=q:width=0.7:gain=1.5:precision=double",
      "highshelf=frequency=8000:width_type=q:width=0.8:gain=-2:precision=double"
    ].joined(separator: ",")
    let graph = try EqualizerAPOParser.filterGraph(source)
    precondition(graph == expected)
    do {
      _ = try EqualizerAPOParser.filterGraph("GraphicEQ: 20 0; 25 0")
      preconditionFailure("unsupported input was accepted")
    } catch EqualizerAPOParser.ParseError.noSupportedFilters {
    }
    print("Equalizer APO parser check passed")
  }
}
