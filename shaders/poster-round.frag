#version 440
// 海报卡圆角:SDF 解析抗锯齿(蒙版纹理无 MSAA,阈值重映射救不回硬边)。
// u_size = 卡面物理像素,u_radius = 圆角半径。
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_size;
    float u_radius;
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec4 c = texture(source, qt_TexCoord0);
    vec2 px = qt_TexCoord0 * u_size;
    vec2 q = abs(px - u_size * 0.5) - (u_size * 0.5 - vec2(u_radius));
    float d = length(max(q, vec2(0.0))) - u_radius;
    float aa = max(fwidth(d), 0.75);
    fragColor = c * (1.0 - smoothstep(-aa, aa, d)) * qt_Opacity;
}
