// Chrome runs a receiver's RTCRtpScriptTransform only if it is attached
// before the receiver's first frame: right after addTrack for receivers we
// create (done in Dart), or synchronously in the "track" event for receivers
// a remote offer creates. dart_webrtc hands track events to Dart a tick late,
// so this covers the second case on dart_webrtc's own worker and key provider
// (set by Dart in morandubaE2ee.keyProviderId).
(() => {
  const randomId = () => Math.random().toString(36).slice(2);
  const e2ee = (window.morandubaE2ee = {
    worker: null,
    keyProviderId: null,
    // By track id, for the receivers attached here.
    states: {},
    receivers: [],

    handles(trackId) {
      return e2ee.receivers.some((entry) => entry.trackId === trackId);
    },

    // Links close all call long (redials, relays, mode switches).
    purge() {
      e2ee.receivers = e2ee.receivers.filter((entry) => {
        if (entry.pc.connectionState !== "closed") return true;
        delete e2ee.states[entry.trackId];
        e2ee.worker?.postMessage({
          msgType: "dispose",
          msgId: randomId(),
          trackId: entry.trackId,
          cryptorId: entry.cryptorId,
        });
        return false;
      });
    },

    // Frame cryptors alive in the worker, for tests.
    cryptorCount() {
      const worker = e2ee.worker;
      if (!worker) return Promise.resolve(0);
      const msgId = randomId();
      return new Promise((resolve) => {
        const onMessage = (event) => {
          if (event.data?.msgId !== msgId) return;
          worker.removeEventListener("message", onMessage);
          resolve(event.data.count ?? -1);
        };
        worker.addEventListener("message", onMessage);
        worker.postMessage({ msgType: "cryptorCount", msgId });
      });
    },
  });

  const NativeWorker = window.Worker;
  window.Worker = class extends NativeWorker {
    constructor(url, options) {
      super(url, options);
      if (String(url).endsWith("e2ee.worker.dart.js")) {
        e2ee.worker = this;
        this.addEventListener("message", (event) => {
          const data = event.data;
          if (data?.type !== "cryptorState") return;
          const entry = e2ee.receivers.find((e) => e.cryptorId === data.cryptorId);
          if (entry) e2ee.states[entry.trackId] = data.state;
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
        const cryptorId = randomId();
        const transform = new RTCRtpScriptTransform(worker, {
          msgType: "decode",
          msgId: randomId(),
          keyProviderId,
          kind: event.track.kind,
          participantId: event.streams[0]?.id ?? "remote",
          trackId,
          cryptorId,
        });
        event.receiver.transform = transform;
        e2ee.purge();
        e2ee.receivers.push({ receiver: event.receiver, transform, pc: this, trackId, cryptorId });
        e2ee.states[trackId] = "new";
        // The worker builds its cryptor disabled once the transform lands.
        let tries = 0;
        const enable = setInterval(() => {
          worker.postMessage({
            msgType: "enable",
            msgId: randomId(),
            trackId,
            cryptorId,
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
