extends CanvasLayer
class_name PostFX
##
## PostFX.gd — 全屏后处理叠加层
##
## 引擎自带的 Environment 覆盖不到这几项(或代价过高), 这里用一个全屏
## CanvasItem 着色器补齐:
##   · 边缘保护锐化(CAS 思路) —— 直接提升"看得清", 全档位保留
##   · 色彩分级(lift/gamma/gain + 饱和 + 对比) —— 统一画面影调
##   · 暗角             —— 收拢视线, 增加画面厚度
##   · 色散             —— 边缘轻微 RGB 分离, 模拟镜头; 高档位才有, 量很小
##   · 胶片颗粒         —— 压掉色带与"塑料感"; 按亮度加权, 高光区抑制
##   · 有序抖动         —— 进一步压夜图暗部的色带(与 use_debanding 互补)
##
## 层级放在 layer = -1: 画在 3D 之上、HUD 之下 —— 准星/血条/文字不受影响,
## 保持竞技可读性。色彩分级因此也只作用于游戏世界, 不会污染 UI 配色。
##
## ── A1 画面重做(2026-09)修掉的两个真实缺陷 ──────────────────────────
##  1. **原来的锐化会产生白色描边(halo)**。旧实现是裸的四邻域 unsharp:
##     col += (col - blur) * u_sharpen, 在高对比边缘(白色墙沿、箱子棱线、
##     准星附近的高光)会过冲, 表现为"物体边上有一圈发光的白线" —— 这是
##     典型的"越锐化越廉价"。现在还加入射亮度钳制: 邻域亮度跨度决定允许的
##     最大过冲量, 超过就等比压低, 于是平面区域照常变清晰、边缘不再发光。
##  2. **颗粒噪声与分辨率绑死**。旧实现把 UV 乘以硬编码的 vec2(1920,1080),
##     在 1600x900 或窗口化分辨率下颗粒会被拉伸/采样错位, 看起来像脏斑。
##     现在改用 textureSize 推导的 texel 尺寸, 任何分辨率下颗粒尺寸一致。
##

const SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float u_time : hint_range(0.0, 100.0) = 0.0;
uniform float u_sharpen : hint_range(0.0, 1.5) = 0.4;
uniform float u_vignette : hint_range(0.0, 1.0) = 0.3;
uniform float u_chromatic : hint_range(0.0, 1.0) = 0.0;
uniform float u_grain : hint_range(0.0, 0.1) = 0.008;
// 色彩分级: 默认全为恒等值, 关闭分级时画面与旧版逐像素一致
uniform float u_gain : hint_range(0.5, 1.5) = 1.0;
uniform float u_gamma : hint_range(0.5, 1.5) = 1.0;
uniform float u_lift : hint_range(-0.1, 0.2) = 0.0;
uniform float u_sat : hint_range(0.0, 2.0) = 1.0;
uniform float u_contrast : hint_range(0.5, 1.5) = 1.0;

vec3 s(vec2 uv) {
	return texture(screen_tex, uv).rgb;
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Interleaved Gradient Noise (Jimenez): 一行表达式的交错梯度噪声, 比 4x4
// Bayer 矩阵更适合做抖动 —— 无数组、无查表, 频谱更高, 大面积渐变上
// 不会留下可见的规则图案。
float ign(vec2 p) {
	return fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y));
}

