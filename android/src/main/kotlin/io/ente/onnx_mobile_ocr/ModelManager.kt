package io.ente.onnx_mobile_ocr

import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

private data class ModelAsset(
    val fileName: String,
    val sha256: String,
    val sizeBytes: Long
)

data class ModelFiles(
    val version: String,
    val baseDir: File,
    val detectionModel: File,
    val recognitionModel: File,
    val classificationModel: File,
    val dictionaryFile: File
)

class ModelManager(private val context: Context) {

    companion object {
        private const val BASE_URL = "https://models.ente.io/PP-OCRv5/"
        private const val MODEL_VERSION = "pp-ocrv5-202410"
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 60_000
        private const val BUFFER_SIZE = 8 * 1024
        private const val VERSION_FILE_NAME = ".model_version"

        private val REQUIRED_ASSETS = listOf(
            ModelAsset("det.onnx", "d7fe3ea74652890722c0f4d02458b7261d9f5ae6c92904d05707c9eb155c7924", 4_748_769),
            ModelAsset("rec.onnx", "bf66820f48fa99f779974c4df78e5274a9d8e0458c4137e8c5357e40e2c3faf2", 16_517_247),
            ModelAsset("cls.onnx", "f4bb53707100c5f3d59ba834eb05bb400369f20aed35d4b26807b1bfadd2a70e", 582_663),
            ModelAsset("ppocrv5_dict.txt", "d1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b", 74_012)
        )
    }

    private val cacheDirectory: File by lazy {
        File(context.filesDir, "onnx_ocr/PP-OCRv5")
    }

    private val modelMutex = Mutex()

    suspend fun ensureModels(): ModelFiles {
        return modelMutex.withLock {
            prepareDirectory()
            val needsRefresh = shouldRefreshAssets()

            val resolvedFiles = REQUIRED_ASSETS.associateWith { asset ->
                val target = File(cacheDirectory, asset.fileName)
                val valid =
                    !needsRefresh && target.exists() && target.length() == asset.sizeBytes && verifySha256(
                        target,
                        asset.sha256
                    )

                if (valid) {
                    target
                } else {
                    downloadAsset(asset, target)
                }
            }

            writeVersionMarker()

            ModelFiles(
                version = MODEL_VERSION,
                baseDir = cacheDirectory,
                detectionModel = resolvedFiles.getValue(REQUIRED_ASSETS[0]),
                recognitionModel = resolvedFiles.getValue(REQUIRED_ASSETS[1]),
                classificationModel = resolvedFiles.getValue(REQUIRED_ASSETS[2]),
                dictionaryFile = resolvedFiles.getValue(REQUIRED_ASSETS[3])
            )
        }
    }

    private fun prepareDirectory() {
        if (!cacheDirectory.exists()) {
            cacheDirectory.mkdirs()
        }
    }

    private fun shouldRefreshAssets(): Boolean {
        val versionFile = File(cacheDirectory, VERSION_FILE_NAME)
        if (!versionFile.exists()) {
            return true
        }

        val storedVersion = runCatching { versionFile.readText().trim() }.getOrNull()
        return storedVersion != MODEL_VERSION
    }

    private fun downloadAsset(asset: ModelAsset, target: File): File {
        val tempFile = File.createTempFile(asset.fileName, ".download", cacheDirectory)
        var connection: HttpURLConnection? = null
        try {
            connection = URL("$BASE_URL${asset.fileName}").openConnection() as HttpURLConnection
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = true

            val responseCode = connection.responseCode
            if (responseCode != HttpURLConnection.HTTP_OK) {
                connection.disconnect()
                throw IOException("Failed to download ${asset.fileName}: HTTP $responseCode")
            }

            connection.inputStream.use { input ->
                FileOutputStream(tempFile).use { output ->
                    copyStream(input, output)
                }
            }

            if (tempFile.length() != asset.sizeBytes) {
                throw IOException(
                    "Size mismatch for ${asset.fileName}: expected ${asset.sizeBytes}, got ${tempFile.length()}"
                )
            }

            val actualSha = computeSha256(tempFile)
            if (!actualSha.equals(asset.sha256, ignoreCase = true)) {
                throw IOException("Checksum mismatch for ${asset.fileName}: expected ${asset.sha256}, got $actualSha")
            }

            if (target.exists()) {
                target.delete()
            }
            if (!tempFile.renameTo(target)) {
                throw IOException("Failed to move ${asset.fileName} into cache directory")
            }

            return target
        } finally {
            connection?.disconnect()
            if (tempFile.exists()) {
                tempFile.delete()
            }
        }
    }

    private fun verifySha256(target: File, expectedSha: String): Boolean {
        val actual = computeSha256(target)
        return actual.equals(expectedSha, ignoreCase = true)
    }

    private fun computeSha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(BUFFER_SIZE)
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun copyStream(input: InputStream, output: FileOutputStream) {
        val buffer = ByteArray(BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            output.write(buffer, 0, read)
        }
        output.flush()
    }

    private fun writeVersionMarker() {
        val versionFile = File(cacheDirectory, VERSION_FILE_NAME)
        versionFile.writeText(MODEL_VERSION)
    }
}
