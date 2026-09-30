# GastlyFace Shader 技术文档

本文档解释 `Assets/Shaders/GastlyFace.shader` 的实现逻辑。该 shader 由 Godot 4 spatial shader 逐行移植为 **Unity 6 (URP 17)** 的手写 HLSL unlit 透明 shader，在 GPU 上用纯数学公式程序化绘制一张会动的"耿鬼脸"：深紫色烟雾中浮现出身体、双眼、瞳孔、红嘴、獠牙和眼晕，整体随时间飘动。

---

## 目录

1. [整体架构](#1-整体架构)
2. [Godot → Unity 的关键转换](#2-godot--unity-的关键转换)
3. [逐行解释：顶点着色器](#3-逐行解释顶点着色器)
4. [逐行解释：形状函数](#4-逐行解释形状函数)
5. [逐行解释：片元着色器（合成逻辑）](#5-逐行解释片元着色器合成逻辑)
6. [使用方法与已知注意事项](#6-使用方法与已知注意事项)

---

## 1. 整体架构

```
┌─────────────────────────────────────────────────────┐
│ 片元着色器 (每个像素执行一次)                          │
│                                                     │
│  UV (0~1) ──加上呼吸偏移 s1──> 形状空间坐标 p          │
│                                                     │
│  p ──┬─ body()          身体圆        (0/1)         │
│      ├─ left/right_eye()  眼白椭圆     (0/1)         │
│      ├─ left/right_pupil() 瞳孔        (0/1)         │
│      ├─ mouth()           嘴 (环形)     (0/1)         │
│      ├─ left/right_canine() 獠牙       (0/1)         │
│      ├─ eye_bag()         眼下红晕      (0/1)         │
│      └─ smoke()           烟雾轮廓      (0/1)         │
│                    │                                 │
│                    ▼                                 │
│        分层合成 (加法/乘法/mix) ──> 颜色 render        │
│        smoke + body + right_eye ──> alpha            │
└─────────────────────────────────────────────────────┘
```

核心思路是 **SDF 式判定**：每个部件是一个函数，输入像素在 0~1 UV 空间中的坐标 `p`，输出 0 或 1（在形状内 / 形状外）。椭圆判定的通用形式：

```hlsl
// 椭圆方程: (x/a)² + (y/b)² < 1 时点在椭圆内部
float q = float((x*x)/(vx*vx) + (y*y)/(vy*vy)) > r);
```

`TIME`（Unity 中为 `_Time.y`）驱动两类动画：

| 动画 | 公式 | 效果 |
|---|---|---|
| 脸部呼吸/眨眼 | `s1 = sin(0.5 + t*10)*0.1`，`s2 = sin(t*10)*0.1` | 整体上下轻微浮动、眼睛沿斜线开合 |
| 瞳孔缩放 | `max(r, t*0.0004)` | 瞳孔随时间缓慢变大 |
| 烟雾流动 | 噪声图按 `(-t, t)` 方向滚动采样 | 烟雾轮廓持续向右上飘 |

---

## 2. Godot → Unity 的关键转换

### 2.1 渲染模式

| Godot | Unity 6 (URP) |
|---|---|
| `shader_type spatial` + `render_mode unshaded` | 单 Pass unlit（`LightMode = UniversalForward`），不做任何光照，直接输出 `SV_Target` |
| `ALBEDO = render` | `float4(render, alpha)` 的 RGB 分量 |
| `ALPHA = alpha`（非 0 即触发透明管线） | `Blend SrcAlpha OneMinusSrcAlpha` + `ZWrite Off` + `Queue = Transparent` |

### 2.2 时间

Godot 的 `TIME` 是秒数。Unity 的 `_Time` 是四分量向量，**只有 `_Time.y` 是秒数**（`_Time.x` 是 t/20，用错会导致动画快 20 倍）：

```hlsl
float t = _Time.y * 0.25;   // 对应 Godot: float t = TIME * 0.25;
```

### 2.3 UV 方向（最关键的一处）

- Godot spatial shader 的 UV 是 **y 向下**（(0,0) 在左上角），所以原代码用 `1.0 - UV.y` 翻转成 "y 向上" 的形状空间（翻转后 `p.y` 越大越靠上，眼睛 y=0.54 在嘴 y=0.49 之上，符合脸的布局）。
- Unity Quad 的 UV **本来就是 y 向上**（(0,0) 在左下角），因此移植时**去掉了 `1.0 -` 翻转**：

```hlsl
// Godot 原版: vec2 uv = vec2(UV.x, (1.0 - UV.y) + s1);
float2 uv = float2(IN.uv.x, IN.uv.y + s1);
```

> ⚠️ 如果把这个 shader 套到 UV 方向不同的网格上（例如从 Godot/DCC 导入的模型），脸会上下颠倒，需要把 `1.0 -` 翻转加回来。

### 2.4 其他 API 映射

| Godot | Unity |
|---|---|
| `texture(tex, uv)` | `SAMPLE_TEXTURE2D(tex, sampler_tex, uv)` |
| `mix(a, b, k)` | `lerp(a, b, k)` |
| `vec2/vec3/vec4` | `float2/float3/float4` |
| `source_color` 提示 | 不需要——噪声图只取 `.r` 通道做数据用，与颜色空间无关 |
| — | `_MainTex_ST` 放入 `UnityPerMaterial` CBUFFER，兼容 SRP Batcher |

### 2.5 对噪声纹理的要求

噪声按 `UV + (-t, t)` 滚动采样，UV 会越出 0~1 范围，因此纹理导入设置 **Wrap Mode 必须为 Repeat**，且纹理本身必须**无缝可平铺**（工程中的 `Assets/Textures/SmokeNoise.png` 由可平铺 fBm 值噪声生成，边缘差 ≈ 0.2/255）。

---

## 3. 逐行解释：顶点着色器

```hlsl
struct Attributes
{
    float4 positionOS : POSITION;   // 物体空间顶点位置
    float2 uv         : TEXCOORD0;  // 第一套 UV（Quad 上为 0~1）
};

struct Varyings
{
    float4 positionHCS : SV_POSITION;  // 裁剪空间位置（光栅化用）
    float2 uv          : TEXCOORD0;    // 传给片元的 UV
};

Varyings vert(Attributes IN)
{
    Varyings OUT;
    // 物体空间 → 世界空间 → 视空间 → 裁剪空间，一步完成
    OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
    // TRANSFORM_TEX 应用材质的 Tiling/Offset（_MainTex_ST）
    OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex);
    return OUT;
}
```

顶点阶段没有任何形变（Godot 原版的 `vertex()` 也是空的），只负责坐标变换和 UV 传递。

---

## 4. 逐行解释：形状函数

以下所有函数共享同一约定：输入 `p` 是形状空间坐标（y 向上），返回 0 或 1 表示"该像素是否属于此部件"。所有偏心坐标 `o`、半径 `r` 均为原始 Godot 代码中的调参值，**原样保留**。

### 4.1 `body(float2 p)` — 身体

```hlsl
const float2 o = float2(0.47, 0.48);  // 身体圆心，略偏左下
const float r  = 0.06;                 // 半径的平方阈值（注意：比较的是平方和）
float x = p.x - o.x;                   // 像素相对圆心的偏移
float y = p.y - o.y;
return float((x * x + y * y) < r);     // 标准圆判定：x²+y² < r（r 实为 r²）
```

### 4.2 `left_eye(float2 p, float t)` — 左眼白

```hlsl
const float vx = 0.9, vy = 1.0, r = 0.022;
const float2 o = float2(0.54, 0.54);              // 左眼中心（偏右上）
float q = float(((x*x)/(vx*vx) + (y*y)/vy) > r);  // ⚠️ vy 没有平方——原代码如此
bool edge = (p.y - 0.02 - t * 0.2 < p.x);          // 一条随时间移动的斜线
return edge ? q : 1.0;
```

三个要点：

1. **`(y*y)/vy` 中 vy 未平方**是原作刻意的调参结果（等效于把 y 轴半径放大 √vy 倍），移植时**不能"顺手修正"**，否则眼睛形状会变。
2. `edge` 是一条斜线（截距随 `t` 上下移动），斜线以下显示椭圆判定 `q`，斜线以上恒返回 1（该像素不属于眼白）。**效果：眼睛沿斜线开合，模拟眨眼/呼吸**。`t` 传入的是 `s2 = sin(t*10)*0.1`，所以开合是往复的。
3. 片元中会取 `1.0 - left_eye(...)`，即函数返回 0 的地方最终为白色眼白。

### 4.3 `right_eye(float2 p, float t)` — 右眼白

与左眼同构，区别只在：

```hlsl
const float2 o = float2(0.3, 0.54);           // 右眼中心（偏左上）
bool edge = (p.y < 0.2 * t + 1.0 - p.x * 1.5); // 斜率不同的另一条动斜线
```

两只眼睛的开合方向和斜率不同，产生不对称的"眨眼"效果。

### 4.4 `left_pupil / right_pupil(float2 p, float t)` — 瞳孔

```hlsl
const float vx = 1.0, vy = 4.0, r = 0.00002;
const float2 o = float2(0.516, 0.48);   // 左瞳孔中心；右瞳孔在 (0.305, 0.48)
return float(((x*x)/vx + (y*y)/(vy*vy)) > max(r, t * 0.0004));
```

- 椭圆方程里 `x²` 除以 `vx`（一次方）而非 `vx²`，再次是原作的调参怪癖，保留。
- `max(r, t * 0.0004)`：阈值随时间从 `r` 缓慢增长 → **瞳孔随时间缓慢放大**。
- 瞳孔返回 1（在椭圆外），片元中用 `render *= pupil_shape` 做乘法——瞳孔区域把之前合成的眼白色"清零"挖出黑瞳。

### 4.5 `mouth(float2 p)` — 嘴

```hlsl
const float3 o = float3(0.45, 0.49, 0.54);  // 一个 vec3 装两个中心：o.xy 主椭圆，o.z 第二椭圆的 y
float q = float(((x*x)/(vx*vx) + (y*y)/vy) > r);        // 椭圆 A 内部为 0
bool edge = (((x*x)/(1.5*1.5) + (yy*yy)/vy) > r);        // 椭圆 B（更扁）外部为 true
return edge ? q : 1.0;
```

两个椭圆相减形成**月牙环形**：只在"椭圆 A 内 && 椭圆 B 外"的月牙区域返回 0，片元取 `1.0 - mouth()` 得到红色的嘴。`o.z = 0.54` 使第二个椭圆中心下移，环的形状因此是上弦月牙。

### 4.6 `left_canine / right_canine(float2 p)` — 獠牙

```hlsl
float q   = float(...);                                  // 与 mouth 相同的椭圆 A 判定
bool edge = (((x*x)/(1.5*1.5) + (yy*yy)/vy) > r);        // 与 mouth 相同的椭圆 B 判定
bool edge_y = (p.y < 0.5);                               // 只保留下半部分
float m = float(p.y - 0.32 > abs(3.0 * p.x - 0.91));     // V 形: y > 0.32 + |3x - 0.91|
return (edge && edge_y) ? m : 0.0;
```

- 獠牙被限制在嘴的月牙环内部（`edge`）且只在下半张脸（`edge_y`）。
- `abs(k*x - c)` 构成 V 形两条边：`y - 0.32 > |3x - 0.91|` 即点在以 x=0.303 为尖、斜率 ±3 的倒 V 之下 → 一颗朝下的三角牙。
- 右獠牙参数不同（`y - 0.29 > |2.5x - 1.4|`，尖在 x=0.56），两颗牙不对称。
- 片元中直接 `render += canine_shape`（加白色）。

### 4.7 `eye_bag(float2 p)` — 眼下红晕

```hlsl
const float r = 0.022;
float x = p.x - 0.545, y = p.y - 0.525;   // 红晕小圆，位于左眼下方
float ex = p.x - 0.54, ey = p.y - 0.545;  // 以左眼中心为圆心的大圆
bool edge = ((ex*ex + ey*ey) > 0.027);    // 大圆之外才显示红晕
float q = float((x*x + y*y) > r);         // 小圆之外为 1
return edge ? q : 1.0;
```

逻辑：红晕 = "左眼周围的大圆内" 且 "更小的圆外"，即在眼睛下缘形成一圈月牙。片元中以 `mix(render, mouth_color, eye_bag * 0.25)` 混入 **25% 的嘴红色**，形成淡淡的红晕。

### 4.8 `smoke(float2 p, float n)` — 烟雾轮廓

```hlsl
float x = p.x - 0.5;
float y = p.y - 0.5;
return float(0.35 * noise + (x*x + y*y) < 0.20);
```

这是整个效果的灵魂：身体圆的判定半径被**噪声扰动**——噪声值 `n`（0~1）越大，烟雾延伸得越远（等效半径从 √0.20 缩到 √0.125 不等）。因为噪声图随 `(-t, t)` 滚动，烟雾边缘看起来在持续向右上飘动、翻卷。片元中以 `0.35 * n` 叠加进圆形判定，`n` 取自噪声图的 `.r` 通道。

---

## 5. 逐行解释：片元着色器（合成逻辑）

```hlsl
float4 frag(Varyings IN) : SV_Target
{
    float t  = _Time.y * 0.25;               // 全局时间（放慢 4 倍）
    float s1 = sin(0.5 + t * 10.0) * 0.1;    // 带相位差的正弦：整体呼吸偏移
    float s2 = sin(t * 10.0) * 0.1;          // 无相位差正弦：眼睛开合量

    // Unity Quad UV 已是 y 向上，故不再做 Godot 的 (1.0 - UV.y) 翻转
    float2 uv = float2(IN.uv.x, IN.uv.y + s1);
```

`s1` 与 `s2` 频率相同但相位差 0.5 rad：整张脸的浮动与眼睛开合不完全同步，看起来更自然。

```hlsl
    float body_shape         = body(uv);                                 // 1 = 在身体内
    float left_eye_shape     = 1.0 - left_eye(uv, s2);                   // 取反后 1 = 眼白
    float right_eye_shape    = 1.0 - right_eye(uv, s2);
    float left_pupil_shape   = left_pupil(uv, s2);                       // 1 = 瞳孔外
    float right_pupil_shape  = right_pupil(uv, s2);
    float mouth_shape        = 1.0 - mouth(uv);                          // 1 = 嘴月牙
    float left_canine_shape  = left_canine(uv);                          // 1 = 獠牙
    float right_canine_shape = right_canine(uv);
    float eye_bag_shape      = 1.0 - eye_bag(uv);                        // 1 = 红晕月牙
    float smoke_shape        = smoke(uv, SAMPLE_TEXTURE2D(_MainTex,
                                 sampler_MainTex, IN.uv + float2(-t, t)).r);
```

注意烟雾采样用的是**未加 s1 偏移的原始 UV**，这样烟雾滚动与身体呼吸各自独立。

```hlsl
    float c = 255.0;
    float3 smoke_color = float3(124.0/c, 110.0/c, 187.0/c);  // 淡紫烟雾 (124,110,187)
    float3 body_color  = float3(5.0/c,   0.0/c,  16.0/c);    // 近黑深紫身体 (5,0,16)
    float3 mouth_color = float3(255.0/c, 65.0/c, 65.0/c);    // 红色嘴/红晕 (255,65,65)

    float3 render = float3(0.0, 0.0, 0.0);
```

Godot 的颜色定义方式（`vec3(x/255)`）原样保留，方便与原版逐像素对照。

### 合成步骤（顺序很重要）

```hlsl
    // ① 烟雾 + 身体：两者并集处铺淡紫色
    render += smoke_color * clamp(smoke_shape + body_shape, 0.0, 1.0);

    // ② 身体内部替换成深紫色（mix 依据 body_shape 的 0/1）
    render *= lerp(render, body_color, body_shape);
```

第②步的写法等价于 `render = lerp(render, body_color, body_shape)`：body_shape=0 时 `lerp` 结果等于 render，乘回去不变；body_shape=1 时等于 body_color，乘回去变成深紫。**身体圆内的烟雾紫色被身体色覆盖，圆外的烟雾保留淡紫**。

```hlsl
    // ③ 眼白：加法叠白（眼睛开合区域 left_eye_shape 为 0，不加）
    render += left_eye_shape;
    render += right_eye_shape;

    // ④ 瞳孔：乘法——瞳孔处乘 0，把眼白挖成黑色
    render *= left_pupil_shape;
    render *= right_pupil_shape;

    // ⑤ 嘴：mix 混入红色（mouth_shape=1 的月牙处变红）
    render = lerp(render, mouth_color, mouth_shape);

    // ⑥ 獠牙：加法叠白
    render += left_canine_shape;
    render += right_canine_shape;

    // ⑦ 眼下红晕：只混入 25% 的嘴红色
    render = lerp(render, mouth_color, eye_bag_shape * 0.25);

    // ⑧ 收尾：加法累积可能超出 1，夹回 LDR 范围
    render = clamp(render, 0.0, 1.0);
```

```hlsl
    // alpha：烟雾 ∪ 身体 ∪ 右眼。右眼被单独加入是原作刻意为之——
    // 即使右眼漂出烟雾/身体范围，它也保持可见
    float alpha = clamp(smoke_shape + body_shape + right_eye_shape, 0.0, 1.0);

    return float4(render, alpha);
}
```

---

## 6. 使用方法与已知注意事项

### 使用步骤

1. 场景中创建一个 **Quad**（GameObject → 3D Object → Quad）。
2. 新建材质，Shader 选择 `Custom/GastlyFace`，挂到 Quad 上。
3. 将 `Assets/Textures/SmokeNoise.png` 拖到材质的 **Noise Texture** 槽位。
4. 确认该纹理的导入设置：**Wrap Mode = Repeat**（必须，否则烟雾滚动会拉丝）；建议取消勾选 sRGB（只做数据用，非必需）。

### 注意事项

- **透明排序**：shader 是标准透明混合 + `ZWrite Off`，多个透明物体之间按距离排序；如需鬼影遮挡后方物体可把 Pass 里的 `ZWrite Off` 改为 `ZWrite On`，但半透明烟雾边缘可能出现排序瑕疵。
- **背面剔除**：Pass 使用 `Cull Back`（与 Godot 默认一致），背面看不到脸；若要双面显示改为 `Cull Off`。
- **非 Quad 网格**：若网格 UV 的 y 方向与 Unity Quad 不同（如从 Godot 导入的模型），需在 `frag` 中恢复 `1.0 - uv.y` 翻转，否则脸上下颠倒。
- **动画速度**：整体节奏由 `t = _Time.y * 0.25` 的 0.25 系数控制；`s1`/`s2` 的频率（10.0）控制呼吸/眨眼快慢。
- **配色**：三个颜色常量（烟雾紫 / 身体深紫 / 嘴红）在 `frag` 开头集中定义，改色只需改这三行。

---

*文档对应 shader 版本：`Assets/Shaders/GastlyFace.shader`（2026-09-30）*
