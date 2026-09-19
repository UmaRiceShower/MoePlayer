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
    float radiusPx;      // 圆角半径(像素,卡面空间)
    float padPx;         // 过扫描边距(宿主比卡面大的像素数/边)
};
layout(binding = 1) uniform sampler2D src;

void main() {
    vec4 tex = texture(src, v_texcoord);
    // 圆角 + 抗锯齿:片元做圆角矩形 SDF(Qt 的 clip 只按矩形裁,radius
    // 不裁子项——图片圆角只能 shader/蒙版做,SDF 零额外 pass)。
    // fwidth 给出透视拉伸后的每像素 uv 梯度,任意倾角下边缘平滑。
    vec2 px = (v_texcoord - 0.5) * vec2(w, h);
    // 宿主含 pad:内容(卡面)半宽 = 全幅半宽 - pad;SDF 零等值线 = 卡界,
    // 落在 mesh 三角形内部 pad 像素处,ramp 两侧都有像素。
    vec2 b = vec2(w, h) * 0.5 - vec2(padPx + radiusPx);
    vec2 q = abs(px) - b;
    float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radiusPx;
    // AA 带宽下限:侧卡透视压缩下 fwidth 可退化到 <1 屏幕像素(边缘
    // 锯齿实测),保底 1.25 卡面像素。
    // 紧 ramp:fwidth 微量 + 1.0 卡面像素下限。宽 ramp 会让动画背景的
    // 星星从边缘半透区透出成移动暗斑(实测星空主题下虚线纹),越窄越好。
    float fw = max(fwidth(sd), 1.0);
    float aa = smoothstep(fw, -fw, sd);
    fragColor = tex * qt_Opacity * aa;
}
