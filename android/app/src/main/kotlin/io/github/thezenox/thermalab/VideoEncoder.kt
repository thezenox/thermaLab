package io.github.thezenox.thermalab

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * Encodes RGBA frames handed over from Flutter into an H.264 MP4 file.
 *
 * Frames are drawn onto the encoder's input surface; a background thread
 * drains the encoder into the muxer. Timestamps come from the frame calls,
 * so a variable frame rate is recorded as it happened.
 */
class VideoEncoder(
    private val path: String,
    private val width: Int,
    private val height: Int,
    fps: Int,
) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val surface: Surface
    private val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private var track = -1
    private var muxerStarted = false
    private val drainThread: Thread
    @Volatile private var finished = false

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, width * height * 6)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
        drainThread = Thread({ drain() }, "t2s-video-drain").apply { start() }
    }

    /** Draws one RGBA frame (width * height * 4 bytes). */
    fun addFrame(rgba: ByteArray) {
        if (finished) return
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
        val canvas = surface.lockHardwareCanvas()
        try {
            canvas.drawBitmap(bitmap, 0f, 0f, null)
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
    }

    /** Finishes the file. Blocks until the encoder has flushed. */
    fun finish(): String {
        if (!finished) {
            codec.signalEndOfInputStream()
            drainThread.join(5000)
            finished = true
            try { codec.stop() } catch (e: Exception) { Log.w(TAG, "codec stop", e) }
            codec.release()
            surface.release()
            if (muxerStarted) {
                try { muxer.stop() } catch (e: Exception) { Log.w(TAG, "muxer stop", e) }
            }
            muxer.release()
            bitmap.recycle()
        }
        return path
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = try {
                codec.dequeueOutputBuffer(info, 10_000)
            } catch (e: IllegalStateException) {
                return
            }
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        info.size = 0
                    }
                    if (info.size > 0 && muxerStarted && buffer != null) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    companion object {
        private const val TAG = "T2sVideoEncoder"
    }
}
