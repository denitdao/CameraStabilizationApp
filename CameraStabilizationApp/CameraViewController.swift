import UIKit
import AVFoundation
import Photos

class CameraViewController: UIViewController {
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    
    // MARK: - Properties
    var captureSession: AVCaptureSession!
    var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    var videoOutput: AVCaptureVideoDataOutput!
    var audioOutput: AVCaptureAudioDataOutput!
    
    var assetWriter: AVAssetWriter!
    var videoInput: AVAssetWriterInput!
    var audioInput: AVAssetWriterInput!
    var isRecording = false
    var outputURL: URL!
    
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    
    // For synchronization
    let recordingQueue = DispatchQueue(label: "recordingQueue")
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        requestPermissions {
            self.setupCameraSession()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Update preview layer frame
        videoPreviewLayer?.frame = view.bounds
    }
    
    // MARK: - Button State Management
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        recordButton.isEnabled = false
        stopButton.isEnabled = true
        startRecording()
    }

    @IBAction func stopButtonTapped(_ sender: UIButton) {
        stopButton.isEnabled = false
        stopRecording()
    }
}

// MARK: - Permissions
extension CameraViewController {
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

// MARK: - Camera Setup
extension CameraViewController {
    func setupCameraSession() {
        // Move capture session setup to a background queue
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession = AVCaptureSession()
            self.captureSession.sessionPreset = .high
            
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
                  self.captureSession.canAddInput(videoDeviceInput) else {
                print("Cannot add video input")
                return
            }
            self.captureSession.addInput(videoDeviceInput)
            
            // Initialize Rotation Coordinator
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: nil)
            self.rotationCoordinator?.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture), options: [.new], context: nil)
            self.rotationCoordinator?.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelPreview), options: [.new], context: nil)
            
            guard let audioDevice = AVCaptureDevice.default(for: .audio),
                  let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice),
                  self.captureSession.canAddInput(audioDeviceInput) else {
                print("Cannot add audio input")
                return
            }
            self.captureSession.addInput(audioDeviceInput)
            
            self.videoOutput = AVCaptureVideoDataOutput()
            self.videoOutput.setSampleBufferDelegate(self, queue: self.recordingQueue)
            guard self.captureSession.canAddOutput(self.videoOutput) else {
                print("Cannot add video output")
                return
            }
            self.captureSession.addOutput(self.videoOutput)
            
            self.audioOutput = AVCaptureAudioDataOutput()
            self.audioOutput.setSampleBufferDelegate(self, queue: self.recordingQueue)
            guard self.captureSession.canAddOutput(self.audioOutput) else {
                print("Cannot add audio output")
                return
            }
            self.captureSession.addOutput(self.audioOutput)
            
            // Start capture session in background to avoid blocking UI
            self.captureSession.startRunning()
            
            // Move UI updates back to the main queue
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
}

// MARK: - Recording
extension CameraViewController {
    func startRecording() {
        isRecording = true
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        
        recordingQueue.async {
            do {
                self.assetWriter = try AVAssetWriter(outputURL: self.outputURL, fileType: .mov)
                
                // Video Input Settings
                let videoSettings = self.videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
                self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                self.videoInput.expectsMediaDataInRealTime = true
                
                // Apply initial rotation transform before starting writing
                if let rotationCoordinator = self.rotationCoordinator {
                    let rotationAngleDegrees = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
                    let rotationAngleRadians = rotationAngleDegrees * (.pi / 180)
                    self.videoInput.transform = CGAffineTransform(rotationAngle: rotationAngleRadians)
                }
                
                if self.assetWriter.canAdd(self.videoInput) {
                    self.assetWriter.add(self.videoInput)
                } else {
                    print("Cannot add video input to asset writer")
                    self.resetRecordingState()
                    return
                }
                
                // Audio Input Settings
                let audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                self.audioInput.expectsMediaDataInRealTime = true
                if self.assetWriter.canAdd(self.audioInput) {
                    self.assetWriter.add(self.audioInput)
                } else {
                    print("Cannot add audio input to asset writer")
                    self.resetRecordingState()
                    return
                }
                
                print("Asset writer initialized.")
                // Do NOT call startWriting() here
            } catch {
                print("Error setting up asset writer: \(error)")
                self.resetRecordingState()
            }
        }
    }

