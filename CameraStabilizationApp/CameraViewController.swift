//
//  CameraViewController.swift
//  CameraStabilizationApp
//
//  Created by Denys Churchyn on 09.11.2024.
//

import UIKit
import AVFoundation
import CoreMotion
import Photos

class CameraViewController: UIViewController {
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    
    // MARK: - Properties
    var captureSession: AVCaptureSession!
    var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    var videoOutput: AVCaptureVideoDataOutput!
    
    let motionManager = CMMotionManager()
    var currentRotationAngle: Double = 0.0
    var previousRotationAngle: Double = 0.0
    let filterFactor: Double = 0.9 // Adjust between 0.0 (no filtering) and 1.0 (maximum filtering)
    
    var assetWriter: AVAssetWriter!
    var assetWriterInput: AVAssetWriterInput!
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    var isRecording = false
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        PermissionsManager.shared.requestAllPermissions { granted in
            if granted {
                self.setupCameraSession()
            } else {
                self.showAlert(title: "Permissions Denied", message: "Please enable permissions in Settings.")
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Start observing device orientation changes
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop observing device orientation changes
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    // MARK: - UI Actions
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        startRecording()
    }
    
    @IBAction func stopButtonTapped(_ sender: UIButton) {
        stopRecording()
    }
}

// MARK: - Permissions
class PermissionsManager {
    static let shared = PermissionsManager()

    func requestAllPermissions(completion: @escaping (Bool) -> Void) {
        let dispatchGroup = DispatchGroup()
        var permissionsGranted = true

        dispatchGroup.enter()
        requestCameraPermission { granted in
            permissionsGranted = permissionsGranted && granted
            dispatchGroup.leave()
        }

        dispatchGroup.enter()
        requestMicrophonePermission { granted in
            permissionsGranted = permissionsGranted && granted
            dispatchGroup.leave()
        }

        dispatchGroup.enter()
        requestMotionPermission { granted in
            permissionsGranted = permissionsGranted && granted
            dispatchGroup.leave()
        }

        dispatchGroup.enter()
        requestPhotoLibraryPermission { granted in
            permissionsGranted = permissionsGranted && granted
            dispatchGroup.leave()
        }

        dispatchGroup.notify(queue: .main) {
            completion(permissionsGranted)
        }
    }

    private func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func requestMotionPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 11.0, *) {
            let status = CMMotionActivityManager.authorizationStatus()
            switch status {
            case .authorized:
                completion(true)
            case .notDetermined:
                // The system will prompt the user when starting motion updates
                completion(true)
            default:
                completion(false)
            }
        } else {
            completion(true)
        }
    }

    private func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        default:
            completion(false)
        }
    }
}

// MARK: - Camera Setup
extension CameraViewController {
    func setupCameraSession() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession = AVCaptureSession()
            self.captureSession.sessionPreset = .high

            guard self.setupVideoInput(),
                  self.setupAudioInput(),
                  self.setupVideoOutput() else {
                print("Failed to set up camera session.")
                return
            }

            self.captureSession.startRunning()

            DispatchQueue.main.async {
                self.setupPreviewLayer()
                self.startDeviceMotionUpdates()
            }
        }
    }

    func setupVideoInput() -> Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified
        )

        guard let videoDevice = discoverySession.devices.first else {
            print("Error: No camera devices are available.")
            return false
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if self.captureSession.canAddInput(videoInput) {
                self.captureSession.addInput(videoInput)

                // Get video dimensions
                let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
                self.videoWidth = Int(dimensions.width)
                self.videoHeight = Int(dimensions.height)
            } else {
                print("Error: Cannot add video input to the session.")
                return false
            }
        } catch {
            print("Error creating video input: \(error.localizedDescription)")
            return false
        }

        return true
    }

    func setupAudioInput() -> Bool {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("Error: No audio devices are available.")
            return false
        }

        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if self.captureSession.canAddInput(audioInput) {
                self.captureSession.addInput(audioInput)
            } else {
                print("Error: Cannot add audio input to the session.")
                return false
            }
        } catch {
            print("Error creating audio input: \(error.localizedDescription)")
            return false
        }

        return true
    }

    func setupVideoOutput() -> Bool {
        self.videoOutput = AVCaptureVideoDataOutput()
        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        if self.captureSession.canAddOutput(self.videoOutput) {
            self.captureSession.addOutput(self.videoOutput)
            return true
        } else {
            print("Error: Cannot add video output to the session.")
            return false
        }
    }

    func setupPreviewLayer() {
        self.videoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
        self.videoPreviewLayer.videoGravity = .resizeAspectFill
        self.videoPreviewLayer.frame = self.view.bounds
        self.view.layer.insertSublayer(self.videoPreviewLayer, at: 0)

        // Set initial orientation
        if let connection = self.videoPreviewLayer.connection {
            connection.videoOrientation = .portrait
        }
    }
}

