#version 440

// lock_crt.frag — CRT glass pass for the lock-screen TV.
// Applied as layer.effect on the whole TV item: it warps the sampled content
// slightly (barrel), adds static noise, scanlines, a rolling band, flicker,
// chromatic fringe, vignette, a rounded-glass mask and a power-off collapse.
// One pass, no Source node cost beyond a single textured sample.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_res;
    float u_time;
    float u_noise;
    float u_off;
    float u_radius;
};

layout(binding = 1) uniform sampler2D source;

float hash(vec2 p) {
    p = fract(p * vec2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return fract(p.x * p.y);
}

// signed distance to rounded rect centered at origin, half-extents h, radius r
float sdRoundRect(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// approximate signed distance to a superellipse |x/a|^n + |y/b|^n = 1. This is
// the continuously-curved, non-rectangular face of an old CRT: bulging edges,
// softly-curved corners, no flat sides. n~2 = ellipse, n->inf = rectangle.
float sdSuper(vec2 p, vec2 b, float n) {
    vec2 q = pow(abs(p) / b, vec2(n));
    return (pow(q.x + q.y, 1.0 / n) - 1.0) * min(b.x, b.y);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 c2 = uv * 2.0 - 1.0;                    // -1..1 for warp + mask

    // --- barrel curvature: bulge the middle, squeeze the edges ---
    vec2 bend = c2 * (1.0 - 0.030 * (1.0 - c2.y * c2.y)) ;
    vec2 x2 = c2 * (1.0 - 0.022 * (1.0 - c2.x * c2.x));
    vec2 uvw = vec2(bend.x, x2.y) * 0.5 + 0.5;

    // --- power-off: content collapses onto a horizontal line ---
    float hgap = abs(uv.y - 0.5) - mix(0.5, 0.0022, u_off);
    if (hgap > 0.0) {
        // outside the slit: pure black (alpha 1 so the glass reads dead)
        float edge0 = sdRoundRect(c2 * u_res * 0.5, u_res * 0.5 - u_radius, u_radius);
        if (edge0 > 0.0) { fragColor = vec4(0.0); return; }
        float line = mix(0.0, 1.0, smoothstep(0.004, 0.0, hgap) * step(0.55, u_off));
        vec3 g = vec3(0.85, 0.95, 0.92) * line;
        fragColor = qt_Opacity * vec4(g, max(line, 1.0 - step(0.999, u_off)));
        return;
    }

    // --- glass outline: a superellipse (old-TV face), eased in from a plain
    // --- rectangle as the camera settles. curve=0 during the zoomed intro
    // --- (n large -> fills corner-to-corner), curve=1 once settled (bulged
    // --- tube). Derived from u_radius (= 0.07*min*dpr*introT) so no new uniform.
    float curve = clamp(u_radius / (0.07 * min(u_res.x, u_res.y)), 0.0, 1.0);
    float expo = mix(30.0, 6.0, curve);
    float sd = sdSuper(c2 * u_res * 0.5, u_res * 0.5, expo);
    // 0 deep inside -> 1 at the curved rim: drives defocus + rim darkening
    float blurW = 0.14 * min(u_res.x, u_res.y);
    float edge = 1.0 - clamp(-sd / blurW, 0.0, 1.0);

    // --- content sample: a real soft-focus (defocus) that grows toward the
    // --- curved rim — a 9-tap Poisson blur so the edge reads genuinely blurry
    // --- like the inspo, not merely darkened ---
    float blurPx = mix(0.0, 18.0, pow(edge, 1.4));
    vec2 bo = blurPx / u_res;
    vec3 s = texture(source, uvw).rgb;
    s += texture(source, uvw + vec2( 0.90,  0.20) * bo).rgb;
    s += texture(source, uvw + vec2(-0.70,  0.70) * bo).rgb;
    s += texture(source, uvw + vec2( 0.30,  1.00) * bo).rgb;
    s += texture(source, uvw + vec2(-1.00, -0.30) * bo).rgb;
    s += texture(source, uvw + vec2( 0.60, -0.90) * bo).rgb;
    s += texture(source, uvw + vec2(-0.40, -0.60) * bo).rgb;
    s += texture(source, uvw + vec2( 0.95, -0.20) * bo).rgb;
    s += texture(source, uvw + vec2(-0.20,  0.95) * bo).rgb;
    vec4 col = vec4(s / 9.0, 1.0);

    // --- scanlines: darken every other device row (CSS: black 25% @0.4% tile) ---
    float sl = mix(1.0, 0.80, step(0.5, fract(gl_FragCoord.y * 0.5)));
    col.rgb *= sl;

    // --- rolling band, slow upward drift ---
    float bandPos = fract(u_time * 0.09);
    float d = abs(uv.y - bandPos);
    col.rgb *= 1.0 - 0.10 * exp(-d * d * 900.0);

    // --- flicker (30 Hz) ---
    col.rgb *= 1.0 - 0.035 * hash(vec2(floor(u_time * 30.0), 7.0));

    // --- static noise ---
    float nz = hash(uv * u_res + mod(u_time * 61.7, 4096.0));
    nz = nz * 0.6 + 0.4 * hash(vec2(nz, floor(u_time * 60.0)));
    col.rgb = mix(col.rgb, vec3(nz * 0.92, nz * 0.96, nz), u_noise);

    // --- vignette + rim darkening: bright through the middle, easing toward
    // --- black at the curved glass edge so it reads as a soft blurry falloff ---
    float v = 1.0 - 0.50 * pow(length(c2 * vec2(0.62, 0.72)), 2.2);
    v *= 1.0 - 0.40 * smoothstep(0.65, 1.0, edge);
    col.rgb *= clamp(v, 0.0, 1.0);

    // --- slight cool tint + contrast punch (CSS: contrast 1.1, saturate 1.3-ish) ---
    col.rgb = clamp((col.rgb - 0.5) * 1.08 + 0.5, 0.0, 1.0);

    // --- glass mask: feathered superellipse edge (soft, not a hard cut) ---
    float a = smoothstep(0.0, -3.0, sd);
    fragColor = qt_Opacity * vec4(col.rgb * a, a);
}
