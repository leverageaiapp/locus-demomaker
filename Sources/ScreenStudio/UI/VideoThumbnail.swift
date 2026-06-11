import SwiftUI
import AVFoundation

/// First-frame thumbnail for a recording, generated off the main thread and
/// cached process-wide so list scrolling never re-decodes the same video.
struct VideoThumbnail: View {
    let url: URL

    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [Color.indigo.opacity(0.55), Color.purple.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: url) {
            if let hit = Self.cache.object(forKey: url as NSURL) {
                image = hit
                return
            }
            guard let generated = await Self.generate(url: url) else { return }
            Self.cache.setObject(generated, forKey: url as NSURL)
            image = generated
        }
    }

    private static func generate(url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // Sample slightly past zero — frame 0 of a screen recording is often
        // still the pre-capture flash and looks washed out.
        let time = CMTime(seconds: 0.3, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