// MARK: - Motion Handling
extension CameraViewController {
    func startDeviceMotionUpdates() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { (motion, error) in
                if let error = error {
                    print("Motion update error: \(error.localizedDescription)")
                    return
                }
                guard let motion = motion else { return }
                self.handleDeviceMotionUpdate(motion)
            }
        } else {
            print("Device motion not available.")
            // Handle the absence of device motion.
        }
    }

    func handleDeviceMotionUpdate(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let x = gravity.x
        let y = gravity.y

        var tiltAngle: Double = 0.0
        let deviceOrientation = UIDevice.current.orientation

        switch deviceOrientation {
        case .portrait:
            tiltAngle = atan2(y, x) - .pi / 2
        case .landscapeRight:
            tiltAngle = atan2(-x, y) - .pi / 2
        case .landscapeLeft:
            tiltAngle = atan2(x, -y) - .pi / 2
        case .portraitUpsideDown:
            tiltAngle = atan2(-y, -x) - .pi / 2
        default:
            tiltAngle = atan2(y, x) - .pi / 2
        }

        tiltAngle = -tiltAngle

        // Normalize angle to range [-π, π]
        if tiltAngle > .pi {
            tiltAngle -= 2 * .pi
        } else if tiltAngle < -.pi {
            tiltAngle += 2 * .pi
        }

        // Apply filter factor
        currentRotationAngle = filterFactor * previousRotationAngle + (1 - filterFactor) * tiltAngle
        previousRotationAngle = currentRotationAngle

        applyRotation(currentRotationAngle)
    }

    func applyRotation(_ angle: Double) {
        guard let previewLayer = self.videoPreviewLayer else {
            print("Warning: videoPreviewLayer is nil in applyRotation")
            return
        }

        // Apply rotation immediately without animation
        previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(angle)))
    }

    @objc func orientationChanged() {
        guard let connection = videoPreviewLayer?.connection,
              let videoConnection = videoOutput.connection(with: .video) else { return }

        let deviceOrientation = UIDevice.current.orientation

        switch deviceOrientation {
        case .portrait:
            connection.videoOrientation = .portrait
            videoConnection.videoOrientation = .portrait
        case .landscapeRight:
            connection.videoOrientation = .landscapeLeft
            videoConnection.videoOrientation = .landscapeLeft
        case .landscapeLeft:
            connection.videoOrientation = .landscapeRight
            videoConnection.videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
            videoConnection.videoOrientation = .portraitUpsideDown
        default:
            connection.videoOrientation = .portrait
            videoConnection.videoOrientation = .portrait
        }

        // Adjust the preview layer frame
        videoPreviewLayer.frame = self.view.bounds
    }
}

