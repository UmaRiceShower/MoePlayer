// 预设驱动的应用背景。所有参数来自 uniform,新增外观只改 QML 预设表(ThemeStore.effects)。
// 四种风格(由 u_style 选择):
//   0 落樱 —— 列索引 + 屏外循环 + 深度同源哈希 + 双轴 tilt 翻滚(樱花贴图 alpha)
//   1 萤火 —— 双正弦游走 + 呼吸(≈7s)与高频闪烁
//   2 星夜 —— 哈希格星点(紧衰减圆核 + 慢呼吸 8~14s)+ 周期分箱流星
//   3 夜雨 —— 剪切空间列索引 + 同源哈希绑长度/速度/透明度
// 亮暗:u_light > 0.5 时粒子系用 alpha 覆盖混合(元素色为比底深的墨色);
// 否则加法发光(元素色为暗底上的浅色)。
// 配色纪律:背景感知明度 ≤0.10,前景主体 ≥0.7,远景降 alpha 不降明度。
// 坐标统一以窗口高度为尺度并做纵横比校正。
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D u_sprite;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float u_time;
    vec2 u_size;
    float u_intensity;
    float u_vignette;
    float u_style;
    float u_light;
    float u_meteorT;
    vec4 u_baseTop;
    vec4 u_baseBottom;
    vec4 u_g0Color;
    vec4 u_g1Color;
    vec4 u_g2Color;
};

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float sdSeg(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

// ---------------- 风格 0:落樱 ----------------
vec4 sakuraField(vec2 fragCoord) {
    vec3 col = vec3(0.0);
    float cov = 0.0;
    float ratio = u_size.x / max(u_size.y, 1.0);
    vec2 base = vec2(fragCoord.x * ratio, fragCoord.y) / u_size.y; 

    float bx = base.x + 0.22 * sin(u_time * 0.13) + 0.11 * sin(u_time * 0.31 + 1.7);

    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float cols = 12.0 + fi * 8.0;
        float colW = 1.0 / cols;

        int cxi = int(floor(bx / colW));
        for (int k = -3; k <= 3; k++) {  
            int cx = cxi + k;
            float seed = float(cx) * 0.717 + fi * 17.3;

            float h1 = hash21(vec2(seed, 1.3));
            float h2 = hash21(vec2(seed, 5.9));
            float h3 = hash21(vec2(seed, 9.1));
            float h4 = hash21(vec2(seed, 13.7));
            if (h3 < 0.50)
                continue;          

            // 深度同源:同一批哈希同时驱动大小/速度/透明度(近大远小快)
            float depth = clamp(fi * 0.33 + h1 * 0.67, 0.0, 1.0);   // 0 远 .. 1 近
            // 花径要 ≥16px 才认得出是樱花(再小就退化成"雪/星点")
            float size = (0.0110 + 0.0090 * h1) * (0.80 + 0.35 * fi);
            float fall = (0.075 + 0.022 * fi) * (0.85 + 0.30 * h1);  // 穿屏 ≈ 9~20s
            float phase = fract(h2 + u_time * fall);
            float y = phase * 1.30 - 0.15;           // -0.15 → 1.15:屏外循环

            // 横向(列单位):格内抖动 + 随下落线性漂移(±0.5 列)+ 2~4s 周期摆动(±0.2 列)
            float drift = (h2 - 0.5) * phase;
            float sway = 0.2 * (0.5 + 0.5 * h4)
                       * sin(u_time * 6.2831853 / (2.0 + 2.0 * h3) + h4 * 6.2831853);
            float xc = (float(cx) + 0.5 + (h4 - 0.5) * 0.4 + drift + sway) * colW;

            vec2 d = vec2(bx - xc, base.y - y);
            if (dot(d, d) > size * size * 4.0)
                continue;                            // 早退:不在这片花瓣附近

            // 2D 摆动旋转(±~28°)
            float rot = h1 * 6.2831853
                      + 0.5 * sin(u_time * 6.2831853 / (2.5 + 1.5 * h2) + h2 * 6.2831853);
            float ca = cos(rot), sa = sin(rot);
            vec2 rp = mat2(ca, sa, -sa, ca) * d;

            // 3D 翻滚:两轴独立角速度,采样坐标各向异性压缩;
            // max(|cos|, 死区) 防止完全侧视时花瓣消失(死区 0.17 ≈ sin10°)
            float tilt = h3 * 6.2831853 + u_time * (4.0 + 3.0 * h4);
            float tilt2 = h4 * 6.2831853 + u_time * (2.5 + 2.0 * h1);
            float flipX = max(abs(cos(tilt)), 0.17);
            float flipY = max(abs(cos(tilt2)), 0.30);
            rp = vec2(rp.x / flipX, rp.y / flipY);

            // 显式 LOD + 显式边界:不能用 texture() 隐式导数——翻转把采样坐标除以
            // ≤0.17,导数随之放大,GPU 会选到最粗 mip(整张贴图平均 alpha≈0.42),
            // 花瓣糊成半透明圆盘,边缘在 2×2 quad 边界导数不连续而抖成虚线环。
            vec2 uv01 = rp / (2.0 * size) + 0.5;
            if (any(lessThan(uv01, vec2(0.0))) || any(greaterThan(uv01, vec2(1.0))))
                continue;
            float lod = max(log2(96.0 / max(2.0 * size * u_size.y, 1.0)
                                     / min(flipX, flipY)), 0.0);
            float m = textureLod(u_sprite, uv01, lod).a;
            if (m < 0.004)
                continue;

            // 随下落轻度淡出;远瓣降 alpha 而非降明度(降明度 ⇒ 灰紫 ⇒ 显脏)
            float fade = mix(1.0, 0.55, phase);
            float alpha = (0.75 + 0.25 * depth) * fade;
            vec3 tint = depth < 0.5 ? mix(u_g2Color.rgb, u_g1Color.rgb, depth * 2.0)
                                    : mix(u_g1Color.rgb, u_g0Color.rgb, depth * 2.0 - 1.0);
            col += tint * m * alpha;
            cov += m * alpha;
        }
    }
    return vec4(col, cov);
}

