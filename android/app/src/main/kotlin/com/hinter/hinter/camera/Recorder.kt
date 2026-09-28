package com.hinter.hinter.camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * MP4 录制器。
 *
 * 线程模型(关键:MediaCodec 非线程安全,每个编码器只由一个线程访问):
 * - 视频编码器:GL 线程通过输入 Surface 送帧(_Surface 是线程安全的_),
 *   drainVideo 线程独占 dequeueOutputBuffer 与 signalEndOfInputStream;
 * - 音频编码器:AudioEngine 通过 [feedAudio] 把 PCM 投进队列,
 *   drainAudio 线程独占地完成输入排队与输出收集;
 * - 停止:只置位标志,由两个 drain 线程各自发出 EOS 并自行退出。
 */
class Recorder(
    private val width: Int,
    private val height: Int,
    private val bitRate: Int = 10_000_000,
) {

    companion object {
        private const val TAG = "HinterRecorder"
        private const val AUDIO_QUEUE_LIMIT = 120 // ≈2.4s 音频,防内存膨胀
    }

    private var muxer: MediaMuxer? = null
    private var videoCodec: MediaCodec? = null
    private var audioCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var videoTrack = -1
    private var audioTrack = -1
    private var path = ""

    private val lock = Object()

    @Volatile private var muxerStarted = false

    @Volatile private var stopping = false
    @Volatile private var videoEos = false
    @Volatile private var audioEos = false
    @Volatile private var videoEosRequested = false
    @Volatile private var audioEosRequested = false

    private val audioQueue = ConcurrentLinkedQueue<ShortArray>()
    private var audioPtsUs = 0L

    /** 视频流 PTS 基准:相机帧时间是系统启动以来的绝对纳秒,
     *  合流必须从 0 开始,否则 muxer 时长会变成几小时 */
    private var videoBasePtsUs = -1L

    val lastError = AtomicReference<String?>(null)

    val recordSurface: Surface get() = inputSurface!!

    fun start(path: String) {
        this.path = path
        muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            val vFmt = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val vc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            vc.configure(vFmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = vc.createInputSurface()
            vc.start()
            videoCodec = vc

            val aFmt = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC, 48000, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65536)
            }
            val ac = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            ac.configure(aFmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            ac.start()
            audioCodec = ac
        } catch (e: Exception) {
            releaseAll()
            throw e
        }
        Thread({ runGuarded("video") { drainVideo() } }, "hinter-rec-video").start()
        Thread({ runGuarded("audio") { drainAudio() } }, "hinter-rec-audio").start()
    }

    /** AudioEngine 抽头:48kHz 单声道 PCM,仅入队,不碰编码器 */
    fun feedAudio(shorts: ShortArray, n: Int) {
        if (stopping || n <= 0 || audioEosRequested) return
        if (audioQueue.size < AUDIO_QUEUE_LIMIT) {
            audioQueue.offer(shorts.copyOf(n))
        }
    }

    /** 结束录制并合流,返回文件路径(无有效帧时删除文件返回空串) */
    fun stop(): String {
        stopping = true
        val deadline = System.currentTimeMillis() + 5000
        while (System.currentTimeMillis() < deadline && !(videoEos && audioEos)) {
            try {
                Thread.sleep(20)
            } catch (_: InterruptedException) {
                break
            }
        }
        return finish()
    }

    // ---- 内部 ----

    private fun runGuarded(tag: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Throwable) {
            Log.e(TAG, "drain-$tag crashed", e)
            lastError.compareAndSet(null, "drain-$tag: ${e.message}")
            // 线程退出前把 EOS 置位,避免 stop() 空等
            if (tag == "video") videoEos = true else audioEos = true
        }
    }

    private fun drainVideo() {
        val vc = videoCodec ?: return
        val info = MediaCodec.BufferInfo()
        var idle = 0
        while (true) {
            if (stopping && !videoEosRequested && !videoEos) {
                try {
                    vc.signalEndOfInputStream()
                } catch (_: Exception) {}
                videoEosRequested = true
            }
            val idx = vc.dequeueOutputBuffer(info, 10_000)
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (videoEos) break
                    if (videoEosRequested && ++idle > 500) break
                    try { Thread.sleep(10) } catch (_: InterruptedException) { break }
                }
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(lock) {
                        val m = muxer ?: return
                        videoTrack = m.addTrack(vc.outputFormat)
                        tryStartMuxer()
                    }
                }
                idx >= 0 -> {
                    val ob = vc.getOutputBuffer(idx)
                    val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (ob != null && info.size > 0) {
                        if (videoBasePtsUs < 0) videoBasePtsUs = info.presentationTimeUs
                        info.presentationTimeUs -= videoBasePtsUs
                        synchronized(lock) {
                            val m = muxer ?: return
                            if (muxerStarted) {
                                ob.position(info.offset)
                                ob.limit(info.offset + info.size)
                                m.writeSampleData(videoTrack, ob, info)
                            }
                        }
                    }
                    try { vc.releaseOutputBuffer(idx, false) } catch (_: Exception) {}
                    if (eos) {
                        videoEos = true
                        break
                    }
                }
            }
        }
    }

    private fun drainAudio() {
        val ac = audioCodec ?: return
        val info = MediaCodec.BufferInfo()
        var idle = 0
        while (true) {
            // 输入:由本线程独占排队
            if (stopping && audioQueue.isEmpty() && !audioEosRequested && !audioEos) {
                try {
                    val idx = ac.dequeueInputBuffer(10_000)
                    if (idx >= 0) {
                        ac.queueInputBuffer(idx, 0, 0, audioPtsUs,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        audioEosRequested = true
                    }
                } catch (_: Exception) {
                    audioEosRequested = true
                }
            }
            if (!audioEosRequested) {
                val chunk = audioQueue.poll()
                if (chunk != null) {
                    try {
                        val idx = ac.dequeueInputBuffer(10_000)
                        if (idx >= 0) {
                            val buf = ac.getInputBuffer(idx)
                            if (buf != null) {
                                buf.clear()
                                buf.order(ByteOrder.LITTLE_ENDIAN)
                                    .asShortBuffer().put(chunk)
                                val pts = audioPtsUs
                                audioPtsUs += chunk.size * 1_000_000L / 48000L
                                ac.queueInputBuffer(idx, 0, chunk.size * 2, pts, 0)
                            }
                        } else {
                            audioQueue.offer(chunk) // 编码器忙,稍后再投
                        }
                    } catch (_: Exception) {
                    }
                }
            }

            // 输出:收集并写 muxer
            val idx = ac.dequeueOutputBuffer(info, 10_000)
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (audioEos) break
                    if (audioEosRequested && ++idle > 500) break
                    try { Thread.sleep(10) } catch (_: InterruptedException) { break }
                }
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(lock) {
                        val m = muxer ?: return
                        audioTrack = m.addTrack(ac.outputFormat)
                        tryStartMuxer()
                    }
                }
                idx >= 0 -> {
                    val ob = ac.getOutputBuffer(idx)
                    val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (ob != null && info.size > 0) {
                        synchronized(lock) {
                            val m = muxer ?: return
                            if (muxerStarted) {
                                ob.position(info.offset)
                                ob.limit(info.offset + info.size)
                                m.writeSampleData(audioTrack, ob, info)
                            }
                        }
                    }
                    try { ac.releaseOutputBuffer(idx, false) } catch (_: Exception) {}
                    if (eos) {
                        audioEos = true
                        break
                    }
                }
            }
        }
    }

    private fun tryStartMuxer() {
        if (!muxerStarted && videoTrack >= 0 && audioTrack >= 0) {
            try {
                muxer?.start()
                muxerStarted = true
            } catch (e: Exception) {
                Log.e(TAG, "muxer start failed", e)
                lastError.compareAndSet(null, "muxer: ${e.message}")
            }
        }
    }

    private fun finish(): String {
        try { videoCodec?.stop() } catch (_: Exception) {}
        try { videoCodec?.release() } catch (_: Exception) {}
        try { audioCodec?.stop() } catch (_: Exception) {}
        try { audioCodec?.release() } catch (_: Exception) {}
        videoCodec = null
        audioCodec = null
        try { inputSurface?.release() } catch (_: Exception) {}
        inputSurface = null
        val m = muxer
        muxer = null
        if (m != null) {
            try {
                if (muxerStarted) {
                    m.stop()
                    return path
                }
                // 一帧有效数据都没有:删掉空文件
                try { File(path).delete() } catch (_: Exception) {}
            } catch (e: Exception) {
                // 合流失败不能假装成功:让调用方(saveToGallery)拿到错误
                lastError.compareAndSet(null, "muxer.stop: ${e.message}")
                throw e
            } finally {
                try { m.release() } catch (_: Exception) {}
            }
        }
        return ""
    }

    private fun releaseAll() {
        try { videoCodec?.stop() } catch (_: Exception) {}
        try { videoCodec?.release() } catch (_: Exception) {}
        try { audioCodec?.stop() } catch (_: Exception) {}
        try { audioCodec?.release() } catch (_: Exception) {}
        videoCodec = null
        audioCodec = null
        try { inputSurface?.release() } catch (_: Exception) {}
        inputSurface = null
        try { muxer?.release() } catch (_: Exception) {}
        muxer = null
    }
}
