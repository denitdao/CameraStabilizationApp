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

    @IBAction func recordButtonTapped(_ sender: UIButton) {
        startRecording()
    }

    @IBAction func stopButtonTapped(_ sender: UIButton) {
        stopRecording()
    }
    
    // MARK: - Properties
    var captureSession: AVCaptureSession!
    var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    var videoOutput: AVCaptureVideoDataOutput!

    let motionManager = CMMotionManager()
    var currentRotationAngle: Double = 0.0

    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        checkPermissions()
    }

    
    // MARK: - Permission Checks
    func checkPermissions() {
        checkCameraAuthorization()
    }

    func checkCameraAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Camera access is already authorized.
            setupCameraSession()
            checkMicrophoneAuthorization()
        case .notDetermined:
            // Camera access has not been requested yet.
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.setupCameraSession()
                        self.checkMicrophoneAuthorization()
                    } else {
                        print("Camera access denied.")
                        // Handle denial (e.g., show an alert to the user)
                    }
                }
            }
        default:
            print("Camera access denied.")
            // Handle denial
        }
    }

    func checkMicrophoneAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // Microphone access is already authorized.
            // Remove or comment out the following line:
            // self.checkMotionAuthorization()
            break
        case .notDetermined:
            // Microphone access has not been requested yet.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        // Remove or comment out the following line:
                        // self.checkMotionAuthorization()
                    } else {
                        print("Microphone access denied.")
                        // Handle denial
                    }
                }
            }
        default:
            print("Microphone access denied.")
            // Handle denial
        }
    }


    func checkMotionAuthorization() {
        if #available(iOS 11.0, *) {
            let status = CMMotionActivityManager.authorizationStatus()
            switch status {
            case .authorized:
                self.startDeviceMotionUpdates()
            case .notDetermined:
                self.startDeviceMotionUpdates() // The system will prompt the user.
            default:
                print("Motion data access denied.")
                // Handle denial
            }
        } else {
            // For iOS versions prior to 11.0
            self.startDeviceMotionUpdates()
        }
    }

    // MARK: - Camera Setup
    func setupCameraSession() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession = AVCaptureSession()
            self.captureSession.sessionPreset = .high

            // Set up video input
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera, .builtInTrueDepthCamera],
                mediaType: .video,
                position: .unspecified
            )

            guard let videoDevice = discoverySession.devices.first else {
                print("Error: No camera devices are available.")
                return
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
                    return
                }
            } catch {
                print("Error creating video input: \(error.localizedDescription)")
                return
            }

            // Set up audio input (optional)
            guard let audioDevice = AVCaptureDevice.default(for: .audio),
                  let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                  self.captureSession.canAddInput(audioInput) else {
                print("Error setting up audio input.")
                return
            }
            self.captureSession.addInput(audioInput)

            // Set up video output
            self.videoOutput = AVCaptureVideoDataOutput()
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            } else {
                print("Error: Cannot add video output to the session.")
                return
            }

            // Start the session
            self.captureSession.startRunning()
            
            // Configure the preview layer
            DispatchQueue.main.async {
                self.videoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                self.videoPreviewLayer.videoGravity = .resizeAspectFill
                self.videoPreviewLayer.frame = self.view.bounds
                self.view.layer.insertSublayer(self.videoPreviewLayer, at: 0)

                // Start device motion updates after the videoPreviewLayer is set up
                self.checkMotionAuthorization()
            }
        }
    }


    // MARK: - Motion Handling
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
        let angle = atan2(x, y) - .pi
        currentRotationAngle = angle
        applyRotation(angle)
    }

    func applyRotation(_ angle: Double) {
        guard let previewLayer = self.videoPreviewLayer else {
            // Optionally log a message or handle the nil case
            print("Warning: videoPreviewLayer is nil in applyRotation")
            return
        }

        UIView.animate(withDuration: 0.1) {
            previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(-angle)))
        }
    }

    // MARK: - Other Methods
    // Include methods for recording, stopping recording, and handling AVCaptureVideoDataOutputSampleBufferDelegate
    var assetWriter: AVAssetWriter!
    var assetWriterInput: AVAssetWriterInput!
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    var isRecording = false
    var videoWidth: Int = 0
    var videoHeight: Int = 0

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
        PHPhotoLibrary.requestAuthorization { status in
            switch status {
            case .authorized:
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
                // Handle denial
            case .notDetermined:
                // Should not reach here
                break
            case .limited:
                // Handle limited access if needed
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { saved, error in
                    if let error = error {
                        print("Error saving video: \(error.localizedDescription)")
                    } else {
                        print("Video saved successfully.")
                    }
                }
            @unknown default:
                break
            }
        }
    }

    @objc func video(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo info: AnyObject) {
        if let error = error {
            print("Error saving video: \(error.localizedDescription)")
        } else {
            print("Video saved successfully.")
        }
    }

}

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
            // Continue as normal
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

            // Apply rotation to ciImage
            let rotatedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-currentRotationAngle)))

            // Create a new pixel buffer
            var newPixelBuffer: CVPixelBuffer?
            let pixelBufferAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
            let contextOptions = [CIContextOption.useSoftwareRenderer: false]
            let context = CIContext(options: contextOptions)
            context.render(rotatedImage, to: outputPixelBuffer)

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

