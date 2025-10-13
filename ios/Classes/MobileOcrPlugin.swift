import Flutter
import UIKit
import Vision

public class MobileOcrPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "mobile_ocr", binaryMessenger: registrar.messenger())
        let instance = MobileOcrPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
        case "prepareModels":
            // iOS uses built-in Vision framework, no model download needed
            result([
                "isReady": true,
                "version": "iOS-Vision",
                "modelPath": "system"
            ])
        case "detectText":
            handleTextDetection(call: call, result: result)
        case "hasText":
            handleQuickTextCheck(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleTextDetection(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let imagePath = arguments["imagePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "Image path is required",
                               details: nil))
            return
        }

        let includeAllConfidenceScores = (arguments["includeAllConfidenceScores"] as? Bool) ?? false
        let minConfidence: Float = includeAllConfidenceScores ? 0.5 : 0.8

        detectTextInImage(imagePath: imagePath,
                         minConfidence: minConfidence,
                         result: result)
    }

    private func handleQuickTextCheck(call: FlutterMethodCall,
                                      result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let imagePath = arguments["imagePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "Image path is required",
                               details: nil))
            return
        }

        quickDetectText(imagePath: imagePath,
                        minConfidence: 0.9,
                        result: result)
    }

    private func detectTextInImage(imagePath: String,
                                  minConfidence: Float,
                                  result: @escaping FlutterResult) {
        // Move processing to background queue
        let workItem = DispatchWorkItem {
            guard let image = UIImage(contentsOfFile: imagePath) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to load image from path",
                                       details: nil))
                }
                return
            }

            // Fix image orientation using modern API
            var fixedImage = image
            if image.imageOrientation != .up {
                let renderer = UIGraphicsImageRenderer(size: image.size)
                fixedImage = renderer.image { _ in
                    image.draw(at: .zero)
                }
            }

            guard let cgImage = fixedImage.cgImage else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to get CGImage",
                                       details: nil))
                }
                return
            }

            // Create Vision request
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            var detectedTexts: [[String: Any]] = []

            let request = VNRecognizeTextRequest { (request, error) in
                if let error = error {
                    print("Text recognition error: \(error.localizedDescription)")
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return
                }

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }

                    // Filter by confidence
                    if topCandidate.confidence < minConfidence {
                        continue
                    }

                    // Convert normalized coordinates to image coordinates
                    let imageWidth = CGFloat(cgImage.width)
                    let imageHeight = CGFloat(cgImage.height)

                    // VNRecognizedTextObservation inherits from VNRectangleObservation
                    // Use the actual corner points for accurate polygon representation
                    // Vision uses bottom-left origin, convert to top-left origin
                    let topLeft = CGPoint(
                        x: observation.topLeft.x * imageWidth,
                        y: (1 - observation.topLeft.y) * imageHeight
                    )
                    let topRight = CGPoint(
                        x: observation.topRight.x * imageWidth,
                        y: (1 - observation.topRight.y) * imageHeight
                    )
                    let bottomRight = CGPoint(
                        x: observation.bottomRight.x * imageWidth,
                        y: (1 - observation.bottomRight.y) * imageHeight
                    )
                    let bottomLeft = CGPoint(
                        x: observation.bottomLeft.x * imageWidth,
                        y: (1 - observation.bottomLeft.y) * imageHeight
                    )

                    // Create polygon points array
                    let points: [[String: Double]] = [
                        ["x": Double(topLeft.x), "y": Double(topLeft.y)],
                        ["x": Double(topRight.x), "y": Double(topRight.y)],
                        ["x": Double(bottomRight.x), "y": Double(bottomRight.y)],
                        ["x": Double(bottomLeft.x), "y": Double(bottomLeft.y)]
                    ]

                    // Character-level bounding boxes (iOS 16+ only)
                    let characterEntries: [[String: Any]] = []
                    // TODO: Re-enable when minimum iOS version is 16+
                    // Character boxes require iOS 16+ API that's not available in current build

                    detectedTexts.append([
                        "text": topCandidate.string,
                        "confidence": topCandidate.confidence,
                        "points": points,
                        "characters": characterEntries
                    ])
                }
            }

            // Configure request for best accuracy
            request.recognitionLevel = .accurate
            request.minimumTextHeight = 0.01
            request.usesLanguageCorrection = true

            // Use automatic language detection if available
            if #available(iOS 16.0, *) {
                request.automaticallyDetectsLanguage = true
                request.revision = VNRecognizeTextRequestRevision3
            } else {
                // Default to English for older iOS versions
                request.recognitionLanguages = ["en-US"]
            }

            // Perform the request
            do {
                try requestHandler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "RECOGNITION_ERROR",
                                       message: "Failed to perform text recognition",
                                       details: error.localizedDescription))
                }
                return
            }

            // Helper function to calculate bounding rect
            func boundingRect(for pointMaps: [[String: Double]]) -> CGRect? {
                guard let firstX = pointMaps.first?["x"], let firstY = pointMaps.first?["y"] else {
                    return nil
                }
                var minX = firstX, maxX = firstX, minY = firstY, maxY = firstY
                for point in pointMaps {
                    guard let x = point["x"], let y = point["y"] else { continue }
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
            }

            // Sort results by position (top to bottom, left to right)
            detectedTexts.sort { first, second in
                guard
                    let firstPoints = first["points"] as? [[String: Double]],
                    let secondPoints = second["points"] as? [[String: Double]],
                    let firstRect = boundingRect(for: firstPoints),
                    let secondRect = boundingRect(for: secondPoints)
                else {
                    return false
                }

                // Sort by vertical position, then horizontal
                if abs(firstRect.minY - secondRect.minY) > 10 {
                    return firstRect.minY < secondRect.minY
                }
                return firstRect.minX < secondRect.minX
            }

            // Return results on main thread
            DispatchQueue.main.async {
                result(detectedTexts)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func quickDetectText(imagePath: String,
                                 minConfidence: Float,
                                 result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async(execute: {
            guard let image = UIImage(contentsOfFile: imagePath) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to load image from path",
                                       details: nil))
                }
                return
            }

            var fixedImage = image
            if image.imageOrientation != .up {
                let renderer = UIGraphicsImageRenderer(size: image.size)
                fixedImage = renderer.image { _ in
                    image.draw(at: .zero)
                }
            }

            guard let cgImage = fixedImage.cgImage else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to get CGImage",
                                       details: nil))
                }
                return
            }

            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            var hasHighConfidenceText = false

            let request = VNDetectTextRectanglesRequest { (request, error) in
                if let error = error {
                    print("Text detection error: \(error.localizedDescription)")
                    return
                }

                guard let observations = request.results as? [VNTextObservation] else {
                    return
                }

                hasHighConfidenceText = observations.contains { observation in
                    return observation.confidence >= minConfidence
                }
            }

            request.reportCharacterBoxes = false

            do {
                try requestHandler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DETECTION_ERROR",
                                       message: "Failed to perform text detection",
                                       details: error.localizedDescription))
                }
                return
            }

            DispatchQueue.main.async {
                result(hasHighConfidenceText)
            }
        })
    }

}
