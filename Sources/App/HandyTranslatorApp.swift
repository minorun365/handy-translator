import SwiftUI

@main
struct HandyTranslatorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .preferredColorScheme(.light)
            #if os(macOS)
                .frame(width: 393, height: 852)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}

/// 色と寸法。面は白と灰の2段、文字は3段、色は録音中の赤だけ。
enum Theme {
    static let background = Color.white
    static let surface = Color(red: 0.965, green: 0.965, blue: 0.97)
    static let ink = Color(red: 0.086, green: 0.086, blue: 0.102)
    static let sub = Color(red: 0.36, green: 0.36, blue: 0.40)
    static let mute = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let hairline = Color(red: 0.086, green: 0.086, blue: 0.102).opacity(0.08)
    static let live = Color(red: 0.80, green: 0.22, blue: 0.18)
    static let good = Color(red: 0.16, green: 0.55, blue: 0.36)
    static let edge: CGFloat = 24
}
