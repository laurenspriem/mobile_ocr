package io.ente.onnx_mobile_ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** OnnxMobileOcrPlugin */
class OnnxMobileOcrPlugin: FlutterPlugin, MethodCallHandler {
  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private var ocrProcessor: OcrProcessor? = null
  private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
  private lateinit var modelManager: ModelManager
  private var cachedModelFiles: ModelFiles? = null
  private val modelMutex = Mutex()
  private val processorMutex = Mutex()

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "onnx_mobile_ocr")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
    modelManager = ModelManager(context)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "prepareModels" -> {
        mainScope.launch {
          try {
            val modelFiles = withContext(Dispatchers.IO) { getModelFiles() }
            withContext(Dispatchers.IO) {
              processorMutex.withLock {
                if (ocrProcessor == null) {
                  ocrProcessor = OcrProcessor(context, modelFiles)
                }
              }
            }
            result.success(
              mapOf(
                "isReady" to true,
                "version" to modelFiles.version,
                "modelPath" to modelFiles.baseDir.absolutePath
              )
            )
          } catch (e: Exception) {
            result.error("MODEL_PREP_ERROR", "Failed to prepare models: ${e.message}", null)
          }
        }
      }
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
    val processor = getOrCreateProcessor()

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
    runBlocking {
      processorMutex.withLock {
        ocrProcessor?.close()
        ocrProcessor = null
      }
      modelMutex.withLock {
        cachedModelFiles = null
      }
    }
  }

  private suspend fun getModelFiles(): ModelFiles {
    return modelMutex.withLock {
      cachedModelFiles?.let { return@withLock it }
      val files = modelManager.ensureModels()
      cachedModelFiles = files
      files
    }
  }

  private suspend fun getOrCreateProcessor(): OcrProcessor {
    val modelFiles = getModelFiles()
    return processorMutex.withLock {
      ocrProcessor ?: OcrProcessor(context, modelFiles).also { created ->
        ocrProcessor = created
      }
    }
  }
}
