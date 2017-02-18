Shader "Hidden/Volumetric Fog" {
Properties {
	_Color1("Fog Color 1", Color) = (.7, .7, .7, 1)
	_Color2("Fog Color 2", Color) = (.7, .7, .7, 1)
	//_MainTex ("Base (RGB)", 2D) = "black" {}
	_Noise ("3D Noise", 3D) = "black" {}
	[Space]
	_Rays ("Rays", Range(1, 512)) = 32
	_MaxDistance ("MaxDistance", Range(0.01, 10000.0)) = 500
	_NearWeight ("Near Weight", Range(0.0, 1.0)) = .5
    _LightRays ("Light Samples", Range(1, 32)) = 16
    _LightDistance ("Light Distance", Range(0.01, 1000.0)) = 200
	//_StepSize ("Step Size", Range(0.01, 50.0)) = .25

	[Space]
	_Cutoff ("Cutoff", Range(0.0, 1.0)) = .25
	_Density ("Density", Range(0.0, 10.0)) = .25
	_Saturation ("Saturation", Range(0.0, 10.0)) = .25
	_Scale ("Scale", Range(0.0, 1.0)) = .15
	_AxisScale ("Axis Scale", Vector) = (1, 1, 1, 0)

	[Space]
    _ShadowScatter("Shadow Scattering Coeff", Range(0.005, .05)) = 0.008
    _Scatter("Scattering Coeff", Range(0.005, .05)) = 0.008
    _HGCoeff("Henyey-Greenstein", Range(0.0, 1.0)) = 0.5
    _HGAmount("Henyey-Greenstein Amount", Range(0.0, 2.0)) = 0.5
    _ShadowAmount("Shadow Amount", Range(0.0, 2.0)) = 0.5
	_Extinct ("Extinction Coeff", Range(0.01, .5)) = 0.01
}

CGINCLUDE

	#include "UnityCG.cginc"

	uniform sampler2D_float _MainTex;
	uniform sampler2D_float _CameraDepthTexture;
	uniform sampler3D _Noise;

	uniform int _Rays;
	uniform float _MaxDistance;
	uniform float _NearWeight;
	uniform int _LightRays;
	uniform float _LightDistance;

	//uniform float _StepSize;
	uniform float _Cutoff;
	uniform float _Density;
	uniform float _Saturation;
	uniform float _Scale;
	uniform float4 _AxisScale;

	uniform float _ShadowScatter;
	uniform float _ShadowAmount;
	uniform float _Scatter;
	uniform float _HGCoeff;
	uniform float _HGAmount;
	uniform float _Extinct;

	uniform float4 _MainTex_TexelSize;

	float4 _Color1;
	float4 _Color2;
	
	// for fast world space reconstruction
	uniform float4x4 _FrustumCornersWS;

	struct v2f
	{
		float4 pos : SV_POSITION;
		float2 uv : TEXCOORD0;
		float2 uv_depth : TEXCOORD1;
		float4 interpolatedRay : TEXCOORD2;
	};
	
	v2f vert (appdata_img v)
	{
		v2f o;
		half index = v.vertex.z;
		v.vertex.z = 0.1;
		o.pos = mul(UNITY_MATRIX_MVP, v.vertex);
		o.uv = v.texcoord.xy;
		o.uv_depth = v.texcoord.xy;
		
		#if UNITY_UV_STARTS_AT_TOP
		if (_MainTex_TexelSize.y < 0)
			o.uv.y = 1-o.uv.y;
		#endif				
		
		o.interpolatedRay = _FrustumCornersWS[(int)index];
		o.interpolatedRay.w = index;
		
		return o;
	}

	float HenyeyGreenstein(float cosine)
	{
		float g2 = _HGCoeff * _HGCoeff;
		return 0.5 * (1 - g2) / pow(1 + g2 - 2 * _HGCoeff * cosine, 1.5);
	}

	float Beer(float density)
	{
		return exp(-_Extinct * density);
	}

	float BeerPowder(float depth)
	{
		return exp(-_Extinct * depth) * (1 - exp(-_Extinct * 2 * depth));
	}

	float2 NoiseAtPoint(float3 pos)
	{
		float3 value = tex3D(_Noise, pos * .00075 * _Scale * _AxisScale.xyz).rgb;
		float cutoff = _Cutoff * (.5 + .5 * value.b);
		value.x = saturate((value.x - cutoff) * (1.0 - cutoff));
		value.x *= value.x;
		//value.x *= ;
		return value.rg;
		//return tex3D(_Noise, pos * .001 * _Scale.xyz).rg;
	}

	float LightMarch(float3 pos, float densityMultiplier)
	{
		float3 light = _WorldSpaceLightPos0.xyz;
		int lightRays = min(_LightRays, 32);

		//float3 lightStep = _LightDistance / lightRays / _Rays * light;
		float invLightRays = 1.0 / lightRays;
		//float invRays = 256.0 / _Rays;
		float3 lightStep = _LightDistance / lightRays * light;

		pos += lightStep;

		float depth = 0.0;

		UNITY_LOOP for (int s = 0; s < lightRays; s++)
		{
			depth += (NoiseAtPoint(pos)) * invLightRays;
			//depth += (NoiseAtPoint(pos) - _Cutoff) * invLightRays;
			pos += lightStep;
		}
		
		return BeerPowder(depth);
	}

	float ShadowMarch(float3 pos, float densityMultiplier)
	{
		float3 light = -_WorldSpaceLightPos0.xyz;
		int lightRays = min(_LightRays, 32);

		//float3 lightStep = _LightDistance / lightRays / _Rays * light;
		float invLightRays = 1.0 / lightRays;
		//float invRays = 256.0 / _Rays;
		float3 lightStep = _LightDistance / lightRays * light;

		pos += lightStep;

		float depth = 0.0;

		UNITY_LOOP for (int s = 0; s < lightRays; s++)
		{
			depth += (NoiseAtPoint(pos)) * invLightRays;
			//depth += (NoiseAtPoint(pos) - _Cutoff) * invLightRays;
			pos += lightStep;
		}

		return BeerPowder(depth);
	}

	float4 ComputeFog (v2f i) : SV_Target
	{
		float4 sceneColor = tex2D(_MainTex, UnityStereoTransformScreenSpaceTex(i.uv));
		
		// Reconstruct world space position & direction
		// towards this screen pixel.
		float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(i.uv_depth));
		float dpth = Linear01Depth(rawDepth);
		float4 wsDir = dpth * i.interpolatedRay;
		float3 normalizedDir = normalize(i.interpolatedRay);
		float3 wsPos = _WorldSpaceCameraPos.xyz + wsDir.xyz;

		float3 light = _WorldSpaceLightPos0.xyz;
		float ldot = abs(dot(normalizedDir, light));
		//ldot *= ldot;
		//ldot = 1.0 - (1.0 - ldot) * (1.0 - ldot);
		//float ldot = dot(normalizedDir, light);
		float hg = HenyeyGreenstein(ldot);
		//hg = pow(hg, .5);

		float depth = dpth * _ProjectionParams.z;
		depth = (dpth < .99) ? min(depth, _MaxDistance) : _MaxDistance;

		//int rayCount = min(_Rays, 512);

		float invRays = 1.0 / _Rays;

		float3 startPos = _WorldSpaceCameraPos.xyz + normalizedDir * _ProjectionParams.y;
		float3 position = startPos;
		float fogDepth = 0.0;
		float densityMultiplier = _Density * 128.0 / _Rays;

		float stepSize = depth / _Rays;
		float3 rayStep = normalizedDir * stepSize;
		float4 fogColor = 0.0;
		//fixed4 fogColor = 0.0;


		UNITY_LOOP for (int i = 0; i < _Rays; i++)
		{
			float2 noise = NoiseAtPoint(position);
			if (noise.x > 0.0)
			{
				float beerPowder = BeerPowder(fogDepth);
				float lightMarch = LightMarch(position, densityMultiplier) * fogDepth * 256.0 * invRays * beerPowder;
				float scatter = _Scatter * hg * lightMarch;
				fogColor += scatter * _HGAmount;
				fogColor -= _ShadowScatter * (1.0 - hg) * lightMarch * _ShadowAmount;
				//fogColor -= fogDepth * _ShadowScatter * (1.0 - hg) * ShadowMarch(position, densityMultiplier) * beerPowder * 256.0 * invRays;
				//fogColor -= fogDepth * _ShadowScatter * (1.0 - hg) * ShadowMarch(position, densityMultiplier) * BeerPowder(fogDepth) * 256.0 * invRays;
				//fogColor += _Color * scatter * BeerPowder(fogDepth);
				//fogColor += _Color * BeerPowder(fogDepth);
				fogDepth += noise.x * densityMultiplier;
				if (beerPowder * densityMultiplier < 1.0)
				{
					//fogColor += lerp(_Color1, _Color2, noiseAtPoint.y) * density * densityMultiplier * _Saturation * .025 * LightMarch(position, densityMultiplier);
					//fogColor += lerp(_Color1, _Color2, noise.y) * noise.x * densityMultiplier * _Saturation * .025 * Beer(fogDepth);
					fogColor += lerp(_Color1, _Color2, noise.y) * noise.x * densityMultiplier * _Saturation * .025 * beerPowder;
				}
			}

			float dist = (i * invRays);
			dist = lerp(dist, dist * dist, _NearWeight);
			dist *= depth;
			position = startPos + normalizedDir * dist;
			//position += rayStep;
		}

		//fogDepth = saturate(fogDepth);

		fogColor += Beer(fogDepth) * sceneColor;
		return fogColor;

		//return lerp(_Color, sceneColor, Beer(fogDepth));
		//return lerp(fogColor, sceneColor, Beer(fogDepth));
	}

ENDCG

SubShader
{
	ZTest Always Cull Off ZWrite Off Fog { Mode Off }

	Pass
	{
		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag
		half4 frag (v2f i) : SV_Target { return ComputeFog (i); }
		ENDCG
	}
}

Fallback off

}
