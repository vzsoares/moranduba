// Chrome runs a receiver's RTCRtpScriptTransform only if it is attached
// before the receiver's first frame: right after addTrack for receivers we
// create (done in Dart), or synchronously in the "track" event for receivers
// a remote offer creates. dart_webrtc hands track events to Dart a tick late,
// so this covers the second case on dart_webrtc's own worker and key provider
// (set by Dart in morandubaE2ee.keyProviderId).
(() => {
  const e2ee = (window.morandubaE2ee = {
    worker: null,
    keyProviderId: null,
    states: {},
  });

  const NativeWorker = window.Worker;
  window.Worker = class extends NativeWorker {
    constructor(url, options) {
      super(url, options);
      if (String(url).endsWith("e2ee.worker.dart.js")) {
        e2ee.worker = this;
        this.addEventListener("message", (event) => {
          const data = event.data;
          if (data && data.type === "cryptorState" && data.trackId) {
            e2ee.states[data.trackId] = data.state;
          }
        });
      }
    }
  };

  if (!window.RTCPeerConnection || !window.RTCRtpScriptTransform) return;
  const NativePeerConnection = window.RTCPeerConnection;
  window.RTCPeerConnection = class extends NativePeerConnection {
    constructor(...args) {
      super(...args);
      this.addEventListener("track", (event) => {
        const { worker, keyProviderId } = e2ee;
        if (!worker || !keyProviderId || event.receiver.transform) return;
        const trackId = event.track.id;
        const transform = new RTCRtpScriptTransform(worker, {
          msgType: "decode",
          msgId: Math.random().toString(36).slice(2),
          keyProviderId,
          kind: event.track.kind,
          participantId: event.streams[0]?.id ?? "remote",
          trackId,
        });
        event.receiver.transform = transform;
        (e2ee.receivers ??= []).push({ receiver: event.receiver, transform, pc: this });
        e2ee.states[trackId] = "new";
        // The worker builds its cryptor disabled once the transform lands.
        let tries = 0;
        const enable = setInterval(() => {
          worker.postMessage({
            msgType: "enable",
            msgId: Math.random().toString(36).slice(2),
            trackId,
            enabled: true,
          });
          if (++tries >= 20 || e2ee.states[trackId] === "ok") {
            clearInterval(enable);
          }
        }, 500);
      });
    }
  };
})();
