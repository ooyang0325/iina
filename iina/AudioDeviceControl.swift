//
//  AudioDeviceControl.swift
//  iina
//

import CoreAudio
import Foundation

/// Direct access to the Core Audio hardware layer, for the things mpv cannot do from where it sits.
///
/// Two jobs, both concerning which device is used and at what rate:
///
/// * Resolving the default output device to a concrete UID. mpv's `auto` device means "whatever is
///   default at the moment the output opens", which stops being good enough once exclusive mode is
///   involved: taking hog mode makes macOS move the default output elsewhere, so the next time the
///   output is reopened `auto` resolves to a different device than the one being played through.
/// * Setting a device's nominal sample rate. This is a hardware layer property, so unlike mpv's
///   `--coreaudio-change-physical-format` it works whichever output driver is playing, including
///   AVFoundation, and it needs neither exclusive access nor hog mode.
enum AudioDeviceControl {

  private static func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
  }

  /// Read a Core Audio property into freshly allocated storage.
  private static func values<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of type: T.Type
  ) -> [T] {
    var address = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else {
      return []
    }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
  }

  /// The current default output device, or `nil` if there is none.
  static var defaultOutputDevice: AudioDeviceID? {
    values(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
           of: AudioDeviceID.self).first.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
  }

  /// The unique identifier of the given device, which is what mpv's `--audio-device` takes after
  /// its `<driver>/` prefix.
  static func uid(of device: AudioDeviceID) -> String? {
    var address = address(kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFTypeRef?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else {
      return nil
    }
    return uid?.takeRetainedValue() as String?
  }

  /// The unique identifier of the current default output device.
  static var defaultOutputDeviceUID: String? {
    defaultOutputDevice.flatMap(uid(of:))
  }

  /// The sample rates the given device can be set to.
  static func availableRates(of device: AudioDeviceID) -> [Double] {
    // Continuous ranges are reported as a min and max that differ; every device seen in practice
    // reports discrete rates, so take the endpoints and let the caller match on them.
    let ranges = values(device, kAudioDevicePropertyAvailableNominalSampleRates,
                        of: AudioValueRange.self)
    return Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
  }

  /// The rate the given device is currently running at.
  static func rate(of device: AudioDeviceID) -> Double? {
    values(device, kAudioDevicePropertyNominalSampleRate, of: Double.self).first
  }

  /// Set the given device's sample rate, returning whether the hardware took it.
  @discardableResult
  static func setRate(_ rate: Double, of device: AudioDeviceID) -> Bool {
    var address = address(kAudioDevicePropertyNominalSampleRate)
    var value = rate
    guard AudioObjectSetPropertyData(device, &address, 0, nil,
                                     UInt32(MemoryLayout<Double>.size), &value) == noErr else {
      return false
    }
    // The change is asynchronous, so confirm rather than assume.
    for _ in 0..<20 {
      if let now = self.rate(of: device), abs(now - rate) < 1 { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return false
  }

  /// The best rate to run a device at for a source at `sourceRate`.
  ///
  /// Matching the source exactly is always best. Failing that, prefer a rate in a whole-number
  /// ratio with it, in either direction, since that is a plain decimation or interpolation rather
  /// than an arbitrary conversion: 384 kHz through a 96 kHz device is a quarter, 22.05 kHz through
  /// an 88.2 kHz device is a quadruple. A source with no such relation to anything on offer falls
  /// back to the highest rate available, which gives the resampler the most room.
  ///
  /// This is deliberately the same rule `ca_asbd_is_better` applies in the fork's mpv, so that the
  /// two drivers land on the same rate for the same file.
  static func bestRate(for sourceRate: Double, from available: [Double]) -> Double? {
    guard !available.isEmpty, sourceRate > 0 else { return nil }
    if let exact = available.first(where: { abs($0 - sourceRate) < 1 }) { return exact }
    let ratio = available.filter { rate in
      let (lo, hi) = (min(rate, sourceRate), max(rate, sourceRate))
      return lo > 0 && abs((hi / lo).rounded() * lo - hi) < 1
    }
    return ratio.last ?? available.last
  }
}
