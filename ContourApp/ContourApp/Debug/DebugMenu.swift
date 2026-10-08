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
            Section("Anushka's Debug Tool") {
                // Add your debug screens here:
                NavigationLink("Anushka's Debug Tool") { AnushkaDebugView() }
            }
            //NavigationLink("Tracking Diagnostics") { TrackingDebugView(camera: CameraService()) }
            // Example: NavigationLink("My Debug Tool") { MyDebugToolView() }

            Section("Evan's Debug Tool"){
                NavigationLink("Harness Connect") { HarnessReceiverView() }
            }
        }
        .navigationTitle("Debug Menu")
    }
}

#Preview {
    DebugMenu()
        // Supply the environment dependency without starting networking or haptics.
        .environment(HarnessConnection(feedback: HarnessConsoleFeedback()))
}
#endif
