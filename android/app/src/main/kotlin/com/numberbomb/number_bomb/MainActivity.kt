package com.numberbomb.number_bomb

import android.media.AudioManager
import android.media.AudioAttributes
import android.media.SoundPool
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
    private var arcadeSounds: SoundPool? = null
    private val arcadeSoundIds = mutableMapOf<String, Int>()
    private var vibrator: Vibrator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        arcadeSounds?.release()
        val pool = SoundPool.Builder()
            .setMaxStreams(2)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .build()
        arcadeSounds = pool
        arcadeSoundIds.clear()
        arcadeSoundIds["arcadeWarning"] = pool.load(this, R.raw.arcade_warning, 1)
        arcadeSoundIds["arcadeMiss"] = pool.load(this, R.raw.arcade_miss, 1)
        arcadeSoundIds["arcadeExplosion"] = pool.load(this, R.raw.arcade_explosion, 1)
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
                    arcadeSounds?.autoPause()
                    vibrator?.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playTone(name: String) {
        tone?.release()
        tone = null
        // 预加载音效未就绪时退回系统提示音，保证反馈不会丢失。
        val soundId = arcadeSoundIds[name]
        val streamId = if (soundId == null) 0 else arcadeSounds?.play(soundId, 1f, 1f, 1, 0, 1f) ?: 0
        if (streamId != 0) return
        val arcade = name.startsWith("arcade")
        tone = ToneGenerator(AudioManager.STREAM_MUSIC, if (arcade) 100 else 85)
        val toneType = when (name) {
            "lock" -> ToneGenerator.TONE_PROP_ACK
            "error" -> ToneGenerator.TONE_PROP_NACK
            "heartbeat" -> ToneGenerator.TONE_PROP_BEEP2
            "explosion" -> ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD
            "arcadeWarning" -> ToneGenerator.TONE_PROP_BEEP2
            "arcadeMiss" -> ToneGenerator.TONE_PROP_NACK
            "arcadeExplosion" -> ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD
            else -> ToneGenerator.TONE_PROP_BEEP
        }
        val duration = when (name) {
            "arcadeExplosion" -> 650
            "explosion" -> 420
            "arcadeMiss" -> 220
            "arcadeWarning" -> 170
            else -> 110
        }
        tone?.startTone(toneType, duration)
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
            // 街机反馈总时长低于结果页切换时间，避免中途被 stop 截断。
            "arcadeWarning" -> longArrayOf(0, 55, 45, 65)
            "arcadeMiss" -> longArrayOf(0, 80, 35, 105)
            "arcadeExplosion" -> longArrayOf(0, 170, 35, 220, 35, 190)
            else -> longArrayOf(0, 35)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val amplitudes = when (pattern) {
                "arcadeWarning" -> intArrayOf(0, 150, 0, 220)
                "arcadeMiss" -> intArrayOf(0, 200, 0, 255)
                "arcadeExplosion" -> intArrayOf(0, 220, 0, 255, 0, 255)
                else -> null
            }
            deviceVibrator.vibrate(
                if (amplitudes == null) VibrationEffect.createWaveform(timings, -1)
                else VibrationEffect.createWaveform(timings, amplitudes, -1)
            )
        } else {
            @Suppress("DEPRECATION") deviceVibrator.vibrate(timings, -1)
        }
    }

    override fun onDestroy() {
        tone?.release()
        tone = null
        arcadeSounds?.release()
        arcadeSounds = null
        vibrator?.cancel()
        super.onDestroy()
    }
}
