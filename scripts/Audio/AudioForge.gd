extends Node
##
## AudioForge.gd — 程序化音效合成器
## Autoload 名: AudioForge
##
## 项目不使用任何第三方音频素材(版权考虑), 全部音效在运行时由代码合成 PCM 波形,
## 生成结果缓存复用, 只占用内存不产生磁盘文件。
##
## 合成模型:
##   gunshot = 噪声爆发(带通) + 低频冲击(扫频正弦) + 尾音(混响近似: 多抽头延迟衰减)
##

const SR := 44100

var _cache: Dictionary = {}
var _rng := RandomNumberGenerator.new()

## 合成参数表: [时长, 衰减指数, 带通下限, 带通上限, 低频冲击频率, 冲击强度, 混响长度]
const PROFILES := {
	"pistol_light":  [0.16, 26.0,  900.0,  7000.0, 140.0, 0.55, 0.05],
	"pistol_heavy":  [0.20, 22.0,  700.0,  6200.0, 115.0, 0.70, 0.07],
	"smg_fast":      [0.11, 34.0, 1100.0,  8200.0, 180.0, 0.42, 0.03],
	"smg_mid":       [0.13, 30.0, 1000.0,  7800.0, 165.0, 0.48, 0.04],
	"smg_heavy":     [0.15, 27.0,  900.0,  7200.0, 150.0, 0.55, 0.05],
	"rifle_mid":     [0.24, 20.0,  600.0,  6800.0, 105.0, 0.80, 0.13],
	"rifle_heavy":   [0.28, 18.0,  520.0,  6400.0,  92.0, 0.88, 0.16],
	"sniper_heavy":  [0.48, 13.0,  380.0,  7600.0,  72.0, 1.00, 0.30],
	"sniper_light":  [0.34, 17.0,  520.0,  7200.0,  88.0, 0.85, 0.20],
	"shotgun":       [0.36, 15.0,  320.0,  5600.0,  70.0, 0.95, 0.22],
	"lmg":           [0.26, 19.0,  480.0,  6200.0,  86.0, 0.90, 0.15],
	"knife":         [0.18, 40.0, 1800.0, 11000.0,   0.0, 0.00, 0.02],
	"explosion":     [0.90,  6.0,   90.0,  3200.0,  48.0, 1.00, 0.55],
	"flashbang":     [0.45, 10.0,  600.0, 12000.0, 130.0, 0.75, 0.35],
	"smoke_emit":    [1.20,  4.0,  200.0,  4000.0,   0.0, 0.00, 0.20],
	"fire_burn":     [0.80,  3.0,  150.0,  2600.0,   0.0, 0.00, 0.30],
	"plant":         [0.22, 14.0,  500.0,  5200.0, 120.0, 0.40, 0.10],
	"defuse":        [0.20, 15.0,  600.0,  5400.0, 140.0, 0.35, 0.08],
	"beep":          [0.30,  8.0,  800.0,  3000.0, 900.0, 0.30, 0.05],
	"impact_concrete": [0.10, 30.0,  900.0, 4200.0, 180.0, 0.28, 0.02],
	"impact_metal":    [0.16, 24.0, 1800.0, 9000.0, 420.0, 0.52, 0.05],
	"impact_wood":     [0.12, 28.0, 1200.0, 5600.0, 230.0, 0.32, 0.03],
	"impact_glass":    [0.20, 20.0, 2600.0, 11000.0, 620.0, 0.42, 0.07],
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 20260829
	prewarm()


## 预生成常用音效, 避免首次开枪时卡顿
func prewarm() -> void:
	for k in PROFILES:
		get_sfx(k)
	get_sfx("hitmarker")
	get_sfx("killmarker")
	get_sfx("headshot")
	get_sfx("footstep")
	get_sfx("reload")
	get_sfx("dryfire")
	get_sfx("impact_concrete")
	get_sfx("impact_metal")
	get_sfx("impact_wood")
	get_sfx("impact_glass")


func get_sfx(profile: String) -> AudioStreamWAV:
	if _cache.has(profile):
		return _cache[profile]
	var stream := _build(profile)
	_cache[profile] = stream
	return stream


func _build(profile: String) -> AudioStreamWAV:
	var buf: PackedFloat32Array
	match profile:
		"hitmarker":
			buf = _synth_tone(0.07, 1100.0, 2400.0, 0.55)
		"killmarker":
			buf = _synth_tone(0.10, 900.0, 3000.0, 0.65)
		"headshot":
			buf = _synth_tone(0.12, 1400.0, 3600.0, 0.70)
		"footstep":
			buf = _synth_footstep()
		"reload":
			buf = _synth_reload()
		"dryfire":
			buf = _synth_click(0.05, 2600.0, 0.5)
		_:
			buf = _synth_gunshot(profile)
	return _to_stream(buf)


# ---------------------------------------------------------------- 合成核心
func _synth_gunshot(profile: String) -> PackedFloat32Array:
	var p: Array = PROFILES.get(profile, PROFILES["rifle_mid"])
	var dur: float = p[0]
	var decay: float = p[1]
	var lo: float = p[2]
	var hi: float = p[3]
	var thump_f: float = p[4]
	var thump_amp: float = p[5]
	var rev_len: float = p[6]

	var n := int(dur * SR)
	var body := PackedFloat32Array()
	body.resize(n)

	# 1) 噪声爆发: 白噪声 * 指数衰减包络
	for i in n:
		var t := float(i) / SR
		var env := exp(-decay * t)
		# 起音极短(1ms)避免爆音
		var attack := clampf(t / 0.001, 0.0, 1.0)
		body[i] = _rng.randf_range(-1.0, 1.0) * env * attack

	body = _bandpass(body, lo, hi)

	# 2) 低频冲击: 频率下扫的正弦
	if thump_amp > 0.0:
		var thump_n := int(0.12 * SR)
		var phase := 0.0
		for i in mini(thump_n, n):
			var t := float(i) / SR
			var f: float = thump_f * (1.0 + 2.6 * exp(-40.0 * t))
			phase += TAU * f / SR
			var env: float = exp(-16.0 * t) * thump_amp
			body[i] += sin(phase) * env * 0.85

	# 3) 尾音混响近似: 多抽头延迟
	if rev_len > 0.0:
		body = _apply_taps(body, rev_len)

	return _normalize(body, 0.92)


func _synth_tone(dur: float, f_start: float, f_end: float, amp: float) -> PackedFloat32Array:
	var n := int(dur * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / SR
		var k := t / dur
		var f: float = lerpf(f_start, f_end, k)
		phase += TAU * f / SR
		var env: float = exp(-14.0 * t) * (1.0 - k * 0.2)
		out[i] = sin(phase) * env * amp
	return _normalize(out, 0.7)


func _synth_click(dur: float, freq: float, amp: float) -> PackedFloat32Array:
	var n := int(dur * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SR
		out[i] = _rng.randf_range(-1.0, 1.0) * exp(-55.0 * t) * amp
	out = _bandpass(out, freq * 0.6, freq * 1.8)
	return _normalize(out, 0.5)


func _synth_footstep() -> PackedFloat32Array:
	var dur := 0.11
	var n := int(dur * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SR
		var env: float = exp(-38.0 * t) * clampf(t / 0.002, 0.0, 1.0)
		out[i] = _rng.randf_range(-1.0, 1.0) * env
	out = _bandpass(out, 180.0, 2200.0)
	# 叠加一点低频"闷响"
	var phase := 0.0
	for i in n:
		var t := float(i) / SR
		phase += TAU * 95.0 / SR
		out[i] += sin(phase) * exp(-30.0 * t) * 0.30
	return _normalize(out, 0.42)


func _synth_reload() -> PackedFloat32Array:
	# 三段机械声: 卸弹匣 -> 插弹匣 -> 拉栓
	var seg1 := _synth_click(0.06, 1800.0, 0.55)
	var seg2 := _synth_click(0.07, 2400.0, 0.65)
	var seg3 := _synth_click(0.05, 3200.0, 0.70)
	var total := 0.06 + 0.10 + 0.22 + 0.05
	var n := int(total * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	_mix_at(out, seg1, int(0.0 * SR))
	_mix_at(out, seg2, int(0.16 * SR))
	_mix_at(out, seg3, int(0.34 * SR))
	return _normalize(out, 0.6)


func _mix_at(dst: PackedFloat32Array, src: PackedFloat32Array, offset: int) -> void:
	for i in src.size():
		var idx: int = offset + i
		if idx < dst.size():
			dst[idx] += src[i]


# ---------------------------------------------------------------- DSP 工具
## 一阶高通 + 一阶低通串联 = 带通
func _bandpass(buf: PackedFloat32Array, lo: float, hi: float) -> PackedFloat32Array:
	var n := buf.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var a_lo: float = 1.0 - exp(-TAU * hi / SR)
	var a_hi: float = 1.0 - exp(-TAU * lo / SR)
	var prev_in := 0.0
	var lp := 0.0
	var prev_lp := 0.0
	var hp := 0.0
	for i in n:
		var x: float = buf[i]
		lp += a_lo * (x - lp)
		hp = a_hi * (hp + lp - prev_lp)
		prev_lp = lp
		out[i] = hp
		prev_in = x
	return out


## 多抽头延迟, 模拟空间反射
func _apply_taps(buf: PackedFloat32Array, rev_len: float) -> PackedFloat32Array:
	var n := buf.size()
	var out := buf.duplicate()
	var taps := [
		[0.018, 0.28], [0.031, 0.20], [0.047, 0.14],
		[0.068, 0.10], [0.095, 0.07], [0.130, 0.05],
	]
	for tap in taps:
		var delay_s: float = tap[0] * (rev_len / 0.15)
		var gain: float = tap[1] * clampf(rev_len / 0.15, 0.2, 2.0)
		var d := int(delay_s * SR)
		if d <= 0 or d >= n:
			continue
		var decay := 1.0
		for i in range(d, n):
			out[i] += buf[i - d] * gain * decay
			decay *= 0.9995
	return out


func _normalize(buf: PackedFloat32Array, target: float) -> PackedFloat32Array:
	var peak := 0.0
	for v in buf:
		peak = maxf(peak, absf(v))
	if peak < 0.00001:
		return buf
	var k: float = target / peak
	var out := PackedFloat32Array()
	out.resize(buf.size())
	for i in buf.size():
		out[i] = clampf(buf[i] * k, -1.0, 1.0)
	return out


func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = SR
	s.stereo = false
	s.data = bytes
	return s
