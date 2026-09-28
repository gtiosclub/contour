//  DebugMenu.swift
//  ContourApp
//
//  Created by Anushka Prabhu on 9/28/26.
//


//  DebugMenu.swift
//  ContourApp/Debug
//
//  Created to provide a DEBUG-only menu for developer screens.
//  Everyone adds one line for their debug screen here. See the onboarding ticket.

#if DEBUG
import SwiftUI

/// The app's debug/developer menu. Only present in DEBUG builds.
/// - Usage: Add a NavigationLink or Button for your debug screen here — one line per debug screen.
public struct DebugMenu: View {
    public init() {}
    public var body: some View {
        List {
            // Add your debug screens here:
            NavigationLink("Anushka's Debug Tool") { AnushkaDebugView() }
            NavigationLink("Anushka's Debug Tool") { AnushkaDebugView() }
            //NavigationLink("Tracking Diagnostics") { TrackingDebugView(camera: CameraService()) }
            // Example: NavigationLink("My Debug Tool") { MyDebugToolView() }
        }
        .navigationTitle("Debug Menu")
    }
}
#endif
