import UIKit
import AVFoundation
import Photos
import CoreMotion
import ObjectiveC

// MARK: - PermissionsManager
class PermissionsManager {
    func requestAllPermissions(completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var permissionGranted = true
        
        // Camera
        group.enter()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            permissionGranted = permissionGranted && granted
            group.leave()
        }
        
        // Microphone
        group.enter()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            permissionGranted = permissionGranted && granted
            group.leave()
        }
        
        // Photo Library
        group.enter()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            permissionGranted = permissionGranted && (status == .authorized || status == .limited)
            group.leave()
        }
        
        group.notify(queue: .main) {
            completion(permissionGranted)
        }
    }
}

// MARK: - CameraControllerDelegate
protocol CameraControllerDelegate: AnyObject {
    func cameraController(_ controller: CameraController, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)
    func cameraController(_ controller: CameraController, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
}

// MARK: - CameraController
class CameraController: NSObject {
    weak var delegate: CameraControllerDelegate?
    
    private let captureSession = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput!
    private var audioOutput: AVCaptureAudioDataOutput!
    
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    
    private let captureQueue = DispatchQueue(label: "CameraCaptureQueue")
    
    func configureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        
        // Video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            print("Cannot setup video input")
            captureSession.commitConfiguration()
            return
        }
        
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        videoWidth = Int(dimensions.width)
        videoHeight = Int(dimensions.height)
        
        // Audio input
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }
        
        // Video output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        // Audio output
        audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
        
        captureSession.commitConfiguration()
    }
    
    func startSession() {
        captureSession.startRunning()
    }
    
    func stopSession() {
        captureSession.stopRunning()
    }
    
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        return previewLayer
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            delegate?.cameraController(self, didOutputVideoSampleBuffer: sampleBuffer)
        } else if output == audioOutput {
            delegate?.cameraController(self, didOutputAudioSampleBuffer: sampleBuffer)
        }
    }
}

// MARK: - RecordingBaselineOrientation
enum RecordingBaselineOrientation {
    case portrait
    case landscape
}

// MARK: - MotionStabilizer
class MotionStabilizer {
    private let motionManager = CMMotionManager()
    var currentRotationAngle: Double = 0.0
    var currentScaleFactor: Double = 1.0
    
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    private var baselineOrientation: RecordingBaselineOrientation = .portrait
    private var initialBaselineAngle: Double = 0.0 // quantized baseline angle
    
    private var updateCount = 0
    
