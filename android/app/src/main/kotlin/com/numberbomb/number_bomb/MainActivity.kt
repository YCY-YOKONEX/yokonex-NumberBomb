package com.numberbomb.number_bomb

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "number_bomb/feedback"
    private var tone: ToneGenerator? = null
    private var vibrator: Vibrator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    playTone(call.arguments as? String ?: "tick")
                    result.success(null)
                }
                "vibrate" -> {
                    vibrate(call.arguments as? String ?: "explosion")
                    result.success(null)
                }
                "stop" -> {
                    tone?.release()
                    tone = null
                    vibrator?.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playTone(name: String) {
        tone?.release()
        tone = ToneGenerator(AudioManager.STREAM_MUSIC, 85)
        val toneType = when (name) {
            "lock" -> ToneGenerator.TONE_PROP_ACK
            "error" -> ToneGenerator.TONE_PROP_NACK
            "heartbeat" -> ToneGenerator.TONE_PROP_BEEP2
            "explosion" -> ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD
            else -> ToneGenerator.TONE_PROP_BEEP
        }
        tone?.startTone(toneType, if (name == "explosion") 420 else 110)
    }

    private fun vibrate(pattern: String) {
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                .let { it as VibratorManager }
                .defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        val deviceVibrator = vibrator ?: return
        if (!deviceVibrator.hasVibrator()) return
        val timings = when (pattern) {
            "dangerLow" -> longArrayOf(0, 35, 45, 35)
            "dangerHigh" -> longArrayOf(0, 55, 35, 55, 35, 75)
            "explosion" -> longArrayOf(0, 150, 70, 280, 90, 120)
            else -> longArrayOf(0, 35)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            deviceVibrator.vibrate(VibrationEffect.createWaveform(timings, -1))
        } else {
            @Suppress("DEPRECATION") deviceVibrator.vibrate(timings, -1)
        }
    }

    override fun onDestroy() {
        tone?.release()
        tone = null
        vibrator?.cancel()
        super.onDestroy()
    }
}
