package io.github.vzsoares.moranduba

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Scales the captured microphone before it is encoded. */
object MicGain : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    @Volatile
    private var gain = 1f
    private var attached = false

    /** False until flutter_webrtc has built its factory (first getUserMedia). */
    fun set(value: Double): Boolean {
        gain = value.toFloat()
        if (attached) return true
        val controller = FlutterWebRTCPlugin.sharedSingleton
            ?.audioProcessingController ?: return false
        controller.capturePostProcessing.addProcessor(this)
        attached = true
        return true
    }

    override fun initialize(sampleRateHz: Int, numChannels: Int) {}

    override fun reset(newRate: Int) {}

    // Samples are floats in the int16 range.
    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        val g = gain
        if (g == 1f) return
        val samples = buffer.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (i in 0 until samples.limit()) {
            samples.put(i, (samples.get(i) * g).coerceIn(-32768f, 32767f))
        }
    }
}
