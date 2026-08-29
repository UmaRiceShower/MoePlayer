#version 440

// 磨砂玻璃(液体玻璃凸透镜):整块玻璃是一个微凸的透镜表面,整个面都折射
// (中心微凸放大、边缘强弯折),而非仅边缘窄带。参考凸透镜玻璃按钮。
// 物理模型:
//   - 玻璃是中心微凸、边缘陡弯的圆角矩形透镜(厚度剖面为平滑凸面)。
//   - 法线由「到中心的归一化径向距离」经凸面剖面(cos/幂曲线)得出:
//     中心法线近 +z(微凸轻折),向边缘法线渐倾(弯折渐强)——整个面都折射。
//   - 折射采样 = uv + 折射向量 xy × 折射长度(随凸面高度/折射角变化),
//     中心放大、边缘拉向边缘,产生透镜体积感。
//   - 边缘高光 + 反射:法线越平(边缘)越亮。
//   - 磨砂 = 折射结果与多 tap 模糊按 frost 混合(独立叠加)。
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_size;         // 控件像素尺寸(width, height)
    vec2 u_srcOrigin;    // 玻璃矩形在采样纹理中的像素原点(扩边后左上角)
    vec2 u_texSize;      // 采样纹理的像素尺寸
    float u_radius;      // 圆角半径(px)
    float u_thickness;   // 玻璃中心凸起厚度(px):越大中心放大/边缘弯折越强
    float u_ior;         // 折射率(玻璃 1.5)
    float u_edgeLight;   // 边缘高光强度
    float u_frost;       // 磨砂模糊量(0=清晰,1=强磨砂)
    float u_blurRadius;  // 磨砂模糊半径(px)
    float u_saturation;  // 饱和度提升
    float u_hoverGlow;   // hover 提亮
};

layout(binding = 1) uniform sampler2D source;

// 圆角矩形有向距离(内负外正)。
float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
// SDF 屏幕导数重建 3D 法线(getNormal):thickness 为隆起厚度。
vec3 glassNormal(float sd, float thickness) {
    float dx = dFdx(sd);
    float dy = dFdy(sd);
    float n_cos = clamp((thickness + sd) / thickness, 0.0, 1.0);
    float n_sin = sqrt(max(0.0, 1.0 - n_cos * n_cos));
    vec3 n = vec3(dx * n_cos, dy * n_cos, n_sin);
    float len = length(n);
    return len > 1e-5 ? n / len : vec3(0.0, 0.0, 1.0);
}

// 玻璃隆起表面高度(cos 剖面,参考 height):sd<0 内部,边缘→0。
float glassHeight(float sd, float thickness) {
    if (sd >= 0.0)
        return 0.0;
    if (sd < -thickness)
        return thickness;
    float x = thickness + sd;
    return sqrt(max(0.0, thickness * thickness - x * x));
}


vec2 toTexUV(vec2 controlPx) {
    return (u_srcOrigin + controlPx) / u_texSize;
}

vec4 blurSample(vec2 texUV, float radiusPx) {
    vec4 sum = vec4(0.0);
    float total = 0.0;
    vec2 step_ = radiusPx / u_texSize * 0.5;
    for (float x = -2.0; x <= 2.0; x += 1.0) {
        for (float y = -2.0; y <= 2.0; y += 1.0) {
            sum += texture(source, texUV + vec2(x, y) * step_);
            total += 1.0;
        }
    }
    return sum / total;
}

void main() {
    vec2 px = (qt_TexCoord0 - 0.5) * u_size;   // 控件内像素(中心原点)
    vec2 half_ = u_size * 0.5;
    float d = sdRoundBox(px, half_, u_radius);

    if (d > 0.5) {                              // 外部透明
        fragColor = vec4(0.0);
        return;
    }

    // ---- 参考2 精确模型:SDF 屏幕导数法线 + cos 高度剖面 + (h+base)/-z 折射 ----
    // 隆起带 = 到边缘的绝对像素距离 ∈ [-thickness, 0]:当 thickness ≥ 短边一半,
    // 整个截面都隆起(参考2 size.y=0 的效果——整条都是弧面,无平面中心)。
    // thickness ≤ 0 = 纯磨砂(无折射):法线 +z、不折射,采样原地;只留模糊。
    // thickness > 0 = 凸透镜折射(SDF 法线 + Snell + 厚度变倍率)。
    vec3 normal = vec3(0.0, 0.0, 1.0);
    vec2 ruv = toTexUV(px + half_);
    float reflW = 0.0;
    if (u_thickness > 0.5) {
        normal = glassNormal(d, u_thickness);
        vec3 incident = vec3(0.0, 0.0, -1.0);
        // Snell 折射。
        vec3 refr = refract(incident, normal, 1.0 / u_ior);
        if (dot(refr, refr) < 1e-6)
            refr = vec3(normal.xy, -normal.z);
        // 折射长度:(隆起高 + 基准高) / 折射向量 -z 分量。
        float h = glassHeight(d, u_thickness);
        float base_h = u_thickness * 8.0;
        float rz = max(0.05, -refr.z);
        float refractLen = (h + base_h) / rz;
        // 折射命中点(控件像素):边缘法线外倾 → 采样点外移(凸透镜放大感)。
        vec2 hitPx = px + half_ + refr.xy * refractLen;
        ruv = toTexUV(hitPx);
        reflW = clamp((1.0 - normal.z) * 2.0, 0.0, 1.0);
    }
    vec4 sharp = texture(source, ruv);

    // 反射项已在上方折射分支内计算(reflW,纯磨砂时为 0)。

    // 磨砂:清晰折射与模糊按 frost 混合。
    vec4 blurred = blurSample(ruv, u_blurRadius);
    vec4 c = mix(sharp, blurred, clamp(u_frost, 0.0, 1.0));

    // 饱和度提升。
    float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    c.rgb = mix(vec3(luma), c.rgb, 1.0 + u_saturation);

    // 边缘高光 + 反射提亮。
    float edge = 1.0 - clamp(normal.z, 0.0, 1.0);
    c.rgb += vec3(u_edgeLight * edge * edge + reflW * 0.15);

    // hover 提亮:提亮折射内容 + 边缘光,不盖白膜。
    c.rgb *= 1.0 + u_hoverGlow * 0.35;
    c.rgb += vec3(u_hoverGlow * edge * 0.25);

    // 圆角抗锯齿 + alpha 预乘。
    float alpha = 1.0 - smoothstep(-0.5, 0.5, d);
    c.rgb *= alpha;
    c.a = alpha;

    fragColor = c * qt_Opacity;
}
