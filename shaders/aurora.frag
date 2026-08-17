// 萌系极光背景:深色底上缓慢流动的粉紫光斑,低饱和低透明度,不抢内容。
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float u_time;
};

void main() {
    vec2 uv = qt_TexCoord0;

    // 主深色底,与 Theme.bg (#0d1117) 对齐。
    vec3 bg = vec3(0.051, 0.067, 0.090);
    // 萌系粉 / 淡紫,只在低透明度下混入。
    vec3 pink = vec3(1.0, 0.62, 0.74);
    vec3 purple = vec3(0.65, 0.42, 0.72);

    float t = u_time * 0.05;

    // 三个缓慢漂移的光斑,周期错开,形成流动感。
    vec2 p1 = vec2(0.25 + 0.22 * sin(t),       0.45 + 0.18 * cos(t * 0.7));
    vec2 p2 = vec2(0.80 + 0.18 * sin(t * 0.6 + 2.0), 0.35 + 0.14 * cos(t * 0.5));
    vec2 p3 = vec2(0.50 + 0.30 * sin(t * 0.4 + 4.0), 0.75 + 0.20 * cos(t * 0.8));

    float d1 = length(uv - p1);
    float d2 = length(uv - p2);
    float d3 = length(uv - p3);

    float b1 = smoothstep(0.55, 0.0, d1);
    float b2 = smoothstep(0.50, 0.0, d2);
    float b3 = smoothstep(0.45, 0.0, d3);

    vec3 col = bg;
    col = mix(col, pink,   b1 * 0.30);
    col = mix(col, purple, b2 * 0.22);
    col = mix(col, pink * 0.85, b3 * 0.18);

    // 顶部略暗,底部微微提亮,增加纵深感;整体仍保持暗色保证可读性。
    col = mix(col, vec3(0.025, 0.032, 0.045), uv.y * 0.35);

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