    func startUpdates(videoWidth: Int, videoHeight: Int, baselineOrientation: RecordingBaselineOrientation) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.baselineOrientation = baselineOrientation
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else { return }
            self.updateAngleAndScale(motion: motion)
        }
    }
    
    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }
    
    func computeCurrentTiltAngle() -> Double {
        guard let motion = motionManager.deviceMotion else { return 0.0 }
        let x = motion.gravity.x
        let y = motion.gravity.y
        var angle = atan2(y, x) - .pi / 2
        angle += .pi
        angle = -angle
        // Normalize
        if angle > .pi {
            angle -= 2 * .pi
        } else if angle < -.pi {
            angle += 2 * .pi
        }
        return angle
    }
    
    func quantizeAngleToRightAngle(_ angle: Double) -> Double {
        // angle / (π/2) -> number of quarter turns
        let quarterTurns = angle / (Double.pi / 2)
        let nearestQuarterTurn = round(quarterTurns)
        return nearestQuarterTurn * (Double.pi / 2)
    }
    
    func setInitialBaselineAngle() {
        let currentAngle = computeCurrentTiltAngle()
        initialBaselineAngle = quantizeAngleToRightAngle(currentAngle)
        
        if baselineOrientation == .landscape {
            let normalized = normalizeAngle(initialBaselineAngle)
            
            // If quantized to exactly ±90° (±π/2):
            if abs(normalized) == Double.pi / 2 {
                // If it's -90°, rotate by 180° (π) to get +90°
                if normalized < 0 {
                    initialBaselineAngle += Double.pi
                    initialBaselineAngle = normalizeAngle(initialBaselineAngle)
                }
                // If it's +90°, do nothing, since it's already correct.
            }
        }
        
        print("[DEBUG] Initial baseline angle set to \(initialBaselineAngle * 180.0 / Double.pi) degrees")
    }
    
    // Helper to normalize angle to [-π, π]
    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle
        if a > .pi {
            a -= 2 * .pi
        } else if a < -.pi {
            a += 2 * .pi
        }
        return a
    }
    
    private func updateAngleAndScale(motion: CMDeviceMotion) {
        updateCount += 1
        
        let gravity = motion.gravity
        let x = gravity.x
        let y = gravity.y
        
        var tiltAngle = atan2(y, x) - .pi / 2
        tiltAngle += .pi
        tiltAngle = -tiltAngle
        
        // Normalize angle to [-π, π]
        if tiltAngle > .pi {
            tiltAngle -= 2 * .pi
        } else if tiltAngle < -.pi {
            tiltAngle += 2 * .pi
        }
        
        // Subtract the initial baseline angle
        var effectiveAngle = tiltAngle - initialBaselineAngle
        if effectiveAngle > .pi {
            effectiveAngle -= 2 * .pi
        } else if effectiveAngle < -.pi {
            effectiveAngle += 2 * .pi
        }
        
        let adjustedAngle: Double
        switch baselineOrientation {
        case .portrait:
            adjustedAngle = effectiveAngle
        case .landscape:
            // If you need a pi/2 offset for landscape baseline, do it here:
            // adjustedAngle = effectiveAngle - (Double.pi / 2)
            adjustedAngle = effectiveAngle
        }
        
        currentRotationAngle = adjustedAngle
        
        // Determine reference dimensions based on baseline orientation
        let referenceWidth: Int
        let referenceHeight: Int
        switch baselineOrientation {
        case .portrait:
            referenceWidth = videoWidth
            referenceHeight = videoHeight
        case .landscape:
            referenceWidth = videoHeight
            referenceHeight = videoWidth
        }
        
        let cosTheta = abs(cos(adjustedAngle))
        let sinTheta = abs(sin(adjustedAngle))
        
        let rotatedWidth = CGFloat(referenceWidth) * cosTheta + CGFloat(referenceHeight) * sinTheta
        let rotatedHeight = CGFloat(referenceWidth) * sinTheta + CGFloat(referenceHeight) * cosTheta
        
        let scaleX = rotatedWidth / CGFloat(referenceWidth)
        let scaleY = rotatedHeight / CGFloat(referenceHeight)
        let scale = Double(max(scaleX, scaleY))
        
        currentScaleFactor = scale
        
        // Print logs every 30 updates
        if updateCount % 30 == 0 {
            let angleDegrees = adjustedAngle * 180.0 / Double.pi
            var phoneRotationAssumption: String
            if angleDegrees > -45 && angleDegrees < 45 {
                phoneRotationAssumption = "Phone is near baseline orientation"
            } else if angleDegrees >= 45 && angleDegrees <= 135 {
                phoneRotationAssumption = "Phone tilted ~90° in one direction"
            } else if angleDegrees <= -45 && angleDegrees >= -135 {
                phoneRotationAssumption = "Phone tilted ~90° in the opposite direction"
            } else {
                phoneRotationAssumption = "Phone possibly upside-down or beyond 90° tilt"
            }
            
            print("""
            [DEBUG] UpdateAngleAndScale (sampled):
            Gravity: x=\(x), y=\(y)
            tiltAngle(rad)=\(tiltAngle), effectiveAngle(rad)=\(effectiveAngle) deg=\(angleDegrees)
            BaselineOrientation=\(baselineOrientation)
            rotatedWidth=\(rotatedWidth), rotatedHeight=\(rotatedHeight)
            scale=\(scale)
            Assumption: \(phoneRotationAssumption)
            """)
        }
    }
}

