package com.hinter.hinter.camera

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

/**
 * 麦克风采集(唯一持有者):
 * - 48kHz 单声道 int16 供录制端 AAC 编码;
 * - 3:1 降采样到 16kHz int16 推给 Flutter 做本地语音识别。
 */
class AudioEngine(
    private val onPcm16k: (ByteArray) -> Unit,
) {
    companion object {
        private const val RATE_48K = 48000
        private const val RATE_16K = 16000
        private const val FRAME_20MS = 960 // 48k * 20ms
    }

    private var record: AudioRecord? = null
    private var thread: Thread? = null

    @Volatile
    private var running = false

    /** 录制器抽头(48kHz ShortArray),仅在录制时非空 */
    @Volatile
    var audioTap: ((ShortArray, Int) -> Unit)? = null

    @SuppressLint("MissingPermission")
    fun start() {
        if (running) return
        val minBuf = AudioRecord.getMinBufferSize(
            RATE_48K, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val r = AudioRecord(
            MediaRecorder.AudioSource.MIC, RATE_48K,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf, RATE_48K * 2) // ≥1s 缓冲
        )
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            throw IllegalStateException("麦克风初始化失败(检查权限)")
        }
        record = r
        running = true
        r.startRecording()
        thread = Thread({ loop() }, "hinter-audio").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun loop() {
        val r = record ?: return
        val buf = ShortArray(FRAME_20MS)
        val out = ByteArray(FRAME_20MS / 3 * 2)
        while (running) {
            try {
                val n = r.read(buf, 0, buf.size)
                if (n <= 0) continue
                audioTap?.invoke(buf, n)
                // 3:1 均值降采样 48k → 16k
                var o = 0
                var i = 0
                while (i + 2 < n) {
                    val v = ((buf[i].toInt() + buf[i + 1] + buf[i + 2]) / 3).toShort()
                    out[o] = (v.toInt() and 0xFF).toByte()
                    out[o + 1] = ((v.toInt() shr 8) and 0xFF).toByte()
                    o += 2
                    i += 3
                }
                if (o > 0) onPcm16k(out.copyOf(o))
            } catch (_: Exception) {
                // 单帧失败不终止采集线程
            }
        }
    }

    fun stop() {
        running = false
        try { thread?.join(500) } catch (_: InterruptedException) {}
        thread = null
        try { record?.stop() } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        record = null
    }
}
