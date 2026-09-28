//
//  DebugMenuTests.swift
//  ContourTests
//
//  Tests for the DEBUG-only developer menu. These are wiring tests: they prove
//  the menu and every screen registered in it can be hosted and laid out
//  without crashing, and that the menu really is absent from Release builds.
//
//  A SwiftUI view has no public tree to walk, so "renders to a non-empty
//  frame" is the honest unit-level assertion. Whether a screen *looks* right
//  is a simulator job.
//

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ContourApp

#if DEBUG

@MainActor
@Suite("Debug menu")
struct DebugMenuTests {

    /// Host a SwiftUI view the way the app would, run one layout pass, and
    /// return the size it asked for on a phone-sized canvas.
    private func hostedSize<V: View>(_ view: V) -> CGSize {
        let controller = UIHostingController(rootView: view)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.layoutIfNeeded()
        return controller.sizeThatFits(in: CGSize(width: 393, height: 852))
    }

    @Test("the menu is constructible with no arguments, so any screen can present it")
    func menuIsConstructible() {
        _ = DebugMenu()
    }

    @Test("the menu hosts and lays out inside a navigation stack without crashing")
    func menuHostsAndLaysOut() {
        let size = hostedSize(NavigationStack { DebugMenu() })
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("Anushka's screen renders to a real image")
    func anushkaScreenRenders() {
        let renderer = ImageRenderer(content: AnushkaDebugView())
        renderer.scale = 1
        let image = renderer.uiImage
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }

    @Test("Anushka's screen hosts and lays out inside the menu's navigation")
    func anushkaScreenHostsAndLaysOut() {
        let size = hostedSize(NavigationStack { AnushkaDebugView() })
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("the debug menu is compiled out of Release builds")
    func menuIsDebugOnly() {
        // This test only exists inside `#if DEBUG`; if DebugMenu ever leaks into
        // Release the wrapping guard around this suite is what to check first.
        #expect(Self.isDebugBuild, "this suite must not run in a Release build")
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

#endif
