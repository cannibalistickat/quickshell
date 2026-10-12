#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 uSize;
    float uValue;
    float uWarn;
    float uGlyph;
    float uLeft;
};

float strokeMask(float distanceToLine, float width)
{
    return 1.0 - smoothstep(max(0.0, width - 1.0), width + 1.0, abs(distanceToLine));
}

float segmentDistance(vec2 p, vec2 a, vec2 b)
{
    vec2 pa = p - a;
    vec2 ba = b - a;
    float divisor = max(dot(ba, ba), 0.0001);
    float h = clamp(dot(pa, ba) / divisor, 0.0, 1.0);
    return length(pa - ba * h);
}

float arcStroke(vec2 p, vec2 center, float radius, float width, float progress)
{
    vec2 d = p - center;
    float radiusError = length(d) - radius;
    float axis = uLeft > 0.5 ? d.x : -d.x;
    float angle = atan(d.y, axis);
    float t = clamp(angle / 3.14159265 + 0.5, 0.0, 1.0);
    float angular = 1.0 - smoothstep(progress, progress + 0.02, t);
    return strokeMask(radiusError, width) * angular;
}

void addColor(inout vec4 target, vec3 color, float alpha)
{
    target.rgb += color * alpha;
    target.a = max(target.a, alpha);
}

void main()
{
    vec2 p = qt_TexCoord0 * uSize;
    vec2 center = vec2(uLeft > 0.5 ? 0.0 : uSize.x, uSize.y * 0.5);
    float radius = min(30.0, min(uSize.x - 2.0, uSize.y * 0.5 - 2.0));
    float radial = length(p - center);
    float body = 1.0 - smoothstep(radius - 0.75, radius + 0.75, radial);
    float border = strokeMask(radial - radius, 0.9);

    vec3 ink = uWarn > 0.5 ? vec3(0.949, 0.427, 0.427) : vec3(0.949);
    vec4 result = vec4(0.0);

    addColor(result, vec3(0.0), body * 0.55);
    addColor(result, vec3(1.0), border * 0.10);
    addColor(result, ink, arcStroke(p, center, max(1.0, radius - 6.0), 3.0, clamp(uValue, 0.0, 1.0)) * 0.95);
    addColor(result, ink, arcStroke(p, center, max(1.0, radius - 11.0), 1.6, clamp(uValue, 0.0, 1.0)) * 0.35);

    vec2 iconCenter = vec2(center.x + (uLeft > 0.5 ? radius * 0.55 : -radius * 0.55), center.y);
    vec2 q = p - iconCenter;

    if (uGlyph < 0.5) {
        float bodyShape = 1.0 - smoothstep(0.0, 0.8,
            max(abs(q.x + 6.8) - 2.3, abs(q.y - 2.4) - 4.5));
        vec2 a = vec2(-4.7, -4.5);
        vec2 b = vec2(2.5, -9.0);
        vec2 c = vec2(2.5, 9.0);
        vec2 v0 = b - a;
        vec2 v1 = c - a;
        vec2 v2 = q - a;
        float d = v0.x * v1.y - v1.x * v0.y;
        float baryA = (v2.x * v1.y - v1.x * v2.y) / d;
        float baryB = (v0.x * v2.y - v2.x * v0.y) / d;
        float speaker = (baryA >= 0.0 && baryB >= 0.0 && baryA + baryB <= 1.0) ? 1.0 : 0.0;
        addColor(result, ink, max(bodyShape, speaker));

        if (uWarn > 0.5) {
            addColor(result, ink, strokeMask(segmentDistance(q, vec2(-10.0, -9.0), vec2(10.0, 9.0)), 1.8));
        } else {
            float r0 = abs(length(q - vec2(4.0, 0.0)) - 3.2);
            float r1 = abs(length(q - vec2(4.0, 0.0)) - 5.8);
            float theta = atan(q.y, q.x - 4.0);
            float wave = smoothstep(-1.047, -1.000, theta) * (1.0 - smoothstep(1.000, 1.047, theta));
            addColor(result, ink, strokeMask(r0, 1.6) * wave);
            addColor(result, ink, strokeMask(r1, 1.6) * wave);
        }
    } else if (uWarn > 0.5) {
        addColor(result, ink, (1.0 - smoothstep(5.7, 6.5, length(q))) * 0.4);
        addColor(result, ink, strokeMask(segmentDistance(q, vec2(-10.0, -9.0), vec2(10.0, 9.0)), 2.0));
    } else {
        addColor(result, ink, strokeMask(length(q) - 5.5, 2.0));
        for (int i = 0; i < 8; ++i) {
            float angle = float(i) * 0.785398163;
            vec2 a = vec2(cos(angle), sin(angle)) * 7.5;
            vec2 b = vec2(cos(angle), sin(angle)) * 10.5;
            addColor(result, ink, strokeMask(segmentDistance(q, a, b), 1.6));
        }
    }

    fragColor = result * qt_Opacity;
}
