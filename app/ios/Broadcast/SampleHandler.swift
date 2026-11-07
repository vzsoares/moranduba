import CoreImage
import ImageIO
import ReplayKit

private let appGroup = "group.io.github.vzsoares.moranduba"
private let framesPerSecond = 15.0

/// Streams the screen to the app over the Unix socket flutter_webrtc's
/// FlutterSocketConnection listens on (`rtc_SSFD` in the app group). Each
/// frame is an HTTP-framed JPEG with Buffer-Width, Buffer-Height and
/// Buffer-Orientation headers, the format its frame reader parses.
final class SampleHandler: RPBroadcastSampleHandler {
  private let queue = DispatchQueue(label: "moranduba.broadcast")
  private let context = CIContext(options: nil)
  private let lock = NSLock()
  private var socket: Int32 = -1
  private var sending = false
  private var lastFrame: CFTimeInterval = 0

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    guard
      let path = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
        .appendingPathComponent("rtc_SSFD").path,
      let connected = connect(to: path)
    else {
      stop("Start sharing from a Moranduba call.")
      return
    }
    socket = connected
  }

  override func broadcastFinished() {
    queue.sync {
      if socket >= 0 { Darwin.close(socket) }
      socket = -1
    }
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    guard sampleBufferType == .video, socket >= 0 else { return }
    let now = CACurrentMediaTime()
    lock.lock()
    let skip = sending || now - lastFrame < 1 / framesPerSecond
    if !skip {
      sending = true
      lastFrame = now
    }
    lock.unlock()
    if skip { return }

    guard let message = frame(sampleBuffer) else {
      done()
      return
    }
    queue.async {
      let sent = self.write(message)
      self.done()
      if !sent { self.stop("Screen sharing ended in Moranduba.") }
    }
  }

  private func done() {
    lock.lock()
    sending = false
    lock.unlock()
  }

  private func stop(_ reason: String) {
    finishBroadcastWithError(
      NSError(
        domain: "Moranduba",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: reason]
      )
    )
  }

  private func frame(_ sampleBuffer: CMSampleBuffer) -> Data? {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    let orientation =
      (CMGetAttachment(
        sampleBuffer,
        key: RPVideoSampleOrientationKey as CFString,
        attachmentModeOut: nil
      ) as? NSNumber)?.uint32Value ?? CGImagePropertyOrientation.up.rawValue
    // Half size keeps the extension under its 50 MB memory limit.
    let image = CIImage(cvPixelBuffer: pixels)
      .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
    guard
      let jpeg = context.jpegRepresentation(
        of: image,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
      )
    else { return nil }

    let message = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1)
      .takeRetainedValue()
    let headers = [
      "Content-Length": "\(jpeg.count)",
      "Buffer-Width": "\(Int(image.extent.width))",
      "Buffer-Height": "\(Int(image.extent.height))",
      "Buffer-Orientation": "\(orientation)",
    ]
    for (name, value) in headers {
      CFHTTPMessageSetHeaderFieldValue(message, name as CFString, value as CFString)
    }
    CFHTTPMessageSetBody(message, jpeg as CFData)
    return CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data?
  }

  /// Runs on [queue]; false once the app closed its end.
  private func write(_ data: Data) -> Bool {
    guard socket >= 0 else { return false }
    return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
      guard let base = buffer.baseAddress else { return false }
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(socket, base + offset, buffer.count - offset)
        if written <= 0 { return false }
        offset += written
      }
      return true
    }
  }

  private func connect(to path: String) -> Int32? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
      Darwin.close(fd)
      return nil
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
        _ = strncpy(chars, path, capacity)
      }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      return nil
    }
    return fd
  }
}
