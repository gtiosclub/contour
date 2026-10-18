//
//  liveCameraView.swift
//  ContourApp
//
//  Created by Evan on 9/26/26.
//

import AVFoundation
import ContourCore
import SwiftUI
import UIKit

struct LiveCameraView: View {
    let camera: CameraService
    let pipeline: ContourPipeline
    let experience: CameraLaunchModel
    @AccessibilityFocusState private var statusFocused: Bool
    @State private var showMessageDetails = false
    @Namespace private var glassNamespace
    @Namespace private var headerActionsNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didLaunch = false
    @State private var cameraLaunchUnavailable = false
    @State private var launchProgress: CGFloat = 0
    @State private var primaryDetached = false
    @State private var headerIsRegular = false
    @State private var headerBounds: CGRect = .zero
    @State private var selectionVisible = false
    @State private var selectionProgress: CGFloat = 0
    @State private var displayedButtons: [SurfaceMap.Button] = []
    @State private var displayedReferenceID: UUID?
    @State private var scanWasInFlight = false
    @State private var scanRequestID = UUID()
    @State private var scanRequiresRetry = false
    @State private var panelDetent: PanelDetent = .collapsed
    @State private var namedRowHeight: CGFloat = 52
    @State private var allControlsHeight: CGFloat = 140
    // Keep the last finger-driven height until the snap transaction commits.
    // GestureState resets before onEnded and used to briefly reopen the panel.
    @State private var panelDragHeight: CGFloat?
    @State private var panelDragStartHeight: CGFloat?
    @State private var selectionLabelVisible = false
    @State private var selectionMotionID = UUID()
    @State private var headerActionsBounds: CGRect = .zero
    @State private var headerSeparationProgress: CGFloat = 0

    private enum PanelLayout {
        // Three stops: Display buttons, named buttons (default expansion), then all buttons.
        static let collapsedWidth: CGFloat = 180
        static let collapsedHeight: CGFloat = 56
        static let edgeInset: CGFloat = 8
        static let buttonGap: CGFloat = 24
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
        // Delay in seconds before the primary button separates from the header.
        static let launchDelaySeconds: Double = 1
        // Shared duration in seconds for glass separation, expansion, and collapse.
        static let animationDurationSeconds: Double = 0.45
        // Delay after separation before the header changes from clear to regular.
        static let headerMaterialDelaySeconds: Double = 0.5
    }

    private struct SelectionAnimationKey: Equatable {
        let referenceID: UUID?
        let scanning: Bool
        let working: Bool
        let requestID: UUID
        let reduceMotion: Bool
    }

    private struct HeaderAnimationKey: Equatable {
        let available: Bool
        let reduceMotion: Bool
    }

