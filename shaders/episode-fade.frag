#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float u_margin;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    float y = qt_TexCoord0.y;
    float fadeIn  = clamp(y / u_margin, 0.0, 1.0);         // 顶:0 → 缩略图起始
    float fadeOut = clamp((1.0 - y) / u_margin, 0.0, 1.0); // 底:对称
    fragColor = c * min(fadeIn, fadeOut) * qt_Opacity;
}
