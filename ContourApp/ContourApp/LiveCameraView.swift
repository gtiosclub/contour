//
//  liveCameraView.swift
//  ContourApp
//
//  Created by Evan on 9/26/26.
//

import SwiftUI
import AVFoundation
import Speech



final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

}

struct CameraView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(
        _ uiView: CameraPreviewView,
        context: Context
    ) {
        uiView.previewLayer.session = session
    }
}











struct LiveCameraView: View {
    @State private var session = AVCaptureSession()
    @State private var isStarted: Bool = false
    var body: some View {
        VStack {
            ZStack{
                
                Image("Apple Park")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .offset(x: -300)
                    
                    
                    
                // This background image is a placeholder for live camera when testing using real iOS device
                
                
                CameraView(session: session)
                    .ignoresSafeArea()
                    .onAppear {
                        setupCamera()
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
    private func setupCamera() {
        guard session.inputs.isEmpty else {
            return
        }
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            session.startRunning()
        } catch {
            print("Camera error:", error)
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

        }
    
            
//            Text("Button")
//                .buttonBorderShape(.circle)
//                .frame(idealWidth: 10, idealHeight: 10)
//                .accessibilityIdentifier("Button")
    
}

func start(){
    
}


#Preview {
    LiveCameraView()
}

