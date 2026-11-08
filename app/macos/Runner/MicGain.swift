import FlutterMacOS
import Foundation
import WebRTC
import flutter_webrtc

/// Scales the captured microphone before it is encoded.
final class MicGain: NSObject, ExternalAudioProcessingDelegate {
  static let shared = MicGain()

  private let lock = NSLock()
  private var gain: Float = 1
  private var attached = false

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "moranduba/mic_gain", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "set",
        let args = call.arguments as? [String: Any],
        let gain = args["gain"] as? Double
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      shared.set(Float(gain))
      result(true)
    }
  }

  private func set(_ value: Float) {
    lock.lock()
    gain = value
    lock.unlock()
    if !attached {
      AudioManager.sharedInstance().capturePostProcessingAdapter.addProcessing(self)
      attached = true
    }
  }

  func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {}

  // Samples are floats in the int16 range.
  func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
    lock.lock()
    let g = gain
    lock.unlock()
    if g == 1 { return }
    for channel in 0..<audioBuffer.channels {
      let samples = audioBuffer.rawBuffer(forChannel: channel)
      for i in 0..<audioBuffer.frames {
        samples[i] = min(max(samples[i] * g, -32768), 32767)
      }
    }
  }

  func audioProcessingRelease() {}
}
