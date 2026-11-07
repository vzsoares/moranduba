// Shows incoming-call pushes from a group's SFU while no Moranduba window is
// in front. The push names no group (the SFU never learns one); opening the
// app finds the call and rings there. Registered once per SFU, each with its
// own scope, since a registration holds one push subscription.
const tag = "ring";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    return;
  }
  if (data.t === "stop") {
    event.waitUntil(
      self.registration
        .getNotifications({ tag })
        .then((open) => open.forEach((n) => n.close())),
    );
    return;
  }
  if (data.t !== "ring") return;
  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((windows) => {
        if (windows.some((w) => w.visibilityState === "visible")) return;
        return self.registration.showNotification("Incoming call", {
          body: "Open Moranduba to answer.",
          tag,
          renotify: true,
          requireInteraction: true,
          icon: new URL("icons/Icon-192.png", self.location).href,
        });
      }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const app = new URL("./", self.location).href;
  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((windows) => {
        const open = windows.find((w) => w.url.startsWith(app));
        return open ? open.focus() : self.clients.openWindow(app);
      }),
  );
});
