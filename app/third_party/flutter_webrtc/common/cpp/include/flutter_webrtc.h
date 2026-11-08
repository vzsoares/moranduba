#ifndef PLUGINS_FLUTTER_WEBRTC_HXX
#define PLUGINS_FLUTTER_WEBRTC_HXX

#include "flutter_common.h"

#include "flutter_data_channel.h"
#include "flutter_data_packet_cryptor.h"
#include "flutter_frame_cryptor.h"
#include "flutter_media_stream.h"
#include "flutter_peerconnection.h"
#include "flutter_screen_capture.h"
#include "flutter_video_renderer.h"

#include "libwebrtc.h"
#include "rtc_logging.h"

#include <atomic>

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class FlutterWebRTCPlugin : public flutter::Plugin {
 public:
  virtual BinaryMessenger* messenger() = 0;

  virtual TextureRegistrar* textures() = 0;

  virtual TaskRunner* task_runner() = 0;
};

// Moranduba patch: scales the captured microphone, set by `setCaptureGain`.
// Samples are floats in the int16 range.
class CaptureGain : public RTCAudioProcessing::CustomProcessing {
 public:
  void Initialize(int sample_rate_hz, int num_channels) override {}

  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override {
    const float g = gain.load(std::memory_order_relaxed);
    if (g == 1.0f) return;
    for (int i = 0; i < buffer_size; i++) {
      const float v = buffer[i] * g;
      buffer[i] = v > 32767.0f ? 32767.0f : (v < -32768.0f ? -32768.0f : v);
    }
  }

  void Reset(int new_rate) override {}

  void Release() override {}

  std::atomic<float> gain{1.0f};
};

class FlutterWebRTC : public FlutterWebRTCBase,
                      public FlutterVideoRendererManager,
                      public FlutterMediaStream,
                      public FlutterPeerConnection,
                      public FlutterScreenCapture,
                      public FlutterDataChannel,
                      public FlutterFrameCryptor,
                      public FlutterDataPacketCryptor {
 public:
  FlutterWebRTC(FlutterWebRTCPlugin* plugin);
  virtual ~FlutterWebRTC();

  void HandleMethodCall(const MethodCallProxy& method_call,
                        std::unique_ptr<MethodResultProxy> result);

 private:
  // Never freed: the factory keeps a raw pointer and libwebrtc cannot
  // detach a capture processor (null crashes it).
  CaptureGain* capture_gain_ = nullptr;

  void initLoggerCallback(RTCLoggingSeverity severity);
  RTCLoggingSeverity str2LogSeverity(std::string str);
};

}  // namespace flutter_webrtc_plugin

#endif  // PLUGINS_FLUTTER_WEBRTC_HXX
