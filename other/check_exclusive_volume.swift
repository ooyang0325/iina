#!/usr/bin/env swift
//
// Check that exclusive mode drives the device's own volume control instead of scaling samples.
//
// Plays a muted sine through the bundled libmpv on ao_coreaudio_exclusive, then sets mpv's
// `ao-volume` and asserts the Core Audio device's volume followed it. Devices with no settable
// volume (HDMI and most S/PDIF) are reported as skipped, not failed -- there the player is
// expected to keep using its software gain.
//
// Usage:  swift other/check_exclusive_volume.swift [path/to/libmpv.2.dylib]
//
// The device's original volume is restored before exiting.

import CoreAudio
import Darwin
import Foundation

// MARK: - libmpv, loaded at runtime so this needs no module map or link flags

let libraryPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
  : URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("deps/lib/libmpv.2.dylib").path

guard let library = dlopen(libraryPath, RTLD_NOW) else {
  FileHandle.standardError.write(Data("cannot load \(libraryPath): \(String(cString: dlerror()))\n".utf8))
  exit(2)
}

func symbol<T>(_ name: String, as type: T.Type) -> T {
  guard let address = dlsym(library, name) else {
    FileHandle.standardError.write(Data("missing symbol \(name)\n".utf8))
    exit(2)
  }
  return unsafeBitCast(address, to: type)
}

let mpvCreate = symbol("mpv_create", as: (@convention(c) () -> OpaquePointer?).self)
let mpvSetOption = symbol("mpv_set_option_string",
                          as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                               UnsafePointer<CChar>?) -> Int32).self)
let mpvInitialize = symbol("mpv_initialize", as: (@convention(c) (OpaquePointer?) -> Int32).self)
let mpvCommand = symbol("mpv_command",
                        as: (@convention(c) (OpaquePointer?,
                                             UnsafePointer<UnsafePointer<CChar>?>?) -> Int32).self)
let mpvGetProperty = symbol("mpv_get_property_string",
                            as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?)
                                 -> UnsafeMutablePointer<CChar>?).self)
let mpvSetProperty = symbol("mpv_set_property_string",
                            as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?,
                                                 UnsafePointer<CChar>?) -> Int32).self)
let mpvFree = symbol("mpv_free", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
let mpvTerminate = symbol("mpv_terminate_destroy",
                          as: (@convention(c) (OpaquePointer?) -> Void).self)

func property(_ mpv: OpaquePointer?, _ name: String) -> String? {
  guard let raw = mpvGetProperty(mpv, name) else { return nil }
  defer { mpvFree(raw) }
  let value = String(cString: raw)
  return value.isEmpty ? nil : value
}

// MARK: - Core Audio

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
-> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

var deviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
var device = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress,
                                 0, nil, &size, &device) == noErr, device != 0 else {
  FileHandle.standardError.write(Data("no default output device\n".utf8))
  exit(2)
}

/// The volume elements the device actually exposes: a single main control, or the channels it
/// nominates as its stereo pair. Mirrors what ao_coreaudio_exclusive does.
let volumeElements: [AudioObjectPropertyElement] = {
  var main = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput,
                     kAudioObjectPropertyElementMain)
  if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }

  var preferred = address(kAudioDevicePropertyPreferredChannelsForStereo,
                          kAudioDevicePropertyScopeOutput)
  var stereo: (UInt32, UInt32) = (1, 2)
  var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
  AudioObjectGetPropertyData(device, &preferred, 0, nil, &size, &stereo)
  return [stereo.0, stereo.1].filter {
    var channel = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0)
    return AudioObjectHasProperty(device, &channel)
  }
}()

func deviceVolume() -> Double? {
  guard let element = volumeElements.first else { return nil }
  var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
  var scalar = Float32(0)
  var size = UInt32(MemoryLayout<Float32>.size)
  guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &scalar) == noErr else {
    return nil
  }
  return Double(scalar) * 100
}

func setDeviceVolume(_ percent: Double) {
  var scalar = Float32(percent / 100)
  for element in volumeElements {
    var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
    AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
  }
}

guard let originalVolume = deviceVolume() else {
  print("SKIP  the default output device has no settable volume, software gain still applies")
  exit(0)
}

// MARK: - Test signal

let file = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent("iina-exclusive-volume.wav")
do {
  let rate = 48000, frames = 48000 * 20
  var data = Data()
  func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
  let bytes = frames * 4
  data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
  data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
  append(UInt16(1)); append(UInt16(2)); append(UInt32(rate))
  append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
  data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
  for frame in 0..<frames {
    let sample = Int16(12000 * sin(2 * Double.pi * 440 * Double(frame) / Double(rate)))
    append(sample); append(sample)
  }
  try data.write(to: file)
}
defer { try? FileManager.default.removeItem(at: file) }

// MARK: - Run

guard let mpv = mpvCreate() else { exit(2) }
for (name, value) in [("ao", "coreaudio_exclusive"), ("audio-exclusive", "yes"), ("vo", "null"),
                      ("mute", "yes"), ("config", "no"), ("msg-level", "all=no")] {
  _ = mpvSetOption(mpv, name, value)
}
guard mpvInitialize(mpv) >= 0 else { exit(2) }

file.path.withCString { path in
  "loadfile".withCString { load in
    var args: [UnsafePointer<CChar>?] = [load, path, nil]
    _ = mpvCommand(mpv, &args)
  }
}

var ready = false
for _ in 0..<200 where !ready {
  Thread.sleep(forTimeInterval: 0.05)
  ready = property(mpv, "audio-out-params/samplerate") != nil
}
guard ready else {
  mpvTerminate(mpv)
  FileHandle.standardError.write(Data("playback never started\n".utf8))
  exit(2)
}

print("output: \(property(mpv, "current-ao") ?? "?"), device volume \(Int(originalVolume))%")
print("volume elements: \(volumeElements)\n")

var failures = 0

if let reported = property(mpv, "ao-volume").flatMap(Double.init) {
  let matches = abs(reported - originalVolume) < 2
  print("\(matches ? "PASS" : "FAIL")  ao-volume reads the device: \(Int(reported))% vs \(Int(originalVolume))%")
  if !matches { failures += 1 }
} else {
  print("FAIL  ao-volume unavailable, exclusive mode is not exposing the hardware control")
  failures += 1
}

for target in [35.0, 70.0] {
  _ = mpvSetProperty(mpv, "ao-volume", String(format: "%.0f", target))
  Thread.sleep(forTimeInterval: 0.4)
  let actual = deviceVolume() ?? -1
  let matches = abs(actual - target) < 2
  print("\(matches ? "PASS" : "FAIL")  ao-volume \(Int(target))% → device at \(Int(actual))%")
  if !matches { failures += 1 }
}

// Software gain must stay neutral, or exclusive output would not be bit-perfect.
let softVolume = property(mpv, "volume").flatMap(Double.init) ?? -1
let neutral = softVolume == 100
print("\(neutral ? "PASS" : "FAIL")  software volume left neutral at \(Int(softVolume))%")
if !neutral { failures += 1 }

setDeviceVolume(originalVolume)
mpvTerminate(mpv)
Thread.sleep(forTimeInterval: 0.5)
setDeviceVolume(originalVolume)
print("\ndevice volume restored to \(Int(deviceVolume() ?? -1))%")

print(failures == 0 ? "exclusive mode drives the hardware volume"
                    : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