    func stopRecording() {
        isRecording = false
        guard assetWriter != nil else {
            print("Asset writer is nil.")
            resetRecordingState()
            return
        }
        
        recordingQueue.async {
            if self.assetWriter.status == .writing || self.assetWriter.status == .unknown {
                self.assetWriter.finishWriting {
                    DispatchQueue.main.async {
                        if self.assetWriter.status == .completed {
                            self.saveVideoToPhotoLibrary(url: self.outputURL)
                        } else {
                            print("Asset writer did not complete successfully.")
                            if let error = self.assetWriter.error {
                                print("Asset Writer Error: \(error.localizedDescription)")
                            }
                            self.resetRecordingState()
                        }
                    }
                }
            } else {
                print("Asset writer is not in a valid state to finish writing.")
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
            self.videoInput = nil
            self.audioInput = nil
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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard self.isRecording else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if self.assetWriter.status == .unknown {
            self.assetWriter.startWriting()
            self.assetWriter.startSession(atSourceTime: timestamp)
            print("Asset writer started writing and session started at \(timestamp)")
        }
        
        if self.assetWriter.status == .writing {
            if output == self.videoOutput, self.videoInput.isReadyForMoreMediaData {
                if !self.videoInput.append(sampleBuffer) {
                    print("Failed to append video sample buffer")
                    if let error = self.assetWriter.error {
                        print("Video Input Error: \(error.localizedDescription)")
                    }
                }
            } else if output == self.audioOutput, self.audioInput.isReadyForMoreMediaData {
                if !self.audioInput.append(sampleBuffer) {
                    print("Failed to append audio sample buffer")
                    if let error = self.assetWriter.error {
                        print("Audio Input Error: \(error.localizedDescription)")
                    }
                }
            }
        } else if self.assetWriter.status == .failed {
            if let error = self.assetWriter.error {
                print("Asset writer error: \(error.localizedDescription)")
            }
            self.resetRecordingState()
        }
    }
}

// MARK: - Observing Rotation
extension CameraViewController {
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?,     context: UnsafeMutableRawPointer?) {
        guard let rotationCoordinator = object as? AVCaptureDevice.RotationCoordinator else {
            return
        }
        
        if keyPath == #keyPath(AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture) {
            let rotationAngleDegrees = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
            print("Rotation angle for capture: \(rotationAngleDegrees) degrees")
            
            // Update the video connection's rotation angle
            if let videoConnection = self.videoOutput.connection(with: .video) {
                if videoConnection.isVideoRotationAngleSupported(rotationAngleDegrees) {
                    videoConnection.videoRotationAngle = rotationAngleDegrees
                } else {
                    print("Video rotation angle \(rotationAngleDegrees) not supported for video connection.")
                }
            }
        } else if keyPath == #keyPath(AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelPreview) {
            let rotationAngleDegrees = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
            print("Rotation angle for preview: \(rotationAngleDegrees) degrees")
            
            // Update the preview layer's rotation angle
            if let previewConnection = self.videoPreviewLayer.connection {
                if previewConnection.isVideoRotationAngleSupported(rotationAngleDegrees) {
                    previewConnection.videoRotationAngle = rotationAngleDegrees
                } else {
                    print("Video rotation angle \(rotationAngleDegrees) not supported for preview connection.")
                }
            }
        }
    }
}

// MARK: - Utilities
extension CameraViewController {
    func showAlert(title: String, message: String) {
        DispatchQueue.main.async { // Ensure UI updates are on the main thread
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
