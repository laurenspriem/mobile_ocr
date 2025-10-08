import Flutter
import UIKit
import Vision
import CoreImage

public class OnnxMobileOcrPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "onnx_mobile_ocr", binaryMessenger: registrar.messenger())
        let instance = OnnxMobileOcrPlugin()
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

    private func detectTextInImage(imagePath: String,
                                  minConfidence: Float,
                                  result: @escaping FlutterResult) {
        // Move processing to background queue
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = UIImage(contentsOfFile: imagePath) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to load image from path",
                                       details: nil))
                }
                return
            }

            // Fix image orientation
            let fixedImage = self.fixImageOrientation(image)

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

                    // Calculate bounding box for compatibility
                    let minX = min(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x)
                    let maxX = max(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x)
                    let minY = min(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y)
                    let maxY = max(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y)

                    detectedTexts.append([
                        "text": topCandidate.string,
                        "confidence": topCandidate.confidence,
                        "x": minX,
                        "y": minY,
                        "width": maxX - minX,
                        "height": maxY - minY,
                        "points": points
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

            // Sort results by position (top to bottom, left to right)
            detectedTexts.sort { first, second in
                let y1 = first["y"] as? CGFloat ?? 0
                let y2 = second["y"] as? CGFloat ?? 0
                let x1 = first["x"] as? CGFloat ?? 0
                let x2 = second["x"] as? CGFloat ?? 0

                // Sort by vertical position, then horizontal
                if abs(y1 - y2) > 10 {
                    return y1 < y2
                }
                return x1 < x2
            }

            // Return results on main thread
            DispatchQueue.main.async {
                result(detectedTexts)
            }
        }
    }

    private func fixImageOrientation(_ image: UIImage) -> UIImage {
        // If image orientation is already correct, return as is
        if image.imageOrientation == .up {
            return image
        }

        // Redraw the image with correct orientation
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        return normalizedImage
    }
}