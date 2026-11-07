/// What a chat attachment is, for display.
enum MediaKind { image, video, audio, pdf, file }

const _byExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'avif': 'image/avif',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'ogv': 'video/ogg',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/ogg',
  'flac': 'audio/flac',
  'aac': 'audio/aac',
  'm4a': 'audio/mp4',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'pdf': 'application/pdf',
};

/// The MIME type the engine accepts for [filename]. Anything unknown goes as
/// `application/octet-stream`, which MIP-04 carries without validation.
String mimeForFilename(String filename) {
  final dot = filename.lastIndexOf('.');
  final extension = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return _byExtension[extension] ?? 'application/octet-stream';
}

MediaKind mediaKind(String mime) => switch (mime.split('/').first) {
  'image' => MediaKind.image,
  'video' => MediaKind.video,
  'audio' => MediaKind.audio,
  _ => mime == 'application/pdf' ? MediaKind.pdf : MediaKind.file,
};