void fragment() {
	vec2 uv = UV;
	vec2 texel = 1.0 / vec2(textureSize(screen_tex, 0));
	vec2 dir = uv - 0.5;
	float r2 = dot(dir, dir);

	// --- 径向色散: 中心为零, 边缘最强
	vec3 col;
	if (u_chromatic > 0.001) {
		vec2 off = dir * (u_chromatic * 0.004 * (0.35 + r2 * 4.0));
		col.r = s(uv + off).r;
		col.g = s(uv).g;
		col.b = s(uv - off).b;
	} else {
		col = s(uv);
	}

	// --- 边缘保护锐化: 邻域亮度跨度决定过冲上限, 杜绝白边光晕
	if (u_sharpen > 0.001) {
		vec3 c = col;
		vec3 n0 = s(uv + vec2(0.0, -texel.y));
		vec3 n1 = s(uv + vec2(0.0, texel.y));
		vec3 n2 = s(uv + vec2(-texel.x, 0.0));
		vec3 n3 = s(uv + vec2(texel.x, 0.0));
		vec3 blur = (n0 + n1 + n2 + n3) * 0.25;
		vec3 diff = c - blur;

		float lc = luma(c);
		float lo = min(min(min(luma(n0), luma(n1)), min(luma(n2), luma(n3))), lc);
		float hi = max(max(max(luma(n0), luma(n1)), max(luma(n2), luma(n3))), lc);
		float span = max(hi - lo, 0.002);
		// 允许的最大过冲 = 局部对比度的 35%; 平面区(span 小)自然几乎不锐化噪点,
		// 高对比边缘则被限幅 —— 这就是"清晰但不发光"的关键。
		float lim = span * 0.35;
		float dl = abs(luma(diff));
		float k = 1.0;
		if (dl > lim) {
			k = lim / max(dl, 1e-5);
		}
		// 亮部少锐化, 避免高光过曝处的振铃
		float hi_mask = 1.0 - smoothstep(0.72, 1.0, lc);
		col = c + diff * (u_sharpen * k * mix(0.45, 1.0, hi_mask));
	}

	// --- 色彩分级: lift / gamma / gain + 饱和 + 对比(围绕中灰)
	if (abs(u_gain - 1.0) > 0.0005 || abs(u_gamma - 1.0) > 0.0005
			|| abs(u_lift) > 0.0005 || abs(u_sat - 1.0) > 0.0005
			|| abs(u_contrast - 1.0) > 0.0005) {
		col = max(col, vec3(0.0)) * u_gain;
		col = pow(col, vec3(1.0 / max(u_gamma, 0.01)));
		col = clamp(col, 0.0, 1.0);
		col = u_lift + col * (1.0 - u_lift);
		float l = luma(col);
		col = mix(vec3(l), col, u_sat);
		col = (col - 0.5) * u_contrast + 0.5;
		col = clamp(col, 0.0, 1.0);
	}

	// --- 颗粒: 亮度越高噪点越少, 避免枪口火光上出现闪粒;
	//     尺度按实际 texel 归一, 任何分辨率下颗粒粗细一致
	if (u_grain > 0.0005) {
		float lum = luma(col);
		vec2 gp = uv / max(texel.x, 1e-6) / 2.0;
		float g = hash21(gp + fract(u_time) * 137.0) - 0.5;
		col += g * u_grain * (1.0 - lum * 0.6);
	}

	// --- 暗角
	if (u_vignette > 0.001) {
		float v = smoothstep(0.85, 0.25, length(dir) * 1.35);
		col *= mix(1.0, v, u_vignette);
	}

	// --- 有序抖动: 最后一步, 把量化误差打散(≈1/255 量级, 不会看出噪点)
	col += (ign(uv / max(texel.x, 1e-6)) - 0.5) * (1.0 / 255.0);

	COLOR = vec4(col, 1.0);
}
"""

var _mat: ShaderMaterial = null
var _time: float = 0.0
var _last_tier: int = -1


func _ready() -> void:
	name = "PostFX"
	layer = -1   # 3D 之上 / HUD 之下

	var rect := ColorRect.new()
	rect.name = "Rect"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 绝不能吃掉鼠标输入

	var sh := Shader.new()
	sh.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	rect.material = _mat
	add_child(rect)

	_apply_tier(GraphicsQuality.current())
	EventBus.graphics_changed.connect(_apply_tier)


func _process(delta: float) -> void:
	if _mat == null:
		return
	_time += delta
	if _time > 100.0:
		_time -= 100.0
	_mat.set_shader_parameter("u_time", _time)


func _apply_tier(_tier: int) -> void:
	if _mat == null:
		return
	var p: Dictionary = GraphicsQuality.preset()
	_mat.set_shader_parameter("u_sharpen", float(p.get("sharpen", 0.4)))
	_mat.set_shader_parameter("u_vignette", float(p.get("vignette", 0.3)))
	_mat.set_shader_parameter("u_chromatic", float(p.get("chromatic", 0.0)))
	_mat.set_shader_parameter("u_grain", float(p.get("grain", 0.0)))
	_mat.set_shader_parameter("u_gain", float(p.get("grade_gain", 1.0)))
	_mat.set_shader_parameter("u_gamma", float(p.get("grade_gamma", 1.0)))
	_mat.set_shader_parameter("u_lift", float(p.get("grade_lift", 0.0)))
	_mat.set_shader_parameter("u_sat", float(p.get("grade_sat", 1.0)))
	_mat.set_shader_parameter("u_contrast", float(p.get("grade_contrast", 1.0)))
