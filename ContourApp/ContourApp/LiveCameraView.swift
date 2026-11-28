//
//  liveCameraView.swift
//  ContourApp
//
//  Created by Evan on 9/26/26.
//

import ContourCore
import ContourFeedback
import SwiftUI
import UIKit

struct LiveCameraView: View {
    let camera: CameraService
    let pipeline: ContourPipeline
    let experience: CameraLaunchModel
    @AccessibilityFocusState private var statusFocused: Bool
    @State private var showMessageDetails = false
    @State private var showFeedbackSettings = false
    @Namespace private var glassNamespace
    @Namespace private var headerActionsNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didLaunch = false
    @State private var cameraLaunchUnavailable = false
    @State private var headerBounds: CGRect = .zero
    @State private var displayedButtons: [SurfaceMap.Button] = []
    @State private var displayedReferenceID: UUID?
    @State private var scanWasInFlight = false
    @State private var scanRequestID = UUID()
    @State private var panelDetent: PanelDetent = .collapsed
    @State private var namedRowHeight: CGFloat = 52
    @State private var allControlsHeight: CGFloat = 140
    @State private var dockActionsHeight: CGFloat = 110
    // Keep the last finger-driven height until the snap transaction commits.
    // GestureState resets before onEnded and used to briefly reopen the panel.
    @State private var panelDragHeight: CGFloat?
    @State private var panelDragStartHeight: CGFloat?
    @State private var headerActionsBounds: CGRect = .zero

    private enum PanelLayout {
        // Three stops: Display buttons, named buttons (default expansion), then all buttons.
        static let primaryDiameter: CGFloat = 80
        static let accessoryDiameter: CGFloat = 62
        static let edgeInset: CGFloat = 8
        static let grabberHeight: CGFloat = 32
    }

    private enum PanelGesture {
        // Points of movement required to distinguish a pull from a tap.
        static let minimumDistance: CGFloat = 6
        // Points per second; a fast flick may skip the intermediate stop.
        static let fastSwipeVelocity: CGFloat = 900
        // Fraction of the remaining height needed for a direct, slow collapse.
        static let directCollapseFraction: CGFloat = 0.55
    }

    private enum PanelDetent: Int {
        case collapsed, named, all

        var accessibilityName: String {
            switch self {
            case .collapsed: "Display buttons"
            case .named: "Named buttons"
            case .all: "All buttons, including unlabelled buttons"
            }
        }
    }

    private var hasNamedButtons: Bool {
        displayedButtons.contains { readableLabel(for: $0) != nil }
    }

    private var hasUnlabelledButtons: Bool {
        displayedButtons.contains { readableLabel(for: $0) == nil }
    }

    private var defaultExpandedDetent: PanelDetent {
        hasNamedButtons ? .named : .all
    }

    private enum MotionTiming {
        // Shared timing for glass transitions.
        static let animationDurationSeconds: Double = 0.45
    }

    private struct SelectionAnimationKey: Equatable {
        let referenceID: UUID?
        let scanning: Bool
        let working: Bool
        let requestID: UUID
        let reduceMotion: Bool
    }

