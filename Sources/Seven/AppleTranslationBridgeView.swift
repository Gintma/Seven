import SwiftUI
import Translation

@available(macOS 15.0, *)
struct AppleTranslationBridgeRoot: View {
    @ObservedObject var model: TranslationModel

    var body: some View {
        Group {
            if let request = model.appleTranslationRequest {
                ThemePalette.transparent
                    .frame(width: 0, height: 0)
                    .translationTask(
                        source: request.sourceIdentifier.map(Locale.Language.init(identifier:)),
                        target: Locale.Language(identifier: request.targetIdentifier)
                    ) { session in
                        do {
                            if request.prepareOnly {
                                try await session.prepareTranslation()
                                model.completeApplePreparation(request)
                            } else {
                                let response = try await session.translate(request.text)
                                model.completeAppleTranslation(request, text: response.targetText)
                            }
                        } catch {
                            model.failAppleTranslation(request, error: error)
                        }
                    }
                    .id(request.id)
            } else {
                ThemePalette.transparent.frame(width: 0, height: 0)
            }
        }
    }
}
