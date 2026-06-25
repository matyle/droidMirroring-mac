import QuickLookThumbnailing
import AppKit

final class ThumbnailProvider: QLThumbnailProvider {
  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
  ) {
    // M3: open the APK / XAPK via Apk-parser-swift; render the app icon.
    handler(QLThumbnailReply(contextSize: request.maximumSize) { _ in true }, nil)
  }
}
