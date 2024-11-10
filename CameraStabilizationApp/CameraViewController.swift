import UIKit
import AVFoundation
import Photos
import CoreMotion

class CameraViewController: UIViewController {
    // MARK: - UI Elements
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    
    // MARK: - Capture Properties
    var captureSession: AVCaptureSession!
    var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    var videoOutput: AVCaptureVideoDataOutput!
    var audioOutput: AVCaptureAudioDataOutput!
    
    // MARK: - Recording Properties
    var assetWriter: AVAssetWriter!
    var assetWriterInput: AVAssetWriterInput!
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    var isRecording = false
    var outputURL: URL!
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    
    // MARK: - Stabilization Properties
    var motionManager: CMMotionManager!
    let recordingQueue = DispatchQueue(label: "recordingQueue")
    private var currentRotationAngle: Double = 0.0
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        lockOrientation()
        setupMotionManager()
        requestPermissions {
            self.setupCameraSession()
        }
    }
    
    // MARK: - Orientation Lock
    private func lockOrientation() {
        if #available(iOS 16.0, *) {
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
    
    override var shouldAutorotate: Bool {
        return false
    }
    
    // MARK: - Motion Setup
    private func setupMotionManager() {
        motionManager = CMMotionManager()
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else { return }
            self.handleDeviceMotionUpdate(motion)
        }
    }
    
    private func handleDeviceMotionUpdate(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let x = gravity.x
        let y = gravity.y
        
        // Calculate the tilt angle around the Z-axis relative to gravity
        var tiltAngle = atan2(y, x) - .pi / 2

        // Apply a 180-degree correction
        tiltAngle += .pi  // Add π to rotate everything by 180 degrees

        tiltAngle = -tiltAngle

        // Normalize angle to range [-π, π] to prevent unexpected flips
        if tiltAngle > .pi {
            tiltAngle -= 2 * .pi
        } else if tiltAngle < -.pi {
            tiltAngle += 2 * .pi
        }

        currentRotationAngle = tiltAngle
    }

    // MARK: - Camera Setup
    func setupCameraSession() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession = AVCaptureSession()
            self.captureSession.sessionPreset = .high
            
            // Setup video input
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
                print("Cannot setup video input")
                return
            }
            
            // Get video dimensions
            let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            self.videoWidth = Int(dimensions.width)
            self.videoHeight = Int(dimensions.height)
            
            if self.captureSession.canAddInput(videoDeviceInput) {
                self.captureSession.addInput(videoDeviceInput)
            }
            
            // Setup audio input
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.captureSession.canAddInput(audioDeviceInput) {
                self.captureSession.addInput(audioDeviceInput)
            }
            
            // Setup video output
            self.videoOutput = AVCaptureVideoDataOutput()
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.recordingQueue)
            
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }
            
            // Setup audio output
            self.audioOutput = AVCaptureAudioDataOutput()
            self.audioOutput.setSampleBufferDelegate(self, queue: self.recordingQueue)
            
            if self.captureSession.canAddOutput(self.audioOutput) {
                self.captureSession.addOutput(self.audioOutput)
            }
            
            self.captureSession.startRunning()
            
            DispatchQueue.main.async {
                self.setupPreviewLayer()
            }
        }
    }
    
    func setupPreviewLayer() {
        videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.videoGravity = .resizeAspectFill
        videoPreviewLayer.frame = view.bounds
        view.layer.insertSublayer(videoPreviewLayer, at: 0)
    }
    
    // MARK: - Recording Control
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        recordButton.isEnabled = false
        stopButton.isEnabled = true
        startRecording()
    }
    
    @IBAction func stopButtonTapped(_ sender: UIButton) {
        stopButton.isEnabled = false
        stopRecording()
    }
    
    func startRecording() {
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6000000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput.expectsMediaDataInRealTime = true
            
            // Apply a clockwise 90-degree rotation
            assetWriterInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: videoWidth,
                    kCVPixelBufferHeightKey as String: videoHeight,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            
            if assetWriter.canAdd(assetWriterInput) {
                assetWriter.add(assetWriterInput)
            }
            
            // Setup audio input
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            
            if assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            }
            
            isRecording = true
            
        } catch {
            print("Error setting up asset writer: \(error)")
            resetRecordingState()
        }
    }
    
    func stopRecording() {
        isRecording = false
        assetWriterInput.markAsFinished()
        
        assetWriter.finishWriting { [weak self] in
            guard let self = self else { return }
            
            if self.assetWriter.status == .completed {
                self.saveVideoToPhotoLibrary(url: self.outputURL)
            } else {
                print("Asset writer did not complete successfully.")
                if let error = self.assetWriter.error {
                    print("Asset Writer Error: \(error)")
                }
                self.resetRecordingState()
            }
        }
    }
    
    func resetRecordingState() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordButton.isEnabled = true
            self.stopButton.isEnabled = false
            self.assetWriter = nil
            self.assetWriterInput = nil
            self.pixelBufferAdaptor = nil
        }
    }
    
    func saveVideoToPhotoLibrary(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { saved, error in
            DispatchQueue.main.async {
                if saved {
                    print("Video saved successfully.")
                    self.resetRecordingState()
                } else if let error = error {
                    print("Error saving video: \(error)")
                    self.resetRecordingState()
                }
            }
        }
    }
    
    // MARK: - Permissions
    func requestPermissions(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        var permissionGranted = true
        
        group.enter()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            permissionGranted = permissionGranted && granted
            group.leave()
        }
        
        group.enter()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            permissionGranted = permissionGranted && granted
            group.leave()
        }
        
        group.enter()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            permissionGranted = permissionGranted && (status == .authorized || status == .limited)
            group.leave()
        }
        
        group.notify(queue: .main) {
            if permissionGranted {
                completion()
            } else {
                self.showAlert(title: "Permissions Denied", message: "Please enable permissions in Settings.")
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if assetWriter.status == .unknown {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: timestamp)
        }
        
        guard assetWriter.status == .writing else {
            if assetWriter.status == .failed {
                print("Asset writer failed: \(String(describing: assetWriter.error))")
                resetRecordingState()
            }
            return
        }
        
        if output == videoOutput, assetWriterInput.isReadyForMoreMediaData,
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            // Calculate center based on swapped dimensions for proper rotation
            let centerTransform = CGAffineTransform(translationX: -CGFloat(videoWidth) / 2, y: -CGFloat(videoHeight) / 2)
            let rotationTransform = CGAffineTransform(rotationAngle: CGFloat(currentRotationAngle))
            let backTransform = CGAffineTransform(translationX: CGFloat(videoWidth) / 2, y: CGFloat(videoHeight) / 2)

            let transformedImage = ciImage
                .transformed(by: centerTransform)      // Move to center
                .transformed(by: rotationTransform)     // Apply rotation
                .transformed(by: backTransform)         // Move back

            var outputPixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,
                                videoWidth,
                                videoHeight,
                                kCVPixelFormatType_32BGRA,
                                nil,
                                &outputPixelBuffer)
            
            if let outputPixelBuffer = outputPixelBuffer {
                let context = CIContext(options: [.useSoftwareRenderer: false])
                context.render(transformedImage, to: outputPixelBuffer)
                
                if !pixelBufferAdaptor.append(outputPixelBuffer, withPresentationTime: timestamp) {
                    print("Failed to append pixel buffer")
                    if let error = assetWriter.error {
                        print("Asset Writer Error: \(error)")
                    }
                }
            }
        } else if output == audioOutput, let audioInput = assetWriter.inputs.first(where: { $0.mediaType == .audio }),
                  audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
}

// MARK: - Utilities
extension CameraViewController {
    func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            let settingsAction = UIAlertAction(title: "Settings", style: .default) { _ in
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
            alert.addAction(settingsAction)
            alert.addAction(cancelAction)
            self.present(alert, animated: true)
        }
    }
}