    private var glassAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: MotionTiming.animationDurationSeconds)
    }

    /// Header controls share the same material as the status card.
    private let headerGlass: Glass = .regular

    private var selectionAnimationKey: SelectionAnimationKey {
        SelectionAnimationKey(
            referenceID: didLaunch
                ? (experience.scanning ? displayedReferenceID
                   : pipeline.canGuide && !(experience.map?.buttons.isEmpty ?? true)
                       ? pipeline.panelReference?.photo.id : nil)
                : nil,
            scanning: experience.scanning, working: experience.busy,
            requestID: scanRequestID, reduceMotion: reduceMotion)
    }
    #if DEBUG
    @State private var showDeveloperTools = false
    #endif

    private var canRetryCamera: Bool {
        cameraLaunchUnavailable || (!experience.ready && (didLaunch || experience.error != nil))
    }

    private var primaryAction: (title: String, symbol: String, hint: String) {
        if experience.busy {
            return ("Stop", "stop.fill", "Cancels the current scan, microphone, or guidance.")
        }
        if canRetryCamera {
            return ("Retry camera", "arrow.clockwise", "Tries to start the camera again.")
        }
        if didLaunch && experience.hasSelectionContent {
            return ("Say a button", "microphone.fill", "Listens for a button name for up to eight seconds.")
        }
        return ("Scan panel", "camera.viewfinder", "Photographs and identifies the panel's buttons.")
    }

    private var orderedButtons: [SurfaceMap.Button] {
        // Stable sorting preserves map order for buttons at the same origin.
        (experience.map?.buttons ?? []).sorted {
            let lhs = $0.bounds.origin
            let rhs = $1.bounds.origin
            return (lhs.y, lhs.x) < (rhs.y, rhs.x)
        }
    }

    private func readableLabel(for button: SurfaceMap.Button) -> String? {
        guard let label = button.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        return label
    }

    private func positionDescription(for button: SurfaceMap.Button) -> String {
        let center = button.bounds.center
        let vertical = center.y < 1.0 / 3 ? "top" : center.y > 2.0 / 3 ? "bottom" : "middle"
        let horizontal = center.x < 1.0 / 3 ? "left" : center.x > 2.0 / 3 ? "right" : "center"
        return "\(vertical) \(horizontal)"
    }

    private func scanPanel() {
        guard experience.ready else { return }
        // Track the UI request synchronously, including scans that finish within
        // one render pass and never expose their intermediate scanning state.
        scanWasInFlight = true
        scanRequestID = UUID()
        experience.scan()
    }

    private var canRescan: Bool {
        // The primary button already handles first scan, empty results and unclear outlines.
        didLaunch && experience.ready && experience.hasSelectionContent && !experience.busy
            && !experience.scanning && !experience.listening && !experience.guiding
    }

    private enum HeaderActionsLayout {
        static let buttonSize: CGFloat = 52
        // Match the layout gap to the native morph threshold, as in Apple's example.
        static let spacing: CGFloat = 8
        static var width: CGFloat {
            #if DEBUG
            buttonSize * 2 + spacing
            #else
            buttonSize
            #endif
        }
    }

    /// A single measured slot anchors the native controls. It contains no artwork.
    private var headerActionsSlot: some View {
        Color.clear
            .frame(width: HeaderActionsLayout.width, height: HeaderActionsLayout.buttonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("launch-controls-layout"))
            } action: { headerActionsBounds = $0 }
    }

    private func headerActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .font(.title3)
            .glassForeground()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerActions: some View {
        let diameter = HeaderActionsLayout.buttonSize
        let sourceX = HeaderActionsLayout.width - diameter / 2
        let settingsX = diameter / 2

        return GlassEffectContainer(spacing: HeaderActionsLayout.spacing) {
            ZStack {
                #if DEBUG
                Button {
                    Task {
                        experience.stop()
                        await experience.waitForWork()
                        showDeveloperTools = true
                    }
                } label: {
                    headerActionLabel("Developer tools", symbol: "wrench.and.screwdriver")
                }
                .headerGlassControl(headerGlass, id: "developer-tools", in: headerActionsNamespace,
                                    diameter: diameter, x: sourceX)
                .accessibilityHint("Stops current work and opens the developer tools.")
                #endif

                Button { showFeedbackSettings = true } label: {
                    headerActionLabel("Feedback settings", symbol: "slider.horizontal.3")
                }
                .headerGlassControl(headerGlass, id: "feedback-settings", in: headerActionsNamespace,
                                    diameter: diameter, x: settingsX)
                .accessibilityHint("Adjusts sound, voice, and vibration feedback.")
            }
        }
        .frame(width: HeaderActionsLayout.width, height: diameter)
        .accessibilitySortPriority(3)
    }

    private var cameraControls: some View {
        GeometryReader { geo in
            let statusHeight = max(0, (geo.size.height + geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2
                                   - min(210, geo.size.height * 0.5) / 2 - 32)
            ZStack {
                if !headerBounds.isEmpty {
                    Color.clear
                        .frame(width: headerBounds.width, height: headerBounds.height)
                        .glassEffect(headerGlass, in: .rect(cornerRadius: 32))
                        .position(x: headerBounds.midX, y: headerBounds.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if !headerActionsBounds.isEmpty {
                    headerActions
                        .position(x: headerActionsBounds.midX, y: headerActionsBounds.midY)
                }

                ViewThatFits(in: .vertical) {
                    statusCard(compact: false)
                    statusCard(compact: true)
                    statusCard(compact: true, minimal: true)
                }
                .frame(height: statusHeight, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                bottomControls(in: geo)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "launch-controls-layout")
        }
    }

    private func bottomControls(in geo: GeometryProxy) -> some View {
        let gap: CGFloat = 12
        let inset = PanelLayout.edgeInset
        let bottom = geo.size.height + geo.safeAreaInsets.bottom - inset
        // The tray already ends one inset above the screen edge.
        let bottomPadding = max(0, geo.safeAreaInsets.bottom - inset) + 4
        let width = max(0, geo.size.width - 2 * inset)
        let hasChoices = !displayedButtons.isEmpty
        let choicesReady = experience.hasSelectionContent && !experience.scanning
            && displayedReferenceID == pipeline.panelReference?.photo.id
        let grabberHeight = hasChoices ? PanelLayout.grabberHeight : 0
        let available = max(0, bottom - headerBounds.maxY - dockActionsHeight - bottomPadding - gap - grabberHeight)
        let namedHeight = min(available, namedRowHeight + 16)
        let allHeight = min(available, max(namedHeight, allControlsHeight + 16))
        let canDisplayButtons = choicesReady && allHeight > 0
        let restingHeight = panelDetent == .collapsed ? 0 : panelDetent == .named ? namedHeight : allHeight
        let height = hasChoices ? min(allHeight, max(0, panelDragHeight ?? restingHeight)) : 0
        let expansion = min(1, height / max(1, namedHeight))
        let panelShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(32)), isUniform: true)

        return VStack(spacing: 0) {
            if hasChoices {
                panelGrabber(restingHeight: restingHeight, collapsedHeight: 0, allHeight: allHeight)
                    .opacity(canDisplayButtons ? 1 : 0)
                    .allowsHitTesting(canDisplayButtons)
                    .accessibilityHidden(!canDisplayButtons)

                let named = displayedButtons.filter { readableLabel(for: $0) != nil }
                let unlabelled = displayedButtons.filter { readableLabel(for: $0) == nil }
                let showsUnlabelled = !unlabelled.isEmpty
                    && (panelDetent == .all || named.isEmpty || height > namedHeight)
                ScrollView(.vertical) {
                    selectionControls(namedButtons: named, unlabelledButtons: unlabelled,
                                      showUnlabelled: showsUnlabelled)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            allControlsHeight = $0
                        }
                        // Keep the full detent measured without scrolling into its hidden row.
                        .frame(height: showsUnlabelled ? nil : namedRowHeight, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .padding(.horizontal, 20)
                .frame(width: width, height: height, alignment: .top)
                .clipped()
                .contentShape(.interaction, Rectangle())
                .opacity(expansion)
                .disabled(!choicesReady)
                .allowsHitTesting(height > 0 && choicesReady)
                .accessibilityHidden(height == 0 || !choicesReady)
            }

            dockActions(width: width, restingHeight: restingHeight, allHeight: allHeight,
                        showsDisplayButton: hasChoices && panelDetent == .collapsed,
                        canDisplayButtons: canDisplayButtons)
                .padding(.top, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockActionsHeight = $0 }
        }
        .padding(.bottom, bottomPadding)
        .frame(width: width)
        .background {
            Color.clear
                .glassEffect(.clear, in: panelShape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        .offset(y: geo.safeAreaInsets.bottom - inset)
    }

    private func dockActions(width: CGFloat, restingHeight: CGFloat, allHeight: CGFloat,
                             showsDisplayButton: Bool, canDisplayButtons: Bool) -> some View {
        let slotWidth = min(96, width / 3)
        let mainDiameter = min(PanelLayout.primaryDiameter, slotWidth)
        let sideDiameter = min(PanelLayout.accessoryDiameter, slotWidth)
        let glassSpacing = max(0, slotWidth - (mainDiameter + sideDiameter) / 2)
        let centerX = width / 2
        let centerY = mainDiameter / 2
        let main = primaryAction
        let showsRescan = canRescan
        let rescanX = showsRescan ? centerX - slotWidth : centerX
        let rescanDiameter = showsRescan ? sideDiameter : min(1, sideDiameter)

        return VStack(spacing: 5) {
            GlassEffectContainer(spacing: glassSpacing) {
                ZStack {
                    // Keep the rescan glass alive as its circle moves into and out of the main circle.
                    Color.clear
                        .frame(width: rescanDiameter, height: rescanDiameter)
                        .glassEffect(.regular, in: Circle())
                        .glassEffectID("rescan", in: glassNamespace)
                        .position(x: rescanX, y: centerY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    dockAction(title: main.title, symbol: main.symbol, id: "primary",
                               diameter: mainDiameter, hint: main.hint) {
                        if experience.busy { experience.stop() }
                        else if canRetryCamera { experience.setActive(true) }
                        else if !experience.ready { return }
                        else if !experience.hasSelectionContent { scanPanel() }
                        else { experience.sayAButton() }
                    }
                    .disabled(!didLaunch && !canRetryCamera)
                    .accessibilitySortPriority(2)
                    .position(x: centerX, y: centerY)

                    if showsDisplayButton {
                        dockAction(title: "Display buttons", symbol: "square.grid.3x3.square", id: "selection",
                                   diameter: sideDiameter,
                                   hint: "Tap or drag up to show the list of detected buttons.") {
                            guard panelDragStartHeight == nil, panelDetent == .collapsed else { return }
                            animateSelection { panelDetent = defaultExpandedDetent }
                        }
                        // Keep the source circle alive until an interactive drag commits its detent.
                        .simultaneousGesture(
                            panelResizeGesture(restingHeight: restingHeight, collapsedHeight: 0, allHeight: allHeight),
                            isEnabled: canDisplayButtons
                        )
                        .disabled(!canDisplayButtons)
                        .position(x: centerX + slotWidth, y: centerY)
                    }
                }
                .frame(width: width, height: mainDiameter)
            }
            .overlay(alignment: .topLeading) {
                Button {
                    guard canRescan else { return }
                    withAnimation(glassAnimation) { scanPanel() }
                } label: {
                    dockSymbol("arrow.clockwise", diameter: sideDiameter)
                        .frame(width: sideDiameter, height: sideDiameter)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan again")
                .accessibilityHint("Scans a new panel.")
                .opacity(showsRescan ? 1 : 0)
                .allowsHitTesting(showsRescan)
                .accessibilityHidden(!showsRescan)
                .position(x: rescanX, y: centerY)
            }

            // Reserve the same caption space even when a side action is hidden.
            HStack(alignment: .top, spacing: 0) {
                dockCaption("Scan again", width: slotWidth)
                    .opacity(showsRescan ? 1 : 0)
                ZStack(alignment: .top) {
                    // Measure the other action titles so a wrapping caption cannot move the circles.
                    ForEach(["Scan panel", "Say a button", "Retry camera", "Stop"], id: \.self) { title in
                        dockCaption(title, width: slotWidth).hidden()
                    }
                    dockCaption(main.title, width: slotWidth)
                }
                dockCaption("Display buttons", width: slotWidth)
                    .opacity(showsDisplayButton ? 1 : 0)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(glassAnimation, value: showsRescan)
        .animation(glassAnimation, value: showsDisplayButton)
    }

    private func dockAction(title: String, symbol: String, id: String, diameter: CGFloat,
                            hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            dockSymbol(symbol, diameter: diameter)
        }
        .buttonStyle(.glass(.regular))
        .buttonBorderShape(.circle)
        .buttonSizing(.flexible)
        .frame(width: diameter, height: diameter)
        .glassEffectID(id, in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func dockSymbol(_ symbol: String, diameter: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.40, weight: .semibold))
            .glassForeground()
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dockCaption(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .glassForeground()
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .frame(width: width)
    }

    var body: some View {
        cameraControls
            .background { cameraBackground }
            .buttonStyle(.glass)
            .preferredColorScheme(.dark)
            #if DEBUG
            .sheet(isPresented: $showDeveloperTools) {
                NavigationStack { DebugMenu(camera: camera, pipeline: pipeline) }
            }
            #endif
            .sheet(isPresented: $showFeedbackSettings) { FeedbackSettingsView() }
            .sheet(isPresented: $showMessageDetails) { messageDetails }
            .onAppear { statusFocused = true }
            .task { await pipeline.guidanceStatus.run() }
            .task(id: experience.ready) { updateCameraLaunch() }
            .task(id: selectionAnimationKey) { updateButtonPanel() }
            .onChange(of: experience.status) { _, message in
                // State transitions only; tracking's per-frame output stays in the feedback engine.
                // VoiceRequest announces listening before it opens the microphone.
                if !experience.listening && !(pipeline.guidanceArrived
                    && (pipeline.feedback as? LiveFeedbackEngine)?.voiceEnabled == true) {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
            .onChange(of: experience.error) { _, error in
                if let error { UIAccessibility.post(notification: .announcement, argument: error) }
            }
            .onChange(of: pipeline.panelReference?.photo.id) {
                experience.referenceChanged()
            }
    }

    private func updateCameraLaunch() {
        cameraLaunchUnavailable = false
        guard experience.ready, !didLaunch else { return }
        // ready follows permission/configuration/start. Live camera mode must
        // also have a running session before showing the bottom controls.
        guard !experience.usesCamera || (camera.status.error == nil && !camera.status.isInterrupted) else {
            cameraLaunchUnavailable = true
            return
        }
        didLaunch = true
    }

    private func updateButtonPanel() {
        if experience.scanning {
            scanWasInFlight = true
            return
        }
        if scanWasInFlight && experience.busy { return }
        scanWasInFlight = false
        withAnimation(glassAnimation) {
            if didLaunch, experience.hasSelectionContent, let referenceID = pipeline.panelReference?.photo.id {
                displayedButtons = orderedButtons
                displayedReferenceID = referenceID
                if panelDetent == .named && !hasNamedButtons { panelDetent = defaultExpandedDetent }
            } else {
                displayedButtons = []
                displayedReferenceID = nil
                panelDetent = .collapsed
                panelDragHeight = nil
                panelDragStartHeight = nil
            }
        }
    }

    private func animateSelection(_ updates: () -> Void) {
        withAnimation(glassAnimation, updates)
    }

    private func movePanel(up: Bool) {
        animateSelection {
            switch (panelDetent, up) {
            case (.collapsed, true): panelDetent = defaultExpandedDetent
            case (.named, true): if hasUnlabelledButtons { panelDetent = .all }
            case (.all, false): panelDetent = hasNamedButtons ? .named : .collapsed
            case (.named, false): panelDetent = .collapsed
            default: break
            }
        }
    }

    private func panelResizeGesture(restingHeight: CGFloat, collapsedHeight: CGFloat,
                                    allHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: PanelGesture.minimumDistance, coordinateSpace: .named("launch-controls-layout"))
            .onChanged { value in
                // A vertical drag expands/resizes; sideways movement stays a native button interaction.
                guard panelDragStartHeight != nil
                        || abs(value.translation.height) > abs(value.translation.width) else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if panelDragStartHeight == nil {
                        panelDragStartHeight = restingHeight
                    }
                    panelDragHeight = min(allHeight, max(collapsedHeight,
                        (panelDragStartHeight ?? restingHeight) - value.translation.height))
                }
            }
            .onEnded { value in
                guard let startHeight = panelDragStartHeight else { return }
                let distance = value.translation.height
                let velocity = value.velocity.height
                let downward = distance > 0
                let target: PanelDetent
                if downward {
                    let longPull = distance >= max(PanelGesture.minimumDistance,
                        (startHeight - collapsedHeight) * PanelGesture.directCollapseFraction)
                    if velocity >= PanelGesture.fastSwipeVelocity || longPull {
                        target = .collapsed
                    } else {
                        // Even a short, slow downward pull advances exactly one stop.
                        target = panelDetent == .all && hasNamedButtons ? .named : .collapsed
                    }
                } else if -velocity >= PanelGesture.fastSwipeVelocity
                            || -distance >= max(PanelGesture.minimumDistance,
                                (allHeight - startHeight) * PanelGesture.directCollapseFraction) {
                    target = hasUnlabelledButtons ? .all : .named
                } else {
                    target = panelDetent == .collapsed ? defaultExpandedDetent
                        : hasUnlabelledButtons ? .all : .named
                }
                // Clear the manual height and choose the detent atomically.
                // Animation starts at the last dragged frame, never the old detent.
                animateSelection {
                    panelDetent = target
                    panelDragHeight = nil
                    panelDragStartHeight = nil
                }
            }
    }

    private func panelGrabber(restingHeight: CGFloat, collapsedHeight: CGFloat,
                              allHeight: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: PanelLayout.grabberHeight)
            .contentShape(Rectangle())
            .gesture(panelResizeGesture(restingHeight: restingHeight, collapsedHeight: collapsedHeight,
                                        allHeight: allHeight))
            .onTapGesture(count: 2) {
                animateSelection { panelDetent = defaultExpandedDetent }
            }
            .accessibilityLabel("Button panel size")
            .accessibilityValue(panelDetent.accessibilityName)
            .accessibilityHint(panelDetent == .collapsed
                               ? "Swipe up to show the detected buttons."
                               : "Swipe up for more buttons or down to collapse.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: movePanel(up: true)
                case .decrement: movePanel(up: false)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Collapse to Display buttons") {
                animateSelection { panelDetent = .collapsed }
            }
    }

    /// Keep selection behavior shared while each row supplies its own label layout.
    private func selectionButton<Label: View>(
        _ button: SurfaceMap.Button,
        hint: String = "Starts finger guidance to this button.",
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button { experience.choose(button) } label: { label() }
            .buttonStyle(.glass)
            .modifier(SelectionButtonAvailability())
            .accessibilityHint(hint)
            .disabled(experience.busy || !experience.ready)
    }

    private func buttonRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12, content: content)
                .padding(.vertical, 4)
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(.visible)
    }

    private func selectionControls(namedButtons: [SurfaceMap.Button],
                                   unlabelledButtons: [SurfaceMap.Button], showUnlabelled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !namedButtons.isEmpty {
                buttonRow {
                    ForEach(namedButtons) { button in
                        selectionButton(button) {
                            Text(readableLabel(for: button) ?? "")
                                .glassForeground()
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minHeight: 32)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { namedRowHeight = $0 }
            }

            if !unlabelledButtons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlabelled buttons")
                        .font(.subheadline.weight(.semibold))
                        .glassForeground()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHint("Ordered top to bottom, then left to right.")
                    buttonRow {
                        ForEach(Array(unlabelledButtons.enumerated()), id: \.element.id) { index, button in
                            selectionButton(button, hint: "Starts finger guidance to this button. The number identifies its place in this list.") {
                                Text("\(index + 1)")
                                    .font(.headline.monospacedDigit())
                                    .glassForeground()
                                    .frame(minWidth: 32, minHeight: 32)
                            }
                            .accessibilityLabel("Unlabelled button \(index + 1), \(positionDescription(for: button))")
                        }
                    }
                }
                .opacity(showUnlabelled ? 1 : 0)
                .allowsHitTesting(showUnlabelled)
                .accessibilityHidden(!showUnlabelled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptText: Text {
        Text(verbatim: "“\(experience.voiceTranscript)”")
            .font(.callout)
    }

    private var messageDetails: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(experience.displayStatus)
                    if !experience.voiceTranscript.isEmpty {
                        transcriptText
                    }
                    if experience.guiding {
                        GuidanceStatusRow(snapshot: pipeline.guidanceStatus.current)
                    }
                    if let error = experience.error { Text(error).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle(primaryAction.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMessageDetails = false }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    /// Glass hugs the text; only the outer layout reserves space above the button.
    /// Unbounded speech results, target names, and system errors use the compact fallback.
    private func statusCard(compact: Bool, minimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Preserve the original header width; the new options do not
                // need a third glass button beside the rescan and debug controls.
                Menu {
                    Button("Feedback settings", systemImage: "slider.horizontal.3") { showFeedbackSettings = true }
                    Button("Read full message", systemImage: "info.circle") { showMessageDetails = true }
                } label: {
                    Text("Contour")
                        .font(.title2.bold())
                        .glassForeground()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens feedback settings and the full status message.")
                Spacer(minLength: 0)
                if minimal {
                    Button { showMessageDetails = true } label: {
                        Image(systemName: "info.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.glass(headerGlass))
                    .accessibilityLabel("Read full message")
                    .accessibilityHint(experience.error ?? experience.displayStatus)
                }
                headerActionsSlot
            }

            if experience.listening {
                VStack(spacing: 8) {
                    Text("Listening...")
                        .font(.body.weight(.semibold))
                        .glassForeground()
                        .accessibilityFocused($statusFocused)

                    ListeningWaveform(experience: experience)

                    if !experience.voiceTranscript.isEmpty {
                        transcriptText
                            .glassForeground()
                            .multilineTextAlignment(.center)
                            .lineLimit(minimal ? 1 : compact ? 2 : 3)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if compact && !minimal {
                Text(experience.error ?? experience.displayStatus)
                    .font(.body)
                    .glassForeground()
                    .lineLimit(2)
                    .accessibilityFocused($statusFocused)
                Button { showMessageDetails = true } label: {
                    Text("Read full message")
                        .font(.footnote)
                        .glassForeground()
                }
                .buttonStyle(.glass(headerGlass))
                .frame(minHeight: 44)
            } else if !minimal {
                Text(experience.displayStatus)
                    .font(.body)
                    .glassForeground()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($statusFocused)
                if let error = experience.error {
                    Text(error)
                        .font(.body)
                        .glassForeground()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !experience.listening && !minimal && !experience.voiceTranscript.isEmpty {
                transcriptText
                    .glassForeground()
                    .lineLimit(compact ? 2 : 3)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if cameraLaunchUnavailable {
                Text("Camera is not running. Try starting it again.")
                    .font(.body)
                    .glassForeground()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("launch-controls-layout"))
        } action: { bounds in
            if !bounds.isEmpty { headerBounds = bounds }
        }
        .accessibilitySortPriority(3)
    }

    /// Measure the background after extending it beyond the safe area; the
    /// foreground GeometryReader still measures the controls' usable area.
    private var cameraBackground: some View {
        GeometryReader { background in
            ZStack {
                Color.black
                #if DEBUG
                let imageOffset: CGFloat = -300
                Image("Apple-Park")
                    .resizable()
                    .scaledToFill()
                    // Leave enough image on both sides for the chosen offset.
                    .frame(width: background.size.width + abs(imageOffset) * 2,
                           height: background.size.height)
                    .offset(x: imageOffset)
                #endif

                if experience.usesCamera {
                    LaunchCameraBackground(camera: camera, revision: camera.status.revision,
                                           pipeline: pipeline, isGuiding: experience.guiding)
                        .frame(width: background.size.width, height: background.size.height)
                }
            }
            .frame(width: background.size.width, height: background.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

}

private struct ListeningWaveform: View {
    private static let barSensitivity = [
        0.24, 0.31, 0.43, 0.38, 0.56, 0.49, 0.72, 0.60, 0.81,
        0.67, 0.99, 0.83, 1.16, 0.92, 1.08, 0.76, 0.88, 0.66,
        0.79, 0.53, 0.64, 0.45, 0.53, 0.34, 0.41, 0.29, 0.23,
    ]

    let experience: CameraLaunchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = experience.voiceLevel
        GeometryReader { geometry in
            let waveformWidth = geometry.size.width / 3
            let barWidth = min(2.5, waveformWidth / CGFloat(Self.barSensitivity.count) * 0.7)

            HStack(spacing: 0) {
                ForEach(Self.barSensitivity.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: barWidth, height: 3 + 25 * min(1, level * Self.barSensitivity[index]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: waveformWidth, height: geometry.size.height)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 28)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: level)
        .accessibilityHidden(true)
    }
}

/// Read the effective enabled state, including the panel's inherited scan/reference
/// restrictions. Keep the native glass style and disabled accessibility semantics.
private struct SelectionButtonAvailability: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.5)
    }
}

private extension View {
    func headerGlassControl(_ material: Glass, id: String, in namespace: Namespace.ID,
                            diameter: CGFloat, x: CGFloat) -> some View {
        buttonStyle(.glass(material))
            .buttonBorderShape(.circle)
            .buttonSizing(.flexible)
            .frame(width: diameter, height: diameter)
            .glassEffectID(id, in: namespace)
            .glassEffectTransition(.matchedGeometry)
            .position(x: x, y: diameter / 2)
    }

    /// Style each foreground label separately to preserve the existing glass layering.
    func glassForeground() -> some View {
        foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 3)
    }
}

/// Use the current shared, upright preview stream with the launch screen's
/// original edge-to-edge presentation. Only this background is cropped;
/// captured photos, tracking coordinates and diagnostic previews are unchanged.
private struct LaunchCameraBackground: View {
    let camera: CameraService
    let revision: Int
    let pipeline: ContourPipeline
    let isGuiding: Bool
    @State private var model = CameraFeedModel()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let preview = model.preview {
                    let image = preview.image
                    let scale = max(geometry.size.width / CGFloat(image.width),
                                    geometry.size.height / CGFloat(image.height))
                    let width = CGFloat(image.width) * scale
                    let height = CGFloat(image.height) * scale
                    let imageRect = CGRect(x: (geometry.size.width - width) / 2,
                                           y: (geometry.size.height - height) / 2,
                                           width: width, height: height)

                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: width, height: height)
                        .position(x: imageRect.midX, y: imageRect.midY)

                    if isGuiding, let marker = preview.marker, marker.sessionID == pipeline.guidancePreviewID {
                        GuidanceTargetOverlay(marker: marker, imageRect: imageRect)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: revision) {
            await model.run(camera: camera, framesPerSecond: 15) { pipeline.guidanceTargetFrame }
        }
    }
}

private struct GuidanceTargetOverlay: View {
    let marker: GuidanceTargetFrame.Marker
    let imageRect: CGRect

    var body: some View {
        Canvas { context, size in
            let corners = marker.corners.map {
                CGPoint(x: imageRect.minX + $0.x * imageRect.width,
                        y: imageRect.minY + $0.y * imageRect.height)
            }
            let outline = roundedOutline(corners)
            let bounds = outline.boundingRect
            guard bounds.intersects(CGRect(origin: .zero, size: size)) else { return }

            context.stroke(outline, with: .color(.black.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 6, lineJoin: .round))
            context.stroke(outline, with: .color(.yellow),
                           style: StrokeStyle(lineWidth: 3, lineJoin: .round))

            let caption = context.resolve(
                Text(verbatim: marker.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
            )
            let edgeInset: CGFloat = 8
            let horizontalPadding: CGFloat = 7
            let verticalPadding: CGFloat = 3
            let maximumWidth = min(240, size.width - 2 * (edgeInset + horizontalPadding))
            guard maximumWidth > 0 else { return }
            let textSize = caption.measure(in: CGSize(width: maximumWidth, height: 44))
            let width = min(maximumWidth, textSize.width) + 2 * horizontalPadding
            let height = textSize.height + 2 * verticalPadding
            let x = min(max(edgeInset, bounds.midX - width / 2), size.width - edgeInset - width)
            let captionRect = CGRect(x: x, y: bounds.minY - height - 6, width: width, height: height)
            context.fill(Path(roundedRect: captionRect, cornerRadius: 6), with: .color(.black.opacity(0.8)))
            context.draw(caption, in: captionRect.insetBy(dx: horizontalPadding, dy: verticalPadding))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func roundedOutline(_ corners: [CGPoint]) -> Path {
        // Round the projected corners on screen so the outline still follows perspective.
        func cutback(_ corner: CGPoint, toward neighbor: CGPoint) -> CGPoint {
            let dx = neighbor.x - corner.x
            let dy = neighbor.y - corner.y
            let length = hypot(dx, dy)
            guard length > 0 else { return corner }
            let fraction = min(0.25, 7 / length)
            return CGPoint(x: corner.x + dx * fraction, y: corner.y + dy * fraction)
        }

        return Path { path in
            for (index, corner) in corners.enumerated() {
                let previous = corners[(index + corners.count - 1) % corners.count]
                let next = corners[(index + 1) % corners.count]
                let start = cutback(corner, toward: previous)
                let end = cutback(corner, toward: next)
                if index == 0 { path.move(to: start) }
                else { path.addLine(to: start) }
                path.addQuadCurve(to: end, control: corner)
            }
            path.closeSubpath()
        }
    }
}

#Preview {
    let camera = CameraService()
    let pipeline = ContourPipeline.mock()
    LiveCameraView(camera: camera, pipeline: pipeline,
                   experience: CameraLaunchModel(camera: camera, pipeline: pipeline))
}