    private var glassAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: MotionTiming.animationDurationSeconds)
    }

    /// Match the primary button's clear material while attached; only the header
    /// becomes regular after separation and its material delay. All header elements share this phase.
    private var headerGlass: Glass {
        headerIsRegular ? .regular : .clear
    }

    private var selectionAnimationKey: SelectionAnimationKey {
        // Observe raw scan results here; scanRequiresRetry is an output of this task,
        // so including it in the key would replay the failure's closing animation.
        SelectionAnimationKey(
            referenceID: primaryDetached
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

    private var primaryTitle: String {
        if experience.busy { return "Stop" }
        if !experience.ready { return "Retry camera" }
        return hasSelectionContent ? "Say a button" : "Scan panel"
    }

    // A simulator caption alone is not content: keep the lower glass absent
    // until scanning (or a prepared reference) produces something actionable.
    private var hasSelectionContent: Bool {
        !scanRequiresRetry && pipeline.canGuide && !(experience.map?.buttons.isEmpty ?? true)
    }

    private var orderedButtons: [SurfaceMap.Button] {
        // SurfaceMap explicitly has no reading-order guarantee.
        (experience.map?.buttons ?? []).enumerated().sorted { lhs, rhs in
            let left = lhs.element.bounds.origin
            let right = rhs.element.bounds.origin
            if left.y != right.y { return left.y < right.y }
            if left.x != right.x { return left.x < right.x }
            return lhs.offset < rhs.offset
        }.map(\.element)
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
        // The center button already handles first scan, empty results and unclear outlines.
        primaryDetached && experience.ready && hasSelectionContent && !experience.busy
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
    }

    /// Keep both controls alive and animate their positions for proximity morphing.
    /// Native glass button styles own the only material and the foreground artwork.
    private var headerActions: some View {
        let diameter = HeaderActionsLayout.buttonSize
        let centerY = diameter / 2
        #if DEBUG
        let sourceX = HeaderActionsLayout.width - diameter / 2
        let rescanX = sourceX - (diameter + HeaderActionsLayout.spacing) * headerSeparationProgress
        #else
        let rescanX = diameter / 2
        #endif
        let rescanReady = canRescan && headerSeparationProgress == 1

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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.glass(headerGlass))
                .buttonBorderShape(.circle)
                .buttonSizing(.flexible)
                .frame(width: diameter, height: diameter)
                .glassEffectID("developer-tools", in: headerActionsNamespace)
                .glassEffectTransition(.identity)
                .position(x: sourceX, y: centerY)
                .accessibilityHint("Stops current work and opens the developer tools.")
                #endif

                // Preserve the morph identity even while merged into Debug.
                Button {
                    guard rescanReady else { return }
                    scanPanel()
                } label: {
                    headerActionLabel("Scan again", symbol: "arrow.clockwise")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(headerSeparationProgress)
                }
                .buttonStyle(.glass(headerGlass))
                .buttonBorderShape(.circle)
                .buttonSizing(.flexible)
                .frame(width: diameter, height: diameter)
                .glassEffectID("rescan", in: headerActionsNamespace)
                .glassEffectTransition(.identity)
                #if !DEBUG
                // Release has no developer button to merge into.
                .opacity(headerSeparationProgress)
                #endif
                .position(x: rescanX, y: centerY)
                .allowsHitTesting(rescanReady)
                .accessibilityHidden(!rescanReady)
                .accessibilityHint("Scans a new panel.")
            }
        }
        .frame(width: HeaderActionsLayout.width, height: diameter)
        .accessibilitySortPriority(3)
    }

    var body: some View {
        GeometryReader { geo in
            let buttonSize = min(210, geo.size.height * 0.5)
            // Translate the full screen's center into this safe-area coordinate space.
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let buttonCenterY = fullHeight / 2 - geo.safeAreaInsets.top
            let panelTopLimit = buttonCenterY + buttonSize / 2 + PanelLayout.buttonGap
            let statusHeight = max(0, buttonCenterY - buttonSize / 2 - 24 - 8)
            let primarySize = 56 + (buttonSize - 56) * launchProgress
            // Keep the waiting circle fully inside the header instead of touching
            // its lower edge, where the native button's material could protrude.
            let sourceCenterY = headerBounds.isEmpty ? min(160, statusHeight) / 2 + 8 : headerBounds.midY
            let dockY = min(buttonCenterY, sourceCenterY)
            let primaryX = geo.size.width / 2 // The card and button share this fixed centerline.
            let primaryY = dockY + (buttonCenterY - dockY) * launchProgress
            let panelWidth = max(0, geo.size.width - PanelLayout.edgeInset * 2)
            // Extend below the safe area, leaving the same inset from the physical edges.
            let panelBottom = geo.size.height + geo.safeAreaInsets.bottom - PanelLayout.edgeInset
            let maximumPanelHeight = max(0, panelBottom - panelTopLimit)
            let bottomPadding = max(16, geo.safeAreaInsets.bottom)
            let namedButtons = displayedButtons.filter { readableLabel(for: $0) != nil }
            let unlabelledButtons = displayedButtons.filter { readableLabel(for: $0) == nil }
            let namedPanelHeight = min(maximumPanelHeight,
                                       namedRowHeight + PanelLayout.grabberHeight + bottomPadding)
            let allPanelHeight = min(maximumPanelHeight,
                                     max(namedPanelHeight, allControlsHeight + PanelLayout.grabberHeight + bottomPadding))
            let collapsedHeight = min(PanelLayout.collapsedHeight, maximumPanelHeight)
            let restingHeight = panelDetent == .collapsed ? collapsedHeight
                : panelDetent == .named ? namedPanelHeight : allPanelHeight
            let panelHeight = min(allPanelHeight,
                                  max(collapsedHeight, panelDragHeight ?? restingHeight))
            let expansion = min(1, max(0, (panelHeight - collapsedHeight)
                                          / max(1, namedPanelHeight - collapsedHeight)))
            let collapsedWidth = min(PanelLayout.collapsedWidth, panelWidth)
            let targetWidth = collapsedWidth + (panelWidth - collapsedWidth) * expansion
            let targetBottom = panelBottom - bottomPadding * (1 - expansion)
            let selectionWidth = 56 + (targetWidth - 56) * selectionProgress
            let selectionHeight = 56 + (panelHeight - 56) * selectionProgress
            let selectionDockY = buttonCenterY + buttonSize / 2 - 28
            let selectionY = selectionDockY
                + (targetBottom - panelHeight / 2 - selectionDockY) * selectionProgress
            // Resolve screen-relative corners with the system's concentric geometry.
            let panelShape = ConcentricRectangle(corners: .concentric(
                minimum: .fixed(28 + 4 * selectionProgress)), isUniform: true)

            let selectionReady = selectionProgress == 1 && hasSelectionContent
                && !experience.scanning && displayedReferenceID == pipeline.panelReference?.photo.id
            // Hiding the label during a drag must not disable the gesture mid-touch.
            let selectionInputReady = selectionReady && (selectionLabelVisible || panelDragHeight != nil)

            ZStack {
                // The primary control uses native button glass. The lower shell keeps
                // its verified explicit glass effect and separate foreground unchanged.
                GlassEffectContainer(spacing: 12) {
                    ZStack {
                        if !headerBounds.isEmpty {
                            Color.clear
                                .frame(width: headerBounds.width, height: headerBounds.height)
                                .glassEffect(headerGlass, in: .rect(cornerRadius: 32))
                                .glassEffectID("status", in: glassNamespace)
                                .position(x: headerBounds.midX, y: headerBounds.midY)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }

                        Button {
                            if experience.busy { experience.stop() }
                            else if !experience.ready { experience.setActive(true) }
                            else if !hasSelectionContent { scanPanel() }
                            else { experience.sayAButton() }
                        } label: {
                            // Hidden text must not impose its full intrinsic size on the docked circle.
                            Text(primaryDetached ? primaryTitle : "")
                                .font(.title.bold())
                                .glassForeground()
                                .multilineTextAlignment(.center)
                                .padding(24 * launchProgress)
                                .contentTransition(.identity)
                                .transaction { $0.animation = nil }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(primaryDetached ? 1 : 0)
                        }
                        .buttonStyle(.glass(.clear))
                        .buttonBorderShape(.circle)
                        .buttonSizing(.flexible)
                        .frame(width: primarySize, height: primarySize)
                        .glassEffectID("primary", in: glassNamespace)
                        .glassEffectTransition(.identity)
                        .opacity(headerBounds.isEmpty ? 0 : 1)
                        .contentShape(Circle())
                        .accessibilityLabel(primaryTitle)
                        .accessibilityHint(experience.busy ? "Cancels the current scan, microphone, or guidance."
                                           : !experience.ready ? "Tries to start the camera again."
                                           : !hasSelectionContent ? "Photographs and identifies the panel's buttons."
                                           : "Listens for a button name for up to eight seconds.")
                        .accessibilitySortPriority(2)
                        .allowsHitTesting(primaryDetached)
                        .accessibilityHidden(!primaryDetached)
                        .position(x: primaryX, y: primaryY)
                        .zIndex(1)

                        if selectionVisible {
                            // Keep this button and its material alive at every detent.
                            // Replacing a styled button with a decorative glass view caused
                            // an extra native hierarchy transition and a visible flash.
                            Button {
                                guard panelDetent == .collapsed, panelDragHeight == nil else { return }
                                animateSelection { panelDetent = defaultExpandedDetent }
                            } label: {
                                Color.clear
                                    .frame(width: selectionWidth, height: selectionHeight)
                                    .glassEffect(.clear, in: panelShape)
                                    .glassEffectID("selection", in: glassNamespace)
                                    .glassEffectTransition(.identity)
                                    .contentShape(panelShape)
                            }
                            // Avoid a second button-style material over the morphing shell.
                            .buttonStyle(.plain)
                            .contentShape(panelShape)
                            .simultaneousGesture(panelResizeGesture(
                                restingHeight: restingHeight, collapsedHeight: collapsedHeight,
                                allHeight: allPanelHeight))
                            .disabled(!selectionReady)
                            .allowsHitTesting(selectionInputReady && panelDetent == .collapsed)
                            .accessibilityHidden(!selectionInputReady || panelDetent != .collapsed)
                            .accessibilityLabel("Display buttons")
                            .accessibilityHint("Tap or drag up to expand the detected button list.")
                            .position(x: primaryX, y: selectionY)
                            .transition(.identity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // Header controls use native button styling independently of the
                // decorative status/primary/menu material container above.
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

                if selectionVisible {
                    VStack(spacing: 0) {
                        panelGrabber(restingHeight: restingHeight, collapsedHeight: collapsedHeight,
                                     allHeight: allPanelHeight)
                        selectionControls(namedButtons: namedButtons,
                                          unlabelledButtons: unlabelledButtons,
                                          showUnlabelled: panelDetent == .all || (panelDragHeight != nil
                                              && (namedButtons.isEmpty || panelHeight > namedPanelHeight)))
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                allControlsHeight = $0
                            }
                    }
                    .padding(.horizontal, 20)
                    .frame(width: panelWidth, alignment: .top)
                    .frame(width: selectionWidth, height: selectionHeight, alignment: .top)
                    .clipShape(panelShape)
                    // Geometry drives the crossfade during a drag; the same values
                    // animate to their endpoints when the panel snaps to a detent.
                    .opacity(expansion * selectionProgress)
                    .allowsHitTesting(selectionReady && panelDetent != .collapsed)
                    .disabled(!selectionReady)
                    .accessibilityHidden(!selectionReady || panelDetent == .collapsed)
                    .position(x: primaryX, y: selectionY)
                    .transition(.identity)

                    Text("Display buttons")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .glassForeground()
                        .frame(width: selectionWidth, height: selectionHeight)
                        .clipShape(panelShape)
                        .opacity(selectionLabelVisible ? 1
                                 : panelDragHeight != nil && selectionReady ? 1 - expansion : 0)
                        .position(x: primaryX, y: selectionY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.identity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "launch-controls-layout")
        }
        .background { cameraBackground }
        .buttonStyle(.glass)
        .preferredColorScheme(.dark)
        #if DEBUG
        .sheet(isPresented: $showDeveloperTools) {
            NavigationStack { DebugMenu(camera: camera, pipeline: pipeline) }
        }
        #endif
        .sheet(isPresented: $showMessageDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(experience.status)
                        if let error = experience.error { Text(error).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .navigationTitle(primaryTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showMessageDetails = false }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
        .onAppear { statusFocused = true }
        .task(id: experience.ready) {
            cameraLaunchUnavailable = false
            guard experience.ready, !didLaunch else { return }
            // ready follows permission/configuration/start. Live camera mode must
            // also have a running session before the launch countdown begins.
            guard !experience.usesCamera || camera.session.isRunning else {
                cameraLaunchUnavailable = true
                return
            }
            didLaunch = true
            // Cancellation and Reduce Motion must always leave a usable button.
            defer {
                if launchProgress != 1 || !primaryDetached {
                    launchProgress = 1
                    primaryDetached = true
                }
            }
            guard !reduceMotion else { return }
            await Task.yield()
            do { try await Task.sleep(for: .seconds(MotionTiming.launchDelaySeconds)) }
            catch { return }
            // Keep both glass identities stable. Native container spacing
            // controls merging as the button moves vertically out of the card.
            withAnimation(glassAnimation) { launchProgress = 1 }
            do { try await Task.sleep(for: .seconds(MotionTiming.animationDurationSeconds)) }
            catch { return }
            withAnimation(glassAnimation) { primaryDetached = true }
        }
        .task(id: primaryDetached) {
            guard primaryDetached, !headerIsRegular else { return }
            do { try await Task.sleep(for: .seconds(MotionTiming.headerMaterialDelaySeconds)) }
            catch { return }
            withAnimation(glassAnimation) { headerIsRegular = true }
        }
        .task(id: HeaderAnimationKey(available: canRescan, reduceMotion: reduceMotion)) {
            withAnimation(glassAnimation) {
                headerSeparationProgress = canRescan ? 1 : 0
            }
        }
        .task(id: selectionAnimationKey) {
            let key = selectionAnimationKey
            if key.scanning {
                // Detection temporarily clears the pipeline reference. Keep the old
                // presentation until the scan finishes; selectionReady disables it.
                scanWasInFlight = true
                return
            }
            // replaceWork can await cleanup before scanning becomes true.
            if scanWasInFlight && key.working { return }
            if scanWasInFlight {
                scanWasInFlight = false
                scanRequiresRetry = experience.error != nil || !pipeline.canGuide
                    || (experience.map?.buttons.isEmpty ?? true)
            }
            selectionMotionID = UUID() // Invalidate callbacks from a superseded reference.
            if primaryDetached, hasSelectionContent, let referenceID = pipeline.panelReference?.photo.id {
                let needsEntrance = !selectionVisible || selectionProgress == 0
                displayedButtons = orderedButtons
                displayedReferenceID = referenceID
                if needsEntrance {
                    panelDetent = .collapsed
                    selectionLabelVisible = false
                    selectionVisible = true
                    if !reduceMotion {
                        do { try await Task.sleep(for: .seconds(1.0 / 60)) }
                        catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    // The fixed-size foreground label fades in with the native separation.
                    animateSelection { selectionProgress = 1 }
                } else {
                    // A successful rescan updates the existing menu without replaying entry.
                    if panelDetent == .named && !hasNamedButtons {
                        animateSelection { panelDetent = defaultExpandedDetent }
                    }
                }
            } else {
                animateSelection {
                    panelDragHeight = nil
                    panelDragStartHeight = nil
                    panelDetent = .collapsed
                    selectionProgress = 0
                } completion: {
                    selectionVisible = false
                    displayedButtons = []
                    displayedReferenceID = nil
                }
            }
        }
        .onChange(of: reduceMotion) { _, reduce in
            if reduce, didLaunch { launchProgress = 1; primaryDetached = true }
        }
        .onChange(of: experience.status) { _, message in
            // State transitions only; tracking's per-frame output stays in the feedback engine.
            // VoiceRequest announces listening before it opens the microphone.
            if !experience.listening {
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

    /// Keep material geometry and foreground crossfades in one transaction.
    /// Labels have a fixed single-line layout, so entry no longer needs a delayed reveal.
    private func animateSelection(_ updates: () -> Void, completion: (() -> Void)? = nil) {
        let motionID = UUID()
        selectionMotionID = motionID
        withAnimation(glassAnimation, completionCriteria: .logicallyComplete) {
            updates()
            selectionLabelVisible = selectionProgress == 1 && panelDetent == .collapsed
                && hasSelectionContent && !experience.scanning
        } completion: {
            guard selectionMotionID == motionID else { return }
            completion?()
        }
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
                        selectionMotionID = UUID()
                        selectionLabelVisible = false
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
            .accessibilityHint("Swipe up for more buttons or down to collapse.")
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

    private func selectionControls(namedButtons: [SurfaceMap.Button],
                                   unlabelledButtons: [SurfaceMap.Button], showUnlabelled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !namedButtons.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(namedButtons) { button in
                            selectionButton(button) {
                                Text(readableLabel(for: button) ?? "")
                                    .glassForeground()
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(minHeight: 32)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollIndicators(.visible)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { namedRowHeight = $0 }
            }

            if !unlabelledButtons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlabelled buttons")
                        .font(.subheadline.weight(.semibold))
                        .glassForeground()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHint("Ordered top to bottom, then left to right.")
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
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
                        .padding(.vertical, 4)
                    }
                    .scrollClipDisabled()
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .scrollIndicators(.visible)
                }
                .opacity(showUnlabelled ? 1 : 0)
                .allowsHitTesting(showUnlabelled)
                .accessibilityHidden(!showUnlabelled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Glass hugs the text; only the outer layout reserves space above the button.
    /// Unbounded speech results, target names, and system errors use the compact fallback.
    private func statusCard(compact: Bool, minimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Contour")
                    .font(.title2.bold())
                    .glassForeground()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if minimal {
                    Button { showMessageDetails = true } label: {
                        Image(systemName: "info.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.glass(headerGlass))
                    .accessibilityLabel("Read full message")
                    .accessibilityHint(experience.error ?? experience.status)
                }
                headerActionsSlot
            }

            if compact && !minimal {
                Text(experience.error ?? experience.status)
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
                Text(experience.status)
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

            // Camera failure must remain recoverable before the main button is revealed.
            if !didLaunch, experience.error != nil || cameraLaunchUnavailable {
                if cameraLaunchUnavailable {
                    Text("Camera is not running. Try starting it again.")
                        .font(.body)
                        .glassForeground()
                }
                Button { experience.setActive(true) } label: {
                    Text("Retry camera").glassForeground()
                }
                .buttonStyle(.glass(headerGlass))
                .accessibilityHint("Tries to start the camera again before the launch animation.")
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
                    LaunchCameraPreview(session: camera.session)
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

/// Read the effective enabled state, including the panel's inherited scan/reference
/// restrictions. Keep the native glass style and disabled accessibility semantics.
private struct SelectionButtonAvailability: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.5)
    }
}

private extension View {
    /// Style each foreground label separately to preserve the existing glass layering.
    func glassForeground() -> some View {
        foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 3)
    }
}

/// Launch-only presentation, reusing the existing preview's rotation handling.
private struct LaunchCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreview.PreviewView {
        let view = CameraPreview.PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: CameraPreview.PreviewView, context: Context) { }
}

#Preview {
    let camera = CameraService()
    let pipeline = ContourPipeline.mock()
    LiveCameraView(camera: camera, pipeline: pipeline,
                   experience: CameraLaunchModel(camera: camera, pipeline: pipeline))
}
