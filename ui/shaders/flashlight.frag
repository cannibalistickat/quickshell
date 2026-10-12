#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 uCursor;
    vec2 uSize;
    float uRadius;
    float uZoom;
    vec2 uPanOffset;
    vec2 uPanReserve;
    float uInvZoom;
    vec2 uBottomScale;
    vec2 uTopScale;
};

layout(binding = 1) uniform sampler2D texBottom;
layout(binding = 2) uniform sampler2D texTop;

vec2 cropUv(vec2 uv, vec2 scale)
{
    return (uv - 0.5) * scale + 0.5;
}

vec2 shiftedUv(vec2 uv, vec2 scale, vec2 pan)
{
    return cropUv(uv, scale) + pan / scale;
}

void main()
{
    const vec2 uv = qt_TexCoord0;
    const vec2 px = uv * uSize;
    const vec2 center = uCursor * uSize;
    const vec2 delta = px - center;
    const float distanceSquared = dot(delta, delta);

    const float radius = max(uRadius, 0.0);
    const float innerRadius = radius * 0.45;
    const float innerSquared = innerRadius * innerRadius;
    const float outerSquared = radius * radius;

    const vec2 reserve = uPanReserve;
    const vec2 pan = uPanOffset;

    if (distanceSquared >= outerSquared) {
        const vec2 scale = min(uTopScale, reserve);
        const vec2 shifted = shiftedUv(uv, scale, pan);
        fragColor = vec4(texture(texTop, shifted).rgb, 1.0);
        return;
    }

    if (distanceSquared <= innerSquared) {
        const vec2 scale = min(uBottomScale, reserve);
        const vec2 base = shiftedUv(uv, scale, pan);
        const vec2 cursor = cropUv(uCursor, scale);
        const vec2 hidden = cursor + (base - cursor) * uInvZoom;
        fragColor = vec4(texture(texBottom, hidden).rgb, 1.0);
        return;
    }

    const vec2 bottomScale = min(uBottomScale, reserve);
    const vec2 topScale = min(uTopScale, reserve);
    const vec2 bottomBase = shiftedUv(uv, bottomScale, pan);
    const vec2 topShifted = shiftedUv(uv, topScale, pan);
    const vec2 bottomCursor = cropUv(uCursor, bottomScale);
    const vec2 hidden = bottomCursor + (bottomBase - bottomCursor) * uInvZoom;

    const float reveal = smoothstep(
        innerRadius,
        radius,
        sqrt(distanceSquared));

    const vec3 bottom = texture(texBottom, hidden).rgb;
    const vec3 top = texture(texTop, topShifted).rgb;
    fragColor = vec4(mix(bottom, top, reveal), 1.0);
}
