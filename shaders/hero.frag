#version 440
layout(location = 0) in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float sideTilt;
    float w;
    float h;
    float maxAngle;
    float focal;
    float sideInset;
    float meshDensity;
};
layout(binding = 1) uniform sampler2D src;

void main() {
    vec4 tex = texture(src, v_texcoord);
    // 边缘抗锯齿:按 uv 到卡片四边的距离做 1 像素宽度羽化。
    // fwidth 给出透视拉伸后的每像素 uv 梯度,保证任意倾角下边缘平滑。
    float fx = fwidth(v_texcoord.x);
    float fy = fwidth(v_texcoord.y);
    float dx = min(v_texcoord.x, 1.0 - v_texcoord.x);
    float dy = min(v_texcoord.y, 1.0 - v_texcoord.y);
    float ax = smoothstep(0.0, fx * 1.2, dx);
    float ay = smoothstep(0.0, fy * 1.2, dy);
    fragColor = tex * qt_Opacity * ax * ay;
}
