import CampaignCore
import SwiftUI

/// How a modal placement is put on screen. The look inside is the app's.
public enum CampaignPresentationStyle: Sendable {
    case sheet
    #if os(iOS)
    case fullScreenCover
    #endif
}

extension View {
    /// Presents `P` whenever the engine has a campaign for it. Closing it in a way the view does not
    /// report (a swipe down) is recorded as `swipe_down`.
    ///
    /// ```swift
    /// RootView()
    ///     .campaignPlacement(TrialOfferPlacement.self, in: campaigns) { offer in
    ///         TrialOfferSheet(values: offer.values, onPrimary: offer.tap,
    ///                         onClose: { offer.dismiss(.secondary) })
    ///     }
    /// ```
    ///
    /// - Parameter isBusy: replaces the engine's check for another full screen being up.
    public func campaignPlacement<P: CampaignPlacement, Content: View>(
        _ placement: P.Type,
        in engine: CampaignEngine,
        style: CampaignPresentationStyle = .sheet,
        isBusy: (@MainActor () -> Bool)? = nil,
        @ViewBuilder content: @escaping (CampaignOffer<P>) -> Content
    ) -> some View {
        modifier(CampaignPlacementModifier(engine: engine, style: style, isBusy: isBusy, content: content))
    }
}

struct CampaignPlacementModifier<P: CampaignPlacement, Body: View>: ViewModifier {
    let engine: CampaignEngine
    let style: CampaignPresentationStyle
    let isBusy: (@MainActor () -> Bool)?
    let content: (CampaignOffer<P>) -> Body

    private var item: Binding<CampaignOffer<P>?> {
        Binding(
            get: { engine.offer(P.self) },
            set: { newValue in
                guard newValue == nil, let presentation = engine.presenting, presentation.placement == P.name else { return }
                Task { await engine.dismiss(presentation, via: .swipeDown) }
            }
        )
    }

    func body(content view: Content) -> some View {
        let presented = view.onAppear { if let isBusy { engine.isBusy = isBusy } }
        switch style {
        case .sheet:
            presented.sheet(item: item) { offer in content(offer) }
        #if os(iOS)
        case .fullScreenCover:
            presented.fullScreenCover(item: item) { offer in content(offer) }
        #endif
        }
    }
}
