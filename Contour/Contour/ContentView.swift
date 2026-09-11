import SwiftUI

struct ContentView: View {
    
    @State private var selectedTab = "Tracking"
    
    var body: some View {
        ZStack {
            // Background
            Color(red: 45/255, green: 45/255, blue: 45/255)
                .ignoresSafeArea()
            
            VStack(spacing: 25) {
                
                // Top title
                Text("C O N T O U R")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.top, 20)
                
                // Tabs
                HStack(spacing: 0) {
                    
                    Button {
                        selectedTab = "Tracking"
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 16, height: 16)
                            
                            Text("Tracking")
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            selectedTab == "Tracking"
                            ? Color.white.opacity(0.15)
                            : Color.clear
                        )
                        .clipShape(Capsule())
                    }
                    
                    Button {
                        selectedTab = "Chart"
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 16, height: 16)
                            
                            Text("Chart")
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            selectedTab == "Chart"
                            ? Color.white.opacity(0.15)
                            : Color.clear
                        )
                        .clipShape(Capsule())
                    }
                }
                .padding(3)
                .background(Color.black.opacity(0.15))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.1))
                }
                
                Spacer()
            }
        }
    }
}

#Preview {
    ContentView()
}