// ---------------- 风格 1:萤火 ----------------
vec4 fireflyField(vec2 fragCoord) {
    vec3 col = vec3(0.0);
    float cov = 0.0;
    float ratio = u_size.x / max(u_size.y, 1.0);
    vec2 base = vec2(fragCoord.x * ratio, fragCoord.y) / u_size.y;

    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float cell = 0.24 + 0.06 * fi;
        vec2 c0 = floor(base / cell);

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                vec2 cc = c0 + vec2(float(dx), float(dy));
                float s1 = hash21(cc + fi * 31.0);
                float s2 = hash21(cc + fi * 31.0 + 3.7);
                float s3 = hash21(cc + fi * 31.0 + 11.3);
                if (s3 < 0.45)
                    continue;                        // 45% 留空 ⇒ 全屏 ~15 只

                vec2 home = (cc + 0.5 + (vec2(s1, s2) - 0.5) * 0.7) * cell;
                float w1 = 0.35 + 0.45 * s1, w2 = 0.30 + 0.40 * s2;
                float amp = cell * (0.35 + 0.20 * fi);
                vec2 pos = home + amp * vec2(sin(u_time * w1 + s1 * 6.2831853),
                                             sin(u_time * w2 * 0.83 + s2 * 6.2831853));

                float r = (0.006 + 0.004 * s2) * (0.8 + 0.5 * fi);   // 光晕半径 ≈ 8~17px
                float d = length(base - pos);
                if (d > r)
                    continue;
                float glow = smoothstep(1.0, 0.12, d / r);

                float breathe = 0.55 + 0.45 * sin(u_time * 0.9 + s1 * 6.2831853);
                float twinkle = 0.85 + 0.15 * sin(u_time * (5.0 + 4.0 * s3) + s2 * 6.2831853);
                vec3 tint = mix(u_g2Color.rgb, u_g0Color.rgb, clamp(fi * 0.5 + 0.5 * s1, 0.0, 1.0));
                float a = glow * breathe * twinkle * (0.55 + 0.45 * fi);
                col += tint * a;
                cov += a;
            }
        }
    }
    return vec4(col, cov);
}

// ---------------- 风格 2:星夜(星空 + 流星) ----------------
vec4 starField(vec2 fragCoord) {
    vec3 col = vec3(0.0);
    float cov = 0.0;
    float ratio = u_size.x / max(u_size.y, 1.0);
    vec2 base = vec2(fragCoord.x * ratio, fragCoord.y) / u_size.y;

    // 星(≈20px 格,22% 占位 ⇒ 全屏 ~500 颗)
    float cell = 0.030;
    vec2 q = base / cell;
    vec2 cc = floor(q);
    float s1 = hash21(cc);
    if (s1 > 0.78) {
        float s2 = hash21(cc + 5.1);
        float s3 = hash21(cc + 9.7);
        vec2 sp = (cc + 0.5 + (vec2(s2, s3) - 0.5) * 0.7) * cell;
        float d = length(base - sp);
        // 圆核:近心亮、边缘紧收(0.55 处已过半衰减);大面积软渐变会糊成团
        float r = 0.0011 + 0.0011 * s2;              // 半径 ≈ 0.8~1.6px,不越格
        float core = smoothstep(1.0, 0.55, d / r);
        // 慢呼吸:周期 8~14s 的逐星随机相位正弦;快闪读作噪点,呼吸才像星
        float tw = 0.55 + 0.45 * sin(u_time * (0.45 + 0.40 * s3) + s1 * 6.2831853);
        float a = core * tw * (0.70 + 0.30 * s3);
        col += u_g2Color.rgb * a;
        cov += a;
    }

    // 流星(两槽,周期 u_meteorT 由设置决定,寿命窗口 22%;u_meteorT ≤ 0 = 关闭)
    for (int slot = 0; slot < 2 && u_meteorT > 0.0; slot++) {
        float tt = u_time / u_meteorT + float(slot) * 0.5;
        float n = floor(tt);
        float p = fract(tt) / 0.22;
        if (p > 1.0)
            continue;
        float m1 = hash21(vec2(n, float(slot) * 7.1 + 1.0));
        float m2 = hash21(vec2(n, float(slot) * 7.1 + 3.0));
        vec2 dir = normalize(vec2(m1 > 0.5 ? -0.42 : 0.42, 1.0));   // 斜落 ≈ 23°
        vec2 start = vec2((0.15 + 0.7 * m2) * ratio, -0.06);
        vec2 head = start + dir * (p * 1.35);
        float tailLen = 0.16 * (0.5 + 0.5 * m1);
        vec2 tail = head - dir * tailLen;
        float d = sdSeg(base, head, tail);
        float line = smoothstep(0.0016, 0.0005, d);
        float along = clamp(dot(base - tail, dir) / tailLen, 0.0, 1.0);
        float fade = sin(3.14159265 * p);            // 进出淡入淡出
        float a = line * along * fade;
        col += mix(u_g1Color.rgb, u_g0Color.rgb, along) * a;
        cov += a;
    }
    return vec4(col, cov);
}

