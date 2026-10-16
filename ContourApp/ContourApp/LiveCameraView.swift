//
//  liveCameraView.swift
//  ContourApp
//
//  Created by Evan on 9/26/26.
//

import SwiftUI
import AVFoundation
import Speech


struct LiveCameraView: View {
    // The app's shared camera setup: starts the session off the main thread
    // and asks for camera permission first.
    @State private var camera = CameraService()
    @State private var isStarted: Bool = false
    var body: some View {
        VStack {
            ZStack{

                // Shows through when there's no camera (e.g. the simulator).
                Color.black
                    .ignoresSafeArea()

                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .task {
                        try? await camera.start()
                    }
                    .onDisappear {
                        Task { await camera.stop() }
                    }

                
                VStack{
                    Spacer()
                    Text("Hello, World!")
                        .padding()
                    
                    
                    Button{
                        
                    } label: {
                        Circle()
                            .glassEffect(.clear)
                            .foregroundStyle(.clear)
                            .frame(width: 250, height: 250)
                            .overlay{
                                Text("Button")
                                    .accessibilityIdentifier("Button")
                                    .bold()
                                    .font(.largeTitle)
                                    .foregroundColor(.primary)
                                //.foregroundStyle(.blue)
                            }
                    }
                    
                    
                    
                    .padding()
                    Text(String(isStarted))
                }
                
            }
            
            ZStack{
                Toggle(isOn: $isStarted){
                    Text("Start View")
                }
                .toggleStyle(.switch)
                .safeAreaPadding()
                
                
                
                
                Toggle(isOn: $isStarted){
                    Text("Toggle Start")
                }
                .toggleStyle(.button)
                .textInputBorderShape(.roundedRectangle)
                .glassEffect(.clear)
            }
        }
        
        .task {
            try? await listenForStart()
        }
    }
    func listenForStart() async throws {

            // 1. Speech-to-text
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "en-US")
            ) else { return }

            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            )

            // 2. ensure speech model is downloaded

            if let request = try await AssetInventory
                .assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }

            // 3. get microphone

            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                return
            }

            let input = try await CaptureInputSequenceProvider
                .providerWithSession(
                    from: microphone,
                    compatibleWith: [transcriber]
                )

            // 4. microphone → SpeechTranscriber

            let analyzer = SpeechAnalyzer(
                inputSequence: input.analyzerInputs,
                modules: [transcriber]
            )

            
            input.captureSession.startRunning()
            

            // 5. get recognition result

            for try await result in transcriber.results {
                let text = String(result.text.characters)
                print(text)
                if text.localizedCaseInsensitiveContains("start") {
                    isStarted = true
                    //input.captureSession.stopRunning()
                    //await analyzer.cancelAndFinishNow()
                    //return
                }

            }

            // Using the analyzer here keeps it alive while the loop above is
            // listening; otherwise it can be released and stop transcribing.
            await analyzer.cancelAndFinishNow()

        }

}


#Preview {
    LiveCameraView()
}