// MARK: - VideoProcessor
class VideoProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    func stabilizeFrame(ciImage: CIImage,
                        width: Int,
                        height: Int,
                        rotationAngle: Double,
                        scaleFactor: Double,
                        baselineOrientation: RecordingBaselineOrientation) -> CVPixelBuffer? {
        
        let transform = buildTransform(width: width, height: height, angle: rotationAngle, scale: scaleFactor, baselineOrientation: baselineOrientation)
        let transformedImage = ciImage.transformed(by: transform)
        
        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                            width,
                            height,
                            kCVPixelFormatType_32BGRA,
                            nil,
                            &outputPixelBuffer)
        
        if let buffer = outputPixelBuffer {
            context.render(transformedImage, to: buffer)
            return buffer
        }
        return nil
    }
    
    private func buildTransform(width: Int, height: Int, angle: Double, scale: Double, baselineOrientation: RecordingBaselineOrientation) -> CGAffineTransform {
        // Remove the special offset for landscape mode:
        let adjustedAngle = angle
        
        let centerTransform = CGAffineTransform(translationX: -CGFloat(width)/2, y: -CGFloat(height)/2)
        let rotationTransform = CGAffineTransform(rotationAngle: CGFloat(adjustedAngle))
        let scaleTransform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        let backTransform = CGAffineTransform(translationX: CGFloat(width)/2, y: CGFloat(height)/2)
        
        return centerTransform
            .concatenating(rotationTransform)
            .concatenating(scaleTransform)
            .concatenating(backTransform)
    }
}

// MARK: - RecordingManager
class RecordingManager {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    let videoWidth: Int
    let videoHeight: Int
    
    var baselineOrientation: RecordingBaselineOrientation {
        get { associatedBaselineOrientation ?? .portrait }
        set { associatedBaselineOrientation = newValue }
    }
    
    private struct AssociatedKeys {
        static var baselineOrientation = "baselineOrientation"
    }
    
    private var associatedBaselineOrientation: RecordingBaselineOrientation? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.baselineOrientation) as? RecordingBaselineOrientation
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.baselineOrientation, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    var status: AVAssetWriter.Status {
        return assetWriter?.status ?? .unknown
    }
    
    var outputURL: URL?
    
    init(videoWidth: Int, videoHeight: Int) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }
    
    func startRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        self.outputURL = url
        
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6000000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        
        switch baselineOrientation {
        case .portrait:
            vInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        case .landscape:
            vInput.transform = .identity
        }
        
        print("[DEBUG] AssetWriter Input transform for \(baselineOrientation): \(vInput.transform)")
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        
        if writer.canAdd(vInput) {
            writer.add(vInput)
        }
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) {
            writer.add(aInput)
        }
        
        self.assetWriter = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.pixelBufferAdaptor = adaptor
    }
    
    func startSession(timestamp: CMTime) {
        guard let writer = assetWriter else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: timestamp)
    }
    
    func appendVideo(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let writer = assetWriter,
              let vInput = videoInput,
              let adaptor = pixelBufferAdaptor,
              writer.status == .writing,
              vInput.isReadyForMoreMediaData else { return }
        
        adaptor.append(pixelBuffer, withPresentationTime: timestamp)
    }
    
    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter,
              let aInput = audioInput,
              writer.status == .writing,
              aInput.isReadyForMoreMediaData else { return }
        aInput.append(sampleBuffer)
    }
    
    func stopRecording(completion: @escaping (URL?, Error?) -> Void) {
        guard let writer = assetWriter else {
            completion(nil, nil)
            return
        }
        
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        
        writer.finishWriting {
            if writer.status == .completed {
                completion(writer.outputURL, nil)
            } else {
                completion(nil, writer.error)
            }
        }
    }
}

// MARK: - CameraViewController
class CameraViewController: UIViewController {
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    
    private let permissionsManager = PermissionsManager()
    private let cameraController = CameraController()
    private let motionStabilizer = MotionStabilizer()
    private let videoProcessor = VideoProcessor()
    private var recordingManager: RecordingManager?
    
    private var isRecording = false
    private var recordingBaselineOrientation: RecordingBaselineOrientation = .portrait
    
    override func viewDidLoad() {
        super.viewDidLoad()
        lockOrientation()
        
        permissionsManager.requestAllPermissions { granted in
            guard granted else {
                self.showAlert(title: "Permissions Denied", message: "Please enable permissions in Settings.")
                return
            }
            self.setupCamera()
        }
    }
    
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
    