// MARK: - Recording
extension CameraViewController {
    func startRecording() {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("output.mov")

        // Remove existing file if necessary
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                print("Could not remove file at url: \(outputURL)")
                return
            }
        }

        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            let videoWidth = self.videoWidth
            let videoHeight = self.videoHeight

            let outputSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: NSNumber(value: 6000000),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            assetWriterInput.expectsMediaDataInRealTime = true

            // Determine the video orientation transform
            let currentOrientation = UIDevice.current.orientation
            var rotationAngle: CGFloat = 0.0

            switch currentOrientation {
            case .portrait:
                rotationAngle = 0.0
            case .landscapeRight:
                rotationAngle = CGFloat(-Double.pi / 2)
            case .landscapeLeft:
                rotationAngle = CGFloat(Double.pi / 2)
            case .portraitUpsideDown:
                rotationAngle = CGFloat(Double.pi)
            default:
                rotationAngle = 0.0
            }

            assetWriterInput.transform = CGAffineTransform(rotationAngle: rotationAngle)

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
            } else {
                print("Cannot add asset writer input.")
                return
            }

            // Do not start writing yet; start when the first sample buffer is received
            isRecording = true
        } catch {
            print("Error setting up asset writer: \(error)")
        }
    }

    func stopRecording() {
        isRecording = false
        assetWriterInput.markAsFinished()
        assetWriter.finishWriting {
            print("Recording finished.")
            if self.assetWriter.status == .completed {
                self.saveVideoToPhotoLibrary(url: self.assetWriter.outputURL)
            } else {
                if let error = self.assetWriter.error {
                    print("Asset Writer Error: \(error.localizedDescription)")
                    print("Asset Writer Error Details: \(error)")
                } else {
                    print("Asset Writer Error: Unknown error")
                }
            }
        }
    }

    func saveVideoToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { saved, error in
                    if let error = error {
                        print("Error saving video: \(error.localizedDescription)")
                    } else {
                        print("Video saved successfully.")
                    }
                }
            case .denied, .restricted:
                print("Photo Library access denied.")
                self.showAlert(title: "Photo Library Access Denied", message: "Please enable access in Settings.")
            case .notDetermined:
                // Should not reach here
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Video Processing
extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Start asset writer when first sample buffer is received
        switch assetWriter.status {
        case .unknown:
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: presentationTime)
        case .writing:
            break
        case .failed, .cancelled, .completed:
            if let error = assetWriter.error {
                print("Asset Writer Error: \(error.localizedDescription)")
                print("Asset Writer Error Details: \(error)")
            }
            return
        default:
            return
        }

        if assetWriterInput.isReadyForMoreMediaData {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Adjust transformations based on device orientation
            let deviceOrientation = UIDevice.current.orientation
            var rotationTransform: CGAffineTransform

            switch deviceOrientation {
            case .portrait:
                rotationTransform = CGAffineTransform(rotationAngle: CGFloat(currentRotationAngle))
            case .landscapeRight:
                rotationTransform = CGAffineTransform(rotationAngle: CGFloat(currentRotationAngle - .pi / 2))
            case .landscapeLeft:
                rotationTransform = CGAffineTransform(rotationAngle: CGFloat(currentRotationAngle + .pi / 2))
            case .portraitUpsideDown:
                rotationTransform = CGAffineTransform(rotationAngle: CGFloat(currentRotationAngle + .pi))
            default:
                rotationTransform = CGAffineTransform(rotationAngle: CGFloat(currentRotationAngle))
            }

            // Center the rotation
            let centerTransform = CGAffineTransform(translationX: -CGFloat(videoWidth) / 2, y: -CGFloat(videoHeight) / 2)
            let backTransform = CGAffineTransform(translationX: CGFloat(videoWidth) / 2, y: CGFloat(videoHeight) / 2)

            let transformedImage = ciImage
                .transformed(by: centerTransform)
                .transformed(by: rotationTransform)
                .transformed(by: backTransform)

            // Create a new pixel buffer for the rotated image
            var newPixelBuffer: CVPixelBuffer?
            let pixelBufferAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: self.videoWidth,
                kCVPixelBufferHeightKey as String: self.videoHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as [String: Any]

            let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                             self.videoWidth,
                                             self.videoHeight,
                                             kCVPixelFormatType_32BGRA,
                                             pixelBufferAttributes as CFDictionary,
                                             &newPixelBuffer)

            guard status == kCVReturnSuccess, let outputPixelBuffer = newPixelBuffer else {
                print("Error creating pixel buffer.")
                return
            }

            // Render the rotated image into the new pixel buffer
            let context = CIContext(options: nil)
            context.render(transformedImage, to: outputPixelBuffer)

            // Append pixel buffer to asset writer
            if !pixelBufferAdaptor.append(outputPixelBuffer, withPresentationTime: presentationTime) {
                print("Failed to append pixel buffer.")
                if let error = assetWriter.error {
                    print("Asset Writer Error during append: \(error.localizedDescription)")
                }
            }
        } else {
            print("Asset Writer Input not ready for more media data.")
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
