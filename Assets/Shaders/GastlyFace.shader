// Unity 6 (URP) port of the Godot "Gastly face" spatial shader.
//
// Source (Godot 4):
//   shader_type spatial;
//   render_mode unshaded;
//   ALBEDO/ALPHA written in fragment(), all shapes are procedural SDF-style
//   ellipse/circle/line tests in a 0..1 UV space where Y points UP.
//
// Conversion notes:
//   - TIME            -> _Time.y  (Unity's _Time.y is seconds; _Time.x is t/20)
//   - Godot UV is y-down ((0,0) top-left); the original flips it with
//     (1.0 - UV.y) to get a y-up shape space. A Unity Quad's UV is already
//     y-up ((0,0) bottom-left), so the flip is REMOVED here. If you use a
//     mesh whose UV is y-down, restore it: uv.y = 1.0 - uv.y + s1.
//   - unshaded        -> unlit pass, direct color output.
//   - ALPHA           -> transparent: Blend SrcAlpha OneMinusSrcAlpha,
//     ZWrite Off, Transparent queue.
//   - The noise texture is scrolled by (-t, t), so its Wrap Mode MUST be
//     set to Repeat in the import settings.
Shader "Custom/GastlyFace"
{
    Properties
    {
        _MainTex ("Noise Texture", 2D) = "white" {}
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Transparent"
            "Queue" = "Transparent"
            "RenderPipeline" = "UniversalPipeline"
        }

        Pass
        {
            Name "ForwardUnlit"

            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Back

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex);
                return OUT;
            }

            // ------------------------------------------------------------------
            // Shape functions, translated 1:1 from the original Godot shader.
            // Quirks are intentional and kept as-is (e.g. (y*y)/vy with vy not
            // squared in left_eye/mouth, pupils scaled by max(r, t*0.0004)).
            // ------------------------------------------------------------------

            float body(float2 p)
            {
                const float2 o = float2(0.47, 0.48);
                const float r = 0.06;
                float x = p.x - o.x;
                float y = p.y - o.y;
                return float((x * x + y * y) < r);
            }

            float left_eye(float2 p, float t)
            {
                const float vx = 0.9;
                const float vy = 1.0;
                const float r = 0.022;
                const float2 o = float2(0.54, 0.54);
                float x = p.x - o.x;
                float y = p.y - o.y;
                float q = float(((x * x) / (vx * vx) + (y * y) / vy) > r);
                bool edge = (p.y - 0.02 - t * 0.2 < p.x);
                return edge ? q : 1.0;
            }

            float right_eye(float2 p, float t)
            {
                const float vx = 0.6;
                const float vy = 1.0;
                const float r = 0.022;
                const float2 o = float2(0.3, 0.54);
                float x = p.x - o.x;
                float y = p.y - o.y;
                float q = float(((x * x) / (vx * vx) + (y * y) / vy) > r);
                bool edge = (p.y < 0.2 * t + 1.0 - p.x * 1.5);
                return edge ? q : 1.0;
            }

            float left_pupil(float2 p, float t)
            {
                const float vx = 1.0;
                const float vy = 4.0;
                const float r = 0.00002;
                const float2 o = float2(0.516, 0.48);
                float x = p.x - o.x;
                float y = p.y - o.y;
                return float(((x * x) / vx + (y * y) / (vy * vy)) > max(r, t * 0.0004));
            }

            float right_pupil(float2 p, float t)
            {
                const float vx = 1.0;
                const float vy = 4.0;
                const float r = 0.00002;
                const float2 o = float2(0.305, 0.48);
                float x = p.x - o.x;
                float y = p.y - o.y;
                return float(((x * x) / vx + (y * y) / (vy * vy)) > max(r, t * 0.0004));
            }

            float mouth(float2 p)
            {
                const float vx = 1.1;
                const float vy = 1.0;
                const float r = 0.04;
                const float3 o = float3(0.45, 0.49, 0.54);
                float x = p.x - o.x;
                float y = p.y - o.y;
                float yy = p.y - o.z;
                float q = float(((x * x) / (vx * vx) + (y * y) / vy) > r);
                bool edge = (((x * x) / (1.5 * 1.5) + (yy * yy) / vy) > r);
                return edge ? q : 1.0;
            }

            float left_canine(float2 p)
            {
                const float vx = 1.1;
                const float vy = 1.0;
                const float r = 0.04;
                const float3 o = float3(0.45, 0.49, 0.54);
                float x = p.x - o.x;
                float y = p.y - o.y;
                float yy = p.y - o.z;
                float q = float(((x * x) / (vx * vx) + (y * y) / vy) > r);
                bool edge = (((x * x) / (1.5 * 1.5) + (yy * yy) / vy) > r);
                bool edge_y = (p.y < 0.5);
                float m = float(p.y - 0.32 > abs(3.0 * p.x - 0.91));
                return (edge && edge_y) ? m : 0.0;
            }

            float right_canine(float2 p)
            {
                const float vx = 1.1;
                const float vy = 1.0;
                const float r = 0.04;
                const float3 o = float3(0.45, 0.49, 0.54);
                float x = p.x - o.x;
                float y = p.y - o.y;
                float yy = p.y - o.z;
                float q = float(((x * x) / (vx * vx) + (y * y) / vy) > r);
                bool edge = (((x * x) / (1.5 * 1.5) + (yy * yy) / vy) > r);
                bool edge_y = (p.y < 0.5);
                float m = float(p.y - 0.29 > abs(2.5 * p.x - 1.4));
                return (edge && edge_y) ? m : 0.0;
            }

            float eye_bag(float2 p)
            {
                const float r = 0.022;
                float x = p.x - 0.545;
                float y = p.y - 0.525;
                float ex = p.x - 0.54;
                float ey = p.y - 0.545;
                bool edge = ((ex * ex + ey * ey) > 0.027);
                float q = float((x * x + y * y) > r);
                return edge ? q : 1.0;
            }

            float smoke(float2 p, float n)
            {
                float noise = n;
                float x = p.x - 0.5;
                float y = p.y - 0.5;
                return float(0.35 * noise + (x * x + y * y) < 0.20);
            }

            float4 frag(Varyings IN) : SV_Target
            {
                float t = _Time.y * 0.25;
                float s1 = sin(0.5 + t * 10.0) * 0.1;
                float s2 = sin(t * 10.0) * 0.1;

                // Unity Quad UV is already y-up; the original Godot shader's
                // (1.0 - UV.y) flip is intentionally removed. See file header.
                float2 uv = float2(IN.uv.x, IN.uv.y + s1);

                float body_shape = body(uv);
                float left_eye_shape = 1.0 - left_eye(uv, s2);
                float right_eye_shape = 1.0 - right_eye(uv, s2);
                float left_pupil_shape = left_pupil(uv, s2);
                float right_pupil_shape = right_pupil(uv, s2);
                float mouth_shape = 1.0 - mouth(uv);
                float left_canine_shape = left_canine(uv);
                float right_canine_shape = right_canine(uv);
                float eye_bag_shape = 1.0 - eye_bag(uv);
                float smoke_shape = smoke(uv, SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv + float2(-t, t)).r);

                float c = 255.0;
                float3 smoke_color = float3(124.0 / c, 110.0 / c, 187.0 / c);
                float3 body_color = float3(5.0 / c, 0.0, 16.0 / c);
                float3 mouth_color = float3(255.0 / c, 65.0 / c, 65.0 / c);

                float3 render = float3(0.0, 0.0, 0.0);
                render += smoke_color * clamp(smoke_shape + body_shape, 0.0, 1.0);
                render *= lerp(render, body_color, body_shape);
                render += left_eye_shape;
                render += right_eye_shape;
                render *= left_pupil_shape;
                render *= right_pupil_shape;
                render = lerp(render, mouth_color, mouth_shape);
                render += left_canine_shape;
                render += right_canine_shape;
                render = lerp(render, mouth_color, eye_bag_shape * 0.25);
                render = clamp(render, 0.0, 1.0);

                float alpha = clamp(smoke_shape + body_shape + right_eye_shape, 0.0, 1.0);

                return float4(render, alpha);
            }
            ENDHLSL
        }
    }
}
