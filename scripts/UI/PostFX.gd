extends CanvasLayer
class_name PostFX
##
## PostFX.gd — 全屏后处理叠加层
##
## 引擎自带的 Environment 覆盖不到这几项(或代价过高), 这里用一个全屏
## CanvasItem 着色器补齐:
##   · 锐化(非锐化掩膜) —— 直接提升"看得清", 全档位保留, 低档位也保留
##   · 暗角             —— 收拢视线, 增加画面厚度
##   · 色散             —— 边缘轻微 RGB 分离, 模拟镜头; 高档位才有, 量很小
##   · 胶片颗粒         —— 压掉色带与"塑料感"; 按亮度加权, 高光区抑制
##
## 层级放在 layer = -1: 画在 3D 之上、HUD 之下 —— 准星/血条/文字不受影响,
## 保持竞技可读性。
##

const SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float u_time : hint_range(0.0, 100.0) = 0.0;
uniform float u_sharpen : hint_range(0.0, 1.5) = 0.5;
uniform float u_vignette : hint_range(0.0, 1.0) = 0.32;
uniform float u_chromatic : hint_range(0.0, 1.0) = 0.3;
uniform float u_grain : hint_range(0.0, 0.1) = 0.02;

vec3 s(vec2 uv) {
	return texture(screen_tex, uv).rgb;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
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
		col = s(uv).rgb;
	}

	// --- 四邻域非锐化掩膜
	if (u_sharpen > 0.001) {
		vec3 blur = (s(uv + vec2(texel.x, 0.0))
			+ s(uv - vec2(texel.x, 0.0))
			+ s(uv + vec2(0.0, texel.y))
			+ s(uv - vec2(0.0, texel.y))) * 0.25;
		col += (col - blur) * u_sharpen;
	}

	// --- 颗粒: 亮度越高噪点越少, 避免枪口火光上出现闪粒
	if (u_grain > 0.0005) {
		float lum = dot(col, vec3(0.299, 0.587, 0.114));
		float g = hash21(uv * vec2(1920.0, 1080.0) + fract(u_time) * 137.0) - 0.5;
		col += g * u_grain * (1.0 - lum * 0.6);
	}

	// --- 暗角
	if (u_vignette > 0.001) {
		float v = smoothstep(0.85, 0.25, length(dir) * 1.35);
		col *= mix(1.0, v, u_vignette);
	}

	COLOR = vec4(col, 1.0);
}
"""

var _mat: ShaderMaterial = null
var _time: float = 0.0


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
	_mat.set_shader_parameter("u_sharpen", float(p.get("sharpen", 0.5)))
	_mat.set_shader_parameter("u_vignette", float(p.get("vignette", 0.32)))
	_mat.set_shader_parameter("u_chromatic", float(p.get("chromatic", 0.0)))
	_mat.set_shader_parameter("u_grain", float(p.get("grain", 0.0)))
