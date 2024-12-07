import UIKit
import AVFoundation
import Photos
import CoreMotion

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

// MARK: - MotionStabilizer
class MotionStabilizer {
    private let motionManager = CMMotionManager()
    var currentRotationAngle: Double = 0.0
    var currentScaleFactor: Double = 1.0
    
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    
    func startUpdates(videoWidth: Int, videoHeight: Int) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        // The updates continuously run and adjust angle & scale factor
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else { return }
            self.updateAngleAndScale(motion: motion)
        }
    }
    
    private func updateAngleAndScale(motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let x = gravity.x
        let y = gravity.y
        
        // Compute rotation angle
        var tiltAngle = atan2(y, x) - .pi / 2
        tiltAngle += .pi  // 180-degree correction
        tiltAngle = -tiltAngle
        
        // Normalize angle
        if tiltAngle > .pi {
            tiltAngle -= 2 * .pi
        } else if tiltAngle < -.pi {
            tiltAngle += 2 * .pi
        }
        
        currentRotationAngle = tiltAngle
        
        // Compute scale factor each time angle updates
        let angle = tiltAngle
        let cosTheta = abs(cos(angle))
        let sinTheta = abs(sin(angle))
        
        let rotatedWidth = CGFloat(videoWidth) * cosTheta + CGFloat(videoHeight) * sinTheta
        let rotatedHeight = CGFloat(videoWidth) * sinTheta + CGFloat(videoHeight) * cosTheta
        
        let scaleX = rotatedWidth / CGFloat(videoWidth)
        let scaleY = rotatedHeight / CGFloat(videoHeight)
        currentScaleFactor = Double(max(scaleX, scaleY))
    }
    
    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - VideoProcessor
class VideoProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    func stabilizeFrame(ciImage: CIImage,
                        width: Int,
                        height: Int,
                        rotationAngle: Double,
                        scaleFactor: Double) -> CVPixelBuffer? {
        
        let transform = buildTransform(width: width, height: height, angle: rotationAngle, scale: scaleFactor)
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
    
    private func buildTransform(width: Int, height: Int, angle: Double, scale: Double) -> CGAffineTransform {
        let centerTransform = CGAffineTransform(translationX: -CGFloat(width)/2, y: -CGFloat(height)/2)
        let rotationTransform = CGAffineTransform(rotationAngle: CGFloat(angle))
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
        vInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        
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
        
        // Call startSession on a background queue
        DispatchQueue.global(qos: .userInitiated).async {
            self.cameraController.startSession()
            
            DispatchQueue.main.async {
                let previewLayer = self.cameraController.makePreviewLayer()
                previewLayer.frame = self.view.bounds
                self.view.layer.insertSublayer(previewLayer, at: 0)
                
                self.motionStabilizer.startUpdates(videoWidth: self.cameraController.videoWidth,
                                                   videoHeight: self.cameraController.videoHeight)
                
                self.stopButton.isEnabled = false
            }
        }
    }
    
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        startRecording()
    }
    
    @IBAction func stopButtonTapped(_ sender: UIButton) {
        stopRecording()
    }
    
    private func startRecording() {
        guard !isRecording else { return }
        
        let width = cameraController.videoWidth
        let height = cameraController.videoHeight
        
        let manager = RecordingManager(videoWidth: width, videoHeight: height)
        do {
            try manager.startRecording()
            recordingManager = manager
            isRecording = true
            recordButton.isEnabled = false
            stopButton.isEnabled = true
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
            } else {
                print("Error finishing writing: \(String(describing: error))")
            }
            self.recordingManager = nil
        }
    }
    
    private func saveVideoToPhotoLibrary(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { saved, error in
            DispatchQueue.main.async {
                if saved {
                    print("Video saved successfully.")
                } else if let error = error {
                    print("Error saving video: \(error)")
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
        }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        
        // Fetch current angle and scale from MotionStabilizer
        let angle = motionStabilizer.currentRotationAngle
        let scale = motionStabilizer.currentScaleFactor
        
        // Apply stabilization transformations, including dynamic scale
        if let stabilizedBuffer = videoProcessor.stabilizeFrame(ciImage: ciImage,
                                                                width: controller.videoWidth,
                                                                height: controller.videoHeight,
                                                                rotationAngle: angle,
                                                                scaleFactor: scale) {
            manager.appendVideo(pixelBuffer: stabilizedBuffer, timestamp: timestamp)
        }
    }
    
    func cameraController(_ controller: CameraController, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        recordingManager?.appendAudio(sampleBuffer: sampleBuffer)
    }
}
