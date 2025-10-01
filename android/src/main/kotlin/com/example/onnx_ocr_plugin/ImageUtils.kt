package com.example.onnx_ocr_plugin

import android.graphics.*
import kotlin.math.*

object ImageUtils {

    fun cropTextRegion(bitmap: Bitmap, points: List<PointF>): Bitmap {
        if (points.size != 4) {
            throw IllegalArgumentException("Expected 4 points for text region")
        }

        // Calculate dimensions of the cropped region
        // Use maximum of opposing sides to avoid truncation (matching Python implementation)
        val width = max(
            distance(points[0], points[1]),  // top edge
            distance(points[2], points[3])   // bottom edge
        ).toInt()
        val height = max(
            distance(points[0], points[3]),  // left edge
            distance(points[1], points[2])   // right edge
        ).toInt()

        // Create destination points for perspective transform
        val dstPoints = floatArrayOf(
            0f, 0f,
            width.toFloat(), 0f,
            width.toFloat(), height.toFloat(),
            0f, height.toFloat()
        )

        // Create source points
        val srcPoints = floatArrayOf(
            points[0].x, points[0].y,
            points[1].x, points[1].y,
            points[2].x, points[2].y,
            points[3].x, points[3].y
        )

        // Calculate perspective transform matrix
        val matrix = Matrix()
        matrix.setPolyToPoly(srcPoints, 0, dstPoints, 0, 4)

        // Apply perspective transform
        val croppedBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(croppedBitmap)
        canvas.drawBitmap(bitmap, matrix, Paint(Paint.FILTER_BITMAP_FLAG))

        // Check if the image needs rotation based on aspect ratio
        if (height.toFloat() / width >= 1.5f) {
            // Rotate 90 degrees if height is significantly larger than width
            val rotationMatrix = Matrix().apply {
                postRotate(90f)
            }
            return Bitmap.createBitmap(
                croppedBitmap,
                0,
                0,
                croppedBitmap.width,
                croppedBitmap.height,
                rotationMatrix,
                true
            )
        }

        return croppedBitmap
    }

    fun orderPointsClockwise(points: List<PointF>): List<PointF> {
        if (points.size != 4) {
            return points
        }

        // Calculate center point
        val centerX = points.sumOf { it.x.toDouble() }.toFloat() / 4
        val centerY = points.sumOf { it.y.toDouble() }.toFloat() / 4

        // Sort points by angle from center
        val sortedPoints = points.sortedBy { point ->
            atan2(
                (point.y - centerY).toDouble(),
                (point.x - centerX).toDouble()
            )
        }

        // Find top-left point (minimum sum of x and y)
        var topLeftIndex = 0
        var minSum = sortedPoints[0].x + sortedPoints[0].y
        for (i in 1 until 4) {
            val sum = sortedPoints[i].x + sortedPoints[i].y
            if (sum < minSum) {
                minSum = sum
                topLeftIndex = i
            }
        }

        // Reorder starting from top-left
        val orderedPoints = mutableListOf<PointF>()
        for (i in 0 until 4) {
            orderedPoints.add(sortedPoints[(topLeftIndex + i) % 4])
        }

        return orderedPoints
    }

    fun distance(p1: PointF, p2: PointF): Float {
        val dx = p2.x - p1.x
        val dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }

    fun expandBox(points: List<PointF>, expandRatio: Float = 1.5f): List<PointF> {
        if (points.size != 4) {
            return points
        }

        // Calculate center
        val centerX = points.sumOf { it.x.toDouble() }.toFloat() / 4
        val centerY = points.sumOf { it.y.toDouble() }.toFloat() / 4

        // Expand each point from center
        return points.map { point ->
            val dx = point.x - centerX
            val dy = point.y - centerY
            PointF(
                centerX + dx * expandRatio,
                centerY + dy * expandRatio
            )
        }
    }

    fun clipBoxToImageBounds(
        points: List<PointF>,
        imageWidth: Int,
        imageHeight: Int
    ): List<PointF> {
        return points.map { point ->
            PointF(
                point.x.coerceIn(0f, imageWidth - 1f),
                point.y.coerceIn(0f, imageHeight - 1f)
            )
        }
    }

    fun calculateBoxArea(points: List<PointF>): Float {
        if (points.size != 4) {
            return 0f
        }

        // Shoelace formula for quadrilateral area
        var area = 0f
        for (i in points.indices) {
            val j = (i + 1) % points.size
            area += points[i].x * points[j].y
            area -= points[j].x * points[i].y
        }
        return abs(area) / 2f
    }

    fun isValidBox(points: List<PointF>, minWidth: Float = 3f, minHeight: Float = 3f): Boolean {
        if (points.size != 4) {
            return false
        }

        val width = distance(points[0], points[1])
        val height = distance(points[0], points[3])

        return width >= minWidth && height >= minHeight
    }
}