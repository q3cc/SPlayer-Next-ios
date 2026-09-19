import ImageIO
import SwiftUI

struct NativeLogo: View {
    // Swift Package 的独立 PNG 不走 asset catalog，固定缓存一份小尺寸位图。
    static let image: CGImage = {
        let url = Bundle.module.url(forResource: "SPlayerLogo", withExtension: "png")!
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }()

    var body: some View {
        Image(Self.image, scale: 1, label: Text("SPlayer 标志"))
            .resizable()
            .scaledToFit()
    }
}