// ---------------- 风格 3:夜雨 ---------------
vec4 rainField(vec2 fragCoord) {
    vec3 col = vec3(0.0);
    float cov = 0.0;
    float ratio = u_size.x / max(u_size.y, 1.0);
    vec2 base = vec2(fragCoord.x * ratio, fragCoord.y) / u_size.y;

    vec2 dir = vec2(-0.22, 1.0);                     // 风 ⇒ 倾角 ≈ 12.5°
    float shear = dir.x / dir.y;
    dir = normalize(dir);

    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float cols = 90.0 + fi * 70.0;               // 90 / 160 列
        float colW = ratio / cols;
        float xs = base.x - shear * base.y;          // 剪切空间 x
        int cxi = int(floor(xs / colW));

        for (int k = -1; k <= 1; k++) {
            int cx = cxi + k;
            float seed = float(cx) * 0.613 + fi * 29.7;
            float h1 = hash21(vec2(seed, 2.9));
            float h2 = hash21(vec2(seed, 7.7));
            float h3 = hash21(vec2(seed, 12.3));
            if (h3 < 0.35)
                continue;                            // 65% 占位 ⇒ 全屏 ~160 条

            float s = h1;
            float spd = (0.45 + 0.35 * s) * (1.0 + 0.35 * fi);   // ≈ 320~740 px/s
            float len = (0.030 + 0.025 * s) * (1.0 + 0.30 * fi); // ≈ 21~55 px

            float phase = fract(h2 + u_time * spd * 0.976 / (1.0 + 2.0 * len));
            float headY = phase * (1.0 + 2.0 * len) - len;
            float x0 = (float(cx) + 0.5 + (h2 - 0.5) * 0.6) * colW;

            vec2 head = vec2(x0 + shear * headY, headY);
            vec2 tail = vec2(x0 + shear * (headY - len * dir.y), headY - len * dir.y);
            float d = sdSeg(base, head, tail);
            float line = smoothstep(0.0013, 0.0004, d);
            float a = line * (0.14 + 0.28 * s) * (0.55 + 0.45 * fi);
            col += u_g0Color.rgb * a;
            cov += a;
        }
    }
    return vec4(col, cov);
}


void main() {
    vec2 uv = qt_TexCoord0;
    float aspect = u_size.x / max(u_size.y, 1.0);
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - 0.5);

    // 底色:竖向为主 + 轻微对角分量。
    float g = clamp(uv.y * 0.85 + (uv.x - 0.5) * 0.30, 0.0, 1.0);
    vec3 col = mix(u_baseTop.rgb, u_baseBottom.rgb, g);

    if (u_style < -0.5) {
        // 无效果:只有底色 + 暗角
    } else {
        // 粒子系(樱/萤/星/雨):vec4(rgb = 覆盖率加权和, a = 覆盖率)
        vec4 fx = u_style > 2.5 ? rainField(uv * u_size)
              : u_style > 1.5 ? starField(uv * u_size)
              : u_style > 0.5 ? fireflyField(uv * u_size)
                              : sakuraField(uv * u_size);
        if (u_light > 0.5)
            // 亮底:元素是墨色,alpha 覆盖(取覆盖率加权平均色,避免叠亮)
            col = mix(col, fx.rgb / max(fx.a, 1e-4),
                      clamp(fx.a, 0.0, 1.0) * u_intensity);
        else
            col += fx.rgb * u_intensity;           // 暗底:加法发光
    }


    // 暗角:边缘压暗,把注意力收到中间。
    float v = smoothstep(1.25, 0.30, length(p) * 1.15);
    col *= mix(1.0, v, u_vignette);

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
