// CrossfadeImage 的混合 shader:双层圆形扩散溶解 + 圆角。
// - 静态(u_reveal <= 0):显示 srcOld,仅圆角。
// - 动画:圆内新图渐入(u_dissolve),圆外旧图;u_inward=1 时反转(圆外新图)。
// - 圆角:corner SDF 裁切,圆角外 alpha=0 真透明。srcOld/srcNew 为
//   visible:false + layer.enabled 的离屏纹理(官方示例模式),故透明区
//   直接透出页面背景,无直角内容可露。
// - 纹理为物理分辨率(ShaderEffectSource textureSize x dpr),锐利。
// 本 shader 用于普通 ShaderEffect(非 layer.effect):QML 属性按名绑定
// uniform block 成员(溶解动画已验证该路径可靠)。
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float u_radius;
    vec2 u_size;
    vec2 u_center;
    float u_reveal;
    float u_dissolve;
    float u_inward;
};

layout(binding = 1) uniform sampler2D srcOld;
layout(binding = 2) uniform sampler2D srcNew;

void main() {
    vec2 px = qt_TexCoord0 * u_size;
    vec4 c;
    if (u_reveal <= 0.0) {
        c = texture(srcOld, qt_TexCoord0);
    } else {
        float dist = length(px - u_center);
        float inC = 1.0 - smoothstep(u_reveal - 1.0, u_reveal, dist);
        float m = mix(inC, 1.0 - inC, u_inward) * u_dissolve;
        c = mix(texture(srcOld, qt_TexCoord0), texture(srcNew, qt_TexCoord0), m);
    }
    // 圆角 SDF:q = 到内矩形的距离,负 = 圆内。
    vec2 q = abs(px - u_size * 0.5) - (u_size * 0.5 - vec2(u_radius));
    float d = length(max(q, 0.0)) - u_radius;
    float corner = 1.0 - smoothstep(0.0, 1.5, max(d, 0.0));
    fragColor = c * corner * qt_Opacity;
}
