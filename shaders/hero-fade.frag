#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float u_fadeBand;   // 底部渐隐带高度,占背景高度比例(0.1 = 底 10%)
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    // 底 u_fadeBand 内线性淡出(alpha 1→0):y=1-0.1 起开始渐隐,
    // 图片细节保留到最后一刻再溶解入页面底色,无平板色带。
    float fade = clamp((1.0 - qt_TexCoord0.y) / u_fadeBand, 0.0, 1.0);
    fragColor = c * fade * qt_Opacity;
}
