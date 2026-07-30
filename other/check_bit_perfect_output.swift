#!/usr/bin/env swift
//
// Phase 1 check: with physical format following enabled, the Core Audio device must run at the
// source's own sample rate instead of resampling to whatever it happened to be set to.
//
// Plays a short muted sine through the bundled libmpv at 44.1, 48, 96 and 192 kHz and asserts the
// default output device's physical stream format followed each one. Rates the device cannot do are
// reported as skipped, not failed -- a real DAC is not the ideal one on paper.
//
// Usage:  swift other/check_bit_perfect_output.swift [path/to/libmpv.2.dylib]
//
// mpv restores the original physical format when the output is closed (ao_coreaudio.c uninit), so
// this leaves the device as it found it.

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

let rates = [44100, 48000, 96000, 192000]

// MARK: - libmpv, loaded at runtime so this needs no module map or link flags

let libraryPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
  : URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()      // other/
    .deletingLastPathComponent()      // repo root
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
let mpvFree = symbol("mpv_free", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
let mpvTerminate = symbol("mpv_terminate_destroy",
                          as: (@convention(c) (OpaquePointer?) -> Void).self)

// MARK: - Core Audio


/// Reads a Core Audio property into freshly allocated storage, so no zero value of `T` is needed.
func propertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of type: T.Type) -> [T] {
  var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                           mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
    return []
  }
  let count = Int(size) / MemoryLayout<T>.stride
  let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
  defer { buffer.deallocate() }
  guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else {
    return []
  }
  return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 of type: T.Type) -> T? {
  propertyArray(object, selector, scope: scope, of: type).first
}

let device = property(AudioObjectID(kAudioObjectSystemObject),
                      kAudioHardwarePropertyDefaultOutputDevice, of: AudioDeviceID.self) ?? 0
guard device != 0 else {
  FileHandle.standardError.write(Data("no default output device\n".utf8))
  exit(2)
}

let streams = propertyArray(device, kAudioDevicePropertyStreams,
                            scope: kAudioDevicePropertyScopeOutput, of: AudioStreamID.self)
guard let stream = streams.first else {
  FileHandle.standardError.write(Data("default output device exposes no streams\n".utf8))
  exit(2)
}

/// Rates the hardware can actually be programmed to, so an unsupported rate is skipped rather than
/// reported as a regression.
let supportedRates: Set<Int> = Set(
  propertyArray(stream, kAudioStreamPropertyAvailablePhysicalFormats,
                of: AudioStreamRangedDescription.self)
    .flatMap { [Int($0.mSampleRateRange.mMinimum), Int($0.mSampleRateRange.mMaximum)] }
)

func physicalSampleRate() -> Int {
  Int(property(stream, kAudioStreamPropertyPhysicalFormat,
               of: AudioStreamBasicDescription.self)?.mSampleRate ?? 0)
}

// MARK: - Test signal

/// A 1 kHz sine as 16 bit stereo PCM. Written by hand so the check needs no encoder.
func writeSine(rate: Int, seconds: Double, to url: URL) throws {
  let frames = Int(Double(rate) * seconds)
  var data = Data()
  func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

  let dataBytes = frames * 2 * 2
  data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
  data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
  append(UInt16(1)); append(UInt16(2)); append(UInt32(rate))
  append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
  data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
  for frame in 0..<frames {
    let sample = Int16(16384 * sin(2 * Double.pi * 1000 * Double(frame) / Double(rate)))
    append(sample); append(sample)
  }
  try data.write(to: url)
}

// MARK: - Run

func play(_ file: URL) -> Int {
  guard let mpv = mpvCreate() else { return 0 }
  defer { mpvTerminate(mpv) }

  for (name, value) in [("ao", "coreaudio"), ("coreaudio-change-physical-format", "yes"),
                        ("audio-exclusive", "no"), ("vo", "null"), ("mute", "yes"),
                        ("config", "no"), ("msg-level", "all=no"), ("audio-samplerate", "0")] {
    _ = mpvSetOption(mpv, name, value)
  }
  guard mpvInitialize(mpv) >= 0 else { return 0 }

  file.path.withCString { path in
    "loadfile".withCString { load in
      var args: [UnsafePointer<CChar>?] = [load, path, nil]
      _ = mpvCommand(mpv, &args)
    }
  }

  // Wait for the output to actually open before reading the hardware back.
  for _ in 0..<100 {
    Thread.sleep(forTimeInterval: 0.05)
    guard let raw = mpvGetProperty(mpv, "audio-out-params/samplerate") else { continue }
    defer { mpvFree(raw) }
    if !String(cString: raw).isEmpty {
      Thread.sleep(forTimeInterval: 0.3)  // let the format change settle
      return physicalSampleRate()
    }
  }
  return 0
}

let directory = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent("iina-bit-perfect-check")
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

let original = physicalSampleRate()
print("device \(device), stream \(stream), currently \(original) Hz")
print("supported rates: \(supportedRates.sorted().map(String.init).joined(separator: ", "))\n")

var failures = 0
for rate in rates {
  guard supportedRates.contains(rate) else {
    print("SKIP  \(rate) Hz — device cannot be programmed to this rate")
    continue
  }
  let file = directory.appendingPathComponent("sine-\(rate).wav")
  try writeSine(rate: rate, seconds: 1.5, to: file)

  let actual = play(file)
  if actual == rate {
    print("PASS  \(rate) Hz source → device running at \(actual) Hz")
  } else {
    print("FAIL  \(rate) Hz source → device running at \(actual) Hz")
    failures += 1
  }
}

// Core Audio format changes take a moment to propagate, so settle before reading back.
Thread.sleep(forTimeInterval: 1)
let restored = physicalSampleRate()
if restored != original {
  print("\nWARN  device left at \(restored) Hz, was \(original) Hz before the check")
}

print(failures == 0 ? "\nall checked rates followed the source" : "\n\(failures) rate(s) did not follow the source")
exit(failures == 0 ? 0 : 1)
