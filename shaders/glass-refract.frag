#version 440

// 磨砂玻璃(液体玻璃,edge lensing):光沿玻璃边缘弯曲、折射周围环境——
// 中心直透,仅外侧边缘带沿径向向外偏移采样(采到玻璃外的背景),玻璃
// 边缘"包裹"周围内容;叠加磨砂、边缘高光与投影,营造浮起的通透玻璃感。
// 物理模型:
//   - 归一化半径 t 由 SDF 圆角矩形距离求出(0 中心 → 1 边缘)。
//   - 边缘带权重 edge = smoothstep(0.45, 1, t);采样点 = 显示点 + 径向
//     单位向量 × 半径 × bend × edge——中心不动,边缘外移幅度渐强,与
//     玻璃外内容连续(偏移小,扩边内)。
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
    float u_bend;        // 边缘折射强度(0..1):边缘采样外移 = 半径 × bend
    float u_edgeLight;   // 边缘高光强度
    float u_frost;       // 磨砂模糊量(0=清晰,1=强磨砂)
    float u_blurRadius;  // 磨砂模糊半径(px)
    float u_saturation;  // 饱和度提升
    float u_hoverGlow;   // hover 提亮
    float u_light;       // 1 = 亮色系:加法提亮项收敛(浅底上加亮会过曝)
    vec4 u_backColor;    // 采样透明区回退色(页面留白 = 主题底色;否则亮主题下透出黑盘)
    vec4 u_glassColor;   // 玻璃底色(叠加在折射内容之上;a 控制强度)
    vec4 u_rimColor;     // 亮描边色(画在 SDF 边缘上,叠于底色之上;a=0 关闭)
};

layout(binding = 1) uniform sampler2D source;

// 采样源内容;透明区(源内容未覆盖处)按预乘 alpha 合成到主题底色上。
vec4 sampleScene(vec2 uv) {
    vec4 t = texture(source, uv);
    t.rgb += u_backColor.rgb * (1.0 - t.a);
    t.a = 1.0;
    return t;
}

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

vec2 toTexUV(vec2 controlPx) {
    return (u_srcOrigin + controlPx) / u_texSize;
}

vec4 blurSample(vec2 texUV, float radiusPx) {
    vec4 sum = vec4(0.0);
    float total = 0.0;
    vec2 step_ = radiusPx / u_texSize * 0.5;
    for (float x = -2.0; x <= 2.0; x += 1.0) {
        for (float y = -2.0; y <= 2.0; y += 1.0) {
            sum += sampleScene(texUV + vec2(x, y) * step_);
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

    // 边缘折射(edge lensing):中心直透,仅外侧边缘带沿径向向外偏移采样
    // (采到玻璃外的背景,玻璃边缘"包裹"周围内容);偏移随半径平滑上升,
    // 与玻璃外内容连续。thickness ≤ 0.5 = 纯磨砂(无折射):采样原地。
    vec3 normal = vec3(0.0, 0.0, 1.0);
    vec2 ruv = toTexUV(px + half_);
    float reflW = 0.0;
    if (u_thickness > 0.5) {
        normal = glassNormal(d, u_thickness);
        float t = clamp((d + u_thickness) / max(u_thickness, 0.5), 0.0, 1.0);  // 0 中心 → 1 边缘
        float edge = smoothstep(0.45, 1.0, t);                                 // 边缘带权重
        vec2 dir = length(px) > 1e-3 ? normalize(px) : vec2(0.0, 0.0);
        // 方向自适应偏移上限:沿 dir 到纹理边界的可用空间(扣掉玻璃半径与
        // 磨砂半径)。贴近窗口边缘的方向自动减弱,避免越界取边界列(clamp
        // 拉伸);远离边缘的方向保持完整折射。
        vec2 centerTex = u_srcOrigin + half_;
        vec2 room = mix(centerTex, u_texSize - centerTex, step(vec2(0.0), dir))
                    / max(abs(dir), vec2(1e-4));
        float avail = min(room.x, room.y) - max(half_.x, half_.y) - u_blurRadius;
        float bendPx = min(min(half_.x, half_.y) * u_bend, max(0.0, avail));
        vec2 hitPx = px + half_ + dir * (bendPx * edge);
        ruv = toTexUV(hitPx);
        reflW = clamp((1.0 - normal.z) * 2.0, 0.0, 1.0);
    }
    vec4 sharp = sampleScene(ruv);

    // 反射项已在上方折射分支内计算(reflW,纯磨砂时为 0)。

    // 磨砂:清晰折射与模糊按 frost 混合。
    vec4 blurred = blurSample(ruv, u_blurRadius);
    vec4 c = mix(sharp, blurred, clamp(u_frost, 0.0, 1.0));

    // 饱和度提升。
    float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    c.rgb = mix(vec3(luma), c.rgb, 1.0 + u_saturation);

    // 边缘高光 + 反射提亮(亮底收敛:浅底加亮会过曝成白边)。
    float edge = 1.0 - clamp(normal.z, 0.0, 1.0);
    float addScale = mix(1.0, 0.35, clamp(u_light, 0.0, 1.0));
    c.rgb += vec3(u_edgeLight * edge * edge + reflW * 0.15) * addScale;

    // hover 提亮:提亮折射内容 + 边缘光,不盖白膜(亮底同样收敛)。
    c.rgb *= 1.0 + u_hoverGlow * mix(0.35, 0.15, clamp(u_light, 0.0, 1.0));
    c.rgb += vec3(u_hoverGlow * edge * 0.25) * addScale;

    // 玻璃底色叠加(原 QML 覆盖层,并入 shader 保证描边不被底色罩暗)。
    c.rgb = mix(c.rgb, u_glassColor.rgb, u_glassColor.a);

    // 亮描边:画在 SDF 边缘(玻璃真实边缘)的 1px 带
    float rim = 1.0 - smoothstep(0.0, 1.5, -d);   // -d = 到边缘的距离(px)
    c.rgb = mix(c.rgb, u_rimColor.rgb, rim * u_rimColor.a);

    // 圆角抗锯齿 + alpha 预乘。
    float alpha = 1.0 - smoothstep(-0.5, 0.5, d);
    c.rgb *= alpha;
    c.a = alpha;

    fragColor = c * qt_Opacity;
}
