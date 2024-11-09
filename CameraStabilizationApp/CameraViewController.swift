//
//  CameraViewController.swift
//  CameraStabilizationApp
//
//  Created by Denys Churchyn on 09.11.2024.
//

import UIKit
import AVFoundation
import CoreMotion

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
            self.checkMotionAuthorization()
        case .notDetermined:
            // Microphone access has not been requested yet.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.checkMotionAuthorization()
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
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high

        // Set up video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ??
              AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            print("Error: No camera devices are available.")
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
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
              captureSession.canAddInput(audioInput) else {
            print("Error setting up audio input.")
            return
        }
        captureSession.addInput(audioInput)

        // Set up video output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        captureSession.addOutput(videoOutput)

        // Configure the preview layer
        videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.videoGravity = .resizeAspectFill

        // Add the preview layer to the view hierarchy
        DispatchQueue.main.async {
            // Assuming you have a UIView named previewView
            self.videoPreviewLayer.frame = self.view.bounds
            self.view.layer.insertSublayer(self.videoPreviewLayer, at: 0)
        }

        // Start the session
        captureSession.startRunning()
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
        UIView.animate(withDuration: 0.1) {
            self.videoPreviewLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(-angle)))
        }
    }

    // MARK: - Other Methods
    // Include methods for recording, stopping recording, and handling AVCaptureVideoDataOutputSampleBufferDelegate
    var assetWriter: AVAssetWriter!
    var assetWriterInput: AVAssetWriterInput!
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    var isRecording = false

    func startRecording() {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("output.mov")
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let outputSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: NSNumber(value: Float(view.frame.width)),
                AVVideoHeightKey: NSNumber(value: Float(view.frame.height))
            ]
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            assetWriterInput.expectsMediaDataInRealTime = true

            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput,
                sourcePixelBufferAttributes: nil
            )

            if assetWriter.canAdd(assetWriterInput) {
                assetWriter.add(assetWriterInput)
            }

            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: .zero)
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
            // Optionally, save video to photo library
            UISaveVideoAtPathToSavedPhotosAlbum(self.assetWriter.outputURL.path, self, #selector(self.video(_:didFinishSavingWithError:contextInfo:)), nil)
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Apply rotation to ciImage
        let rotatedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-currentRotationAngle)))

        // Create a pixel buffer from the rotated image
        var newPixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary

        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(rotatedImage.extent.width),
                                         Int(rotatedImage.extent.height),
                                         kCVPixelFormatType_32BGRA,
                                         attributes,
                                         &newPixelBuffer)

        guard status == kCVReturnSuccess, let outputPixelBuffer = newPixelBuffer else {
            print("Error creating pixel buffer.")
            return
        }

        // Render the CIImage into the pixel buffer
        let context = CIContext()
        context.render(rotatedImage, to: outputPixelBuffer)

        // Append pixel buffer to asset writer
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        pixelBufferAdaptor.append(outputPixelBuffer, withPresentationTime: presentationTime)
    }
}
