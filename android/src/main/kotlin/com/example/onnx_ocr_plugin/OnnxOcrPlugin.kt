package com.example.onnx_ocr_plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*

/** OnnxOcrPlugin */
class OnnxOcrPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private var ocrProcessor: OcrProcessor? = null
  private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "onnx_ocr_plugin")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext

    // Initialize OCR processor asynchronously
    mainScope.launch {
      withContext(Dispatchers.IO) {
        try {
          ocrProcessor = OcrProcessor(context)
        } catch (e: Exception) {
          e.printStackTrace()
        }
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "detectText" -> {
        val imageData = call.argument<ByteArray>("imageData")
        if (imageData == null) {
          result.error("INVALID_ARGUMENT", "Image data is required", null)
          return
        }

        val includeAllConfidenceScores = call.argument<Boolean>("includeAllConfidenceScores") ?: false

        mainScope.launch {
          try {
            val ocrResult = withContext(Dispatchers.IO) {
              processImage(imageData, includeAllConfidenceScores)
            }
            result.success(ocrResult)
          } catch (e: Exception) {
            result.error("OCR_ERROR", "Failed to process image: ${e.message}", null)
          }
        }
      }
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private suspend fun processImage(imageData: ByteArray, includeAllConfidenceScores: Boolean = false): Map<String, Any> {
    val processor = ocrProcessor ?: throw IllegalStateException("OCR processor not initialized")

    // Decode image
    val bitmap = BitmapFactory.decodeByteArray(imageData, 0, imageData.size)
        ?: throw IllegalArgumentException("Failed to decode image")

    // Process with OCR
    val ocrResults = processor.processImage(bitmap, includeAllConfidenceScores)

    // Convert results to Flutter-compatible format
    val results = mutableMapOf<String, Any>()
    results["boxes"] = ocrResults.boxes.map { box ->
      mapOf(
        "points" to box.points.map { point ->
          mapOf("x" to point.x, "y" to point.y)
        }
      )
    }
    results["texts"] = ocrResults.texts
    results["scores"] = ocrResults.scores

    return results
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    mainScope.cancel()
    ocrProcessor?.close()
  }
}