    private func setupCamera() {
        cameraController.delegate = self
        cameraController.configureSession()
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.cameraController.startSession()
            
            DispatchQueue.main.async {
                let previewLayer = self.cameraController.makePreviewLayer()
                previewLayer.frame = self.view.bounds
                self.view.layer.insertSublayer(previewLayer, at: 0)
                
                self.motionStabilizer.startUpdates(
                    videoWidth: self.cameraController.videoWidth,
                    videoHeight: self.cameraController.videoHeight,
                    baselineOrientation: self.recordingBaselineOrientation
                )
                
                self.stopButton.isEnabled = false
                
                print("[DEBUG] Camera configured. Video dimensions: \(self.cameraController.videoWidth)x\(self.cameraController.videoHeight)")
            }
        }
    }
    
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        determineBaselineOrientation()
        
        // Quantize and set initial baseline angle before recording
        motionStabilizer.setInitialBaselineAngle()
        
        startRecording()
    }
    
    @IBAction func stopButtonTapped(_ sender: UIButton) {
        stopRecording()
    }
    
    private func determineBaselineOrientation() {
        let deviceOrientation = UIDevice.current.orientation
        if deviceOrientation.isLandscape {
            recordingBaselineOrientation = .landscape
        } else {
            recordingBaselineOrientation = .portrait
        }
        
        // Restart motion updates with the new baseline orientation
        motionStabilizer.startUpdates(
            videoWidth: cameraController.videoWidth,
            videoHeight: cameraController.videoHeight,
            baselineOrientation: recordingBaselineOrientation
        )
        
        print("[DEBUG] Recording started. Baseline orientation: \(recordingBaselineOrientation)")
    }
    
    private func startRecording() {
        guard !isRecording else { return }
        
        let width = cameraController.videoWidth
        let height = cameraController.videoHeight
        
        let manager = RecordingManager(videoWidth: width, videoHeight: height)
        manager.baselineOrientation = recordingBaselineOrientation
        
        do {
            try manager.startRecording()
            recordingManager = manager
            isRecording = true
            recordButton.isEnabled = false
            stopButton.isEnabled = true
            
            print("[DEBUG] Started recording with baseline: \(recordingBaselineOrientation)")
            print("[DEBUG] Video target dimensions: \(width)x\(height)")
        } catch {
            showAlert(title: "Recording Error", message: "Cannot start recording: \(error)")
        }
    }
    
    private func stopRecording() {
        guard isRecording, let manager = recordingManager else { return }
        isRecording = false
        recordButton.isEnabled = true
        stopButton.isEnabled = false
        
        manager.stopRecording { url, error in
            if let url = url {
                self.saveVideoToPhotoLibrary(url: url)
                print("[DEBUG] Video saved at URL: \(url)")
            } else {
                print("[DEBUG] Error finishing writing: \(String(describing: error))")
            }
            self.recordingManager = nil
        }
        
        print("[DEBUG] Stopped recording.")
    }
    
    private func saveVideoToPhotoLibrary(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { saved, error in
            DispatchQueue.main.async {
                if saved {
                    print("[DEBUG] Video saved successfully.")
                } else if let error = error {
                    print("[DEBUG] Error saving video: \(error)")
                }
            }
        }
    }
    
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

// MARK: - CameraControllerDelegate
extension CameraViewController: CameraControllerDelegate {
    func cameraController(_ controller: CameraController, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard isRecording, let manager = recordingManager else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if manager.status == .unknown {
            manager.startSession(timestamp: timestamp)
            print("[DEBUG] Started writer session at \(timestamp.value)/\(timestamp.timescale) seconds")
        }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        // Fetch current angle and scale from MotionStabilizer
        let angle = motionStabilizer.currentRotationAngle
        let scale = motionStabilizer.currentScaleFactor
        
        if let stabilizedBuffer = videoProcessor.stabilizeFrame(ciImage: ciImage,
                                                                width: controller.videoWidth,
                                                                height: controller.videoHeight,
                                                                rotationAngle: angle,
                                                                scaleFactor: scale,
                                                                baselineOrientation: recordingBaselineOrientation) {
            manager.appendVideo(pixelBuffer: stabilizedBuffer, timestamp: timestamp)
        }
    }
    
    func cameraController(_ controller: CameraController, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        recordingManager?.appendAudio(sampleBuffer: sampleBuffer)
    }
    
    private func radiansToDegrees(_ radians: Double) -> Double {
        return radians * 180.0 / Double.pi
    }
}
