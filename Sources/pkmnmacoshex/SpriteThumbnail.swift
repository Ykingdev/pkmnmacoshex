import SwiftUI
import Gen3Save

/// One Pokémon's artwork, loaded lazily and left as a quiet placeholder when the
/// species can't be resolved or the network isn't there.
struct SpriteThumbnail: View {
    let mon: Gen3Mon
    let shiny: Bool
    let library: SpriteLibrary
    var size: CGFloat = 52

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Text("\(mon.species)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .background {
            if shiny {
                // A shiny gets a warm halo so it reads as special at a glance.
                RoundedRectangle(cornerRadius: 10)
                    .fill(RadialGradient(colors: [.yellow.opacity(0.35), .clear],
                                         center: .center, startRadius: 2, endRadius: size * 0.7))
            }
        }
        .task(id: "\(mon.offset)-\(mon.species)-\(shiny)") {
            if let cached = library.cachedSprite(for: mon, shiny: shiny) {
                image = cached
            } else {
                image = await library.sprite(for: mon, shiny: shiny)
            }
        }
    }
}
