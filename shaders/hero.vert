#version 440
// Hero 轮播侧卡:绕 Y 轴真 3D 旋转 + 透视投影。
// 相机位于 +z 看向原点;卡片平面在 z=0。旋转后做一次标准透视除法,
// 把带深度的齐次 w 交给光栅化器,varying 自动透视校正。
layout(location = 0) in vec4 qt_Vertex;        // 卡片局部坐标 (0..w, 0..h)
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 v_texcoord;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;      // Qt 场景图 MVP(item 缩放/平移/窗口投影)
    float qt_Opacity;
    float sideTilt;      // >0 左卡, <0 右卡, 0 中卡
    float w;
    float h;
    float maxAngle;      // 侧卡最大转角(度),压低到 24° 避免弧度/穿帮
    float focal;         // 焦距(像素),越大透视越弱
    float sideInset;     // 侧卡向中线收拢的水平位移(像素)
    float meshDensity;   // 网格密度,缓解透视锯齿
    float radiusPx;      // 与 frag 块布局一致(std140 同名块两阶段需同布局)
    float padPx;
};

void main() {
    // 1) 局部 3D 坐标,以卡片中心为原点,平面在 z=0。
    vec3 p = vec3(qt_Vertex.x - w * 0.5, qt_Vertex.y - h * 0.5, 0.0);

    // 2) 绕 Y 轴旋转(中卡角度 0)。
    float t = clamp(sideTilt, -1.0, 1.0);
    float ang = radians(maxAngle) * t;
    float c = cos(ang);
    float s = sin(ang);
    vec3 rp = vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);

    // 3) 侧卡向中线收拢。
    rp.x += -t * sideInset;

    // 4) 标准透视投影:相机在 +focal 看向原点,视线深度 d = focal - rp.z。
    //    把投影写进齐次 w,GPU 透视除法后 varying 自动校正。
    float d = focal - rp.z;
    float kw = d / focal;
    // 齐次裁剪坐标:先投影到 item 平面,再乘 kw 让 w=kw。
    vec2 proj = rp.xy / kw + vec2(w * 0.5, h * 0.5);
    vec4 clip = qt_Matrix * vec4(proj, 0.0, 1.0);
    // 关键:xyz 乘 kw、w=kw -> 透视除法后回到 proj,varying 按 1/kw 加权。
    clip = vec4(clip.xyz * kw, kw);
    gl_Position = clip;

    v_texcoord = qt_MultiTexCoord0;
}
