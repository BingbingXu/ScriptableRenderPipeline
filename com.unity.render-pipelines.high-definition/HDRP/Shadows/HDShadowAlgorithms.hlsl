// Various shadow algorithms
// There are two variants provided, one takes the texture and sampler explicitly so they can be statically passed in.
// The variant without resource parameters dynamically accesses the texture when sampling.

#ifdef PUNCTUAL_SHADOW_LOW
#define PUNCTUAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp) SampleShadow_PCF_Tent_5x5(_ShadowAtlasSize.zwxy, posTC, sampleBias, tex, samp)
#elif PUNCTUAL_SHADOW_MEDIUM
#define PUNCTUAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp) SampleShadow_PCF_Tent_7x7(_ShadowAtlasSize.zwxy, posTC, sampleBias, tex, samp)
#else // PUNCTUAL_SHADOW_HIGH
#define PUNCTUAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp) SampleShadow_PCSS(posTC, sd.shadowMapSize.xy * _ShadowAtlasSize.zw, sd.atlasOffset, sampleBias, sd.shadowFilterParams0.x, asint(sd.shadowFilterParams0.y), asint(sd.shadowFilterParams0.z), tex, samp, s_point_clamp_sampler)
#endif

#ifdef DIRECTIONAL_SHADOW_LOW
#define DIRECTIONAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp) SampleShadow_PCF_Tent_5x5(_ShadowAtlasSize.zwxy, posTC, sampleBias, tex, samp)
#elif DIRECTIONAL_SHADOW_MEDIUM
#define DIRECTIONAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp) SampleShadow_PCF_Tent_7x7(_ShadowAtlasSize.zwxy, posTC, sampleBias, tex, samp)
#else // DIRECTIONAL_SHADOW_HIGH
#define DIRECTIONAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp) SampleShadow_PCSS(posTC, sd.shadowMapSize.xy * _ShadowAtlasSize.zw, sd.atlasOffset, sampleBias, sd.shadowFilterParams0.x, asint(sd.shadowFilterParams0.y), asint(sd.shadowFilterParams0.z), tex, samp, s_point_clamp_sampler)
#endif

real4 EvalShadow_WorldToShadow(HDShadowData sd, real3 positionWS, bool perspProj)
{
    // Note: Due to high VGRP load we can't use the whole view projection matrix, instead we reconstruct it from
    // rotation, position and projection vectors (projection and position are stored in SGPR)
#if 0
    return mul(viewProjection, real4(positionWS, 1));
#else
    if( perspProj )
    {
        positionWS = positionWS - sd.pos;
        float3x3 view = { sd.rot0, sd.rot1, sd.rot2 };
        positionWS = mul( view, positionWS );
    }
    else
    {
        float3x4 view;
        view[0] = float4( sd.rot0, sd.pos.x );
        view[1] = float4( sd.rot1, sd.pos.y );
        view[2] = float4( sd.rot2, sd.pos.z );
        positionWS = mul( view, float4( positionWS, 1.0 ) ).xyz;
    }

    float4x4 proj;
    proj = 0.0;
    proj._m00 = sd.proj[0];
    proj._m11 = sd.proj[1];
    proj._m22 = sd.proj[2];
    proj._m23 = sd.proj[3];
    if( perspProj )
        proj._m32 = -1.0;
    else
        proj._m33 = 1.0;

    return mul( proj, float4( positionWS, 1.0 ) );
#endif
}

// function called by spot, point and directional eval routines to calculate shadow coordinates
real3 EvalShadow_GetTexcoordsAtlas(HDShadowData sd, real2 shadowMapSize, real2 offset, real3 positionWS, out real3 posNDC, bool perspProj)
{
    real4 posCS = EvalShadow_WorldToShadow(sd, positionWS, perspProj);
    posNDC = perspProj ? (posCS.xyz / posCS.w) : posCS.xyz;
    // calc TCs
    real3 posTC = real3(posNDC.xy * 0.5 + 0.5, posNDC.z);
    posTC.xy = posTC.xy * shadowMapSize * _ShadowAtlasSize.zw + offset;

    return posTC;
}

real3 EvalShadow_GetTexcoordsAtlas(HDShadowData sd, real2 shadowMapSize, real2 offset, real3 positionWS, bool perspProj)
{
    real3 ndc;
    return EvalShadow_GetTexcoordsAtlas(sd, shadowMapSize, offset, positionWS, ndc, perspProj);
}

real2 EvalShadow_GetTexcoordsAtlas(HDShadowData sd, real2 shadowMapSize, real2 offset, real2 shadowmapSize, real2 shadowmapSizeRcp, real3 positionWS, out real2 closestSampleNDC, bool perspProj)
{
    real4 posCS = EvalShadow_WorldToShadow(sd, positionWS, perspProj);
    real2 posNDC = perspProj ? (posCS.xy / posCS.w) : posCS.xy;
    // calc TCs
    real2 posTC = posNDC * 0.5 + 0.5;
    closestSampleNDC = (floor(posTC * shadowmapSize) + 0.5) * shadowmapSizeRcp * 2.0 - 1.0.xx;
    return posTC * shadowMapSize * _ShadowAtlasSize.zw + offset;
}

uint2 EvalShadow_GetIntTexcoordsAtlas(HDShadowData sd, real2 shadowMapSize, real2 offset, real2 shadowmapSize, real2 shadowmapSizeRcp, real2 atlasSize, real3 positionWS, out real2 closestSampleNDC, bool perspProj)
{
    real2 texCoords = EvalShadow_GetTexcoordsAtlas(sd, shadowMapSize, offset, shadowmapSize, shadowmapSizeRcp, positionWS, closestSampleNDC, perspProj);
    return uint2(texCoords * atlasSize.xy);
}

//
//  Biasing functions
//

// helper function to get the world texel size
real EvalShadow_WorldTexelSize(real4 viewBias, real L_dist, bool perspProj)
{
    return perspProj ? (viewBias.w * L_dist) : viewBias.w;
}

// used to scale down view biases to mitigate light leaking across shadowed corners
#if SHADOW_USE_VIEW_BIAS_SCALING != 0
real EvalShadow_ReceiverBiasWeightFlag(int flag)
{
    return (flag & HDSHADOWFLAG_EDGE_LEAK_FIXUP) ? 1.0 : 0.0;
}

bool EvalShadow_ReceiverBiasWeightUseNormalFlag(int flag)
{
    return (flag & HDSHADOWFLAG_EDGE_TOLERANCE_NORMAL) ? true : false;
}

real3 EvalShadow_ReceiverBiasWeightPos(real3 positionWS, real3 normalWS, real3 L, real worldTexelSize, real tolerance, bool useNormal)
{
#if SHADOW_USE_ONLY_VIEW_BASED_BIASING != 0
    return positionWS + L * worldTexelSize * tolerance;
#else
    return positionWS + (useNormal ? normalWS : L) * worldTexelSize * tolerance;
#endif
}

real EvalShadow_ReceiverBiasWeight(HDShadowData sd, real2 shadowMapSize, real2 offset, real4 viewBias, real edgeTolerance, int flags, Texture2D tex, SamplerComparisonState samp, real3 positionWS, real3 normalWS, real3 L, real L_dist, bool perspProj)
{
    real3 pos = EvalShadow_ReceiverBiasWeightPos(positionWS, normalWS, L, EvalShadow_WorldTexelSize(viewBias, L_dist, perspProj), edgeTolerance, EvalShadow_ReceiverBiasWeightUseNormalFlag(flags));
    return lerp(1.0, SAMPLE_TEXTURE2D_SHADOW(tex, samp, EvalShadow_GetTexcoordsAtlas(sd, shadowMapSize, offset, pos, perspProj)).x, EvalShadow_ReceiverBiasWeightFlag(flags));
}

real EvalShadow_ReceiverBiasWeight(Texture2D tex, SamplerState samp, real3 positionWS, real3 normalWS, real3 L, real L_dist, bool perspProj)
{
    // only used by PCF filters
    return 1.0;
}
#else // SHADOW_USE_VIEW_BIAS_SCALING != 0
real EvalShadow_ReceiverBiasWeight(Texture2D tex, SamplerComparisonState samp, real3 positionWS, real3 normalWS, real3 L, real L_dist, bool perspProj)                              { return 1.0; }
real EvalShadow_ReceiverBiasWeight (Texture2D tex, SamplerState samp, real3 positionWS, real3 normalWS, real3 L, real L_dist, bool perspProj)                                        { return 1.0; }
#endif // SHADOW_USE_VIEW_BIAS_SCALING != 0


// receiver bias either using the normal to weight normal and view biases, or just light view biasing
real3 EvalShadow_ReceiverBias(real4 viewBias, real3 normalBias, real3 positionWS, real3 normalWS, real3 L, real L_dist, real lightviewBiasWeight, bool perspProj)
{
#if SHADOW_USE_ONLY_VIEW_BASED_BIASING != 0 // only light vector based biasing
    real viewBiasScale = viewBias.z;
    return positionWS + L * viewBiasScale * lightviewBiasWeight * EvalShadow_WorldTexelSize(viewBias, L_dist, perspProj);
#else // biasing based on the angle between the normal and the light vector
    real viewBiasMin   = viewBias.x;
    real viewBiasMax   = viewBias.y;
    real viewBiasScale = viewBias.z;
    real normalBiasMin   = normalBias.x;
    real normalBiasMax   = normalBias.y;
    real normalBiasScale = normalBias.z;

    real  NdotL       = dot(normalWS, L);
    real  sine        = sqrt(saturate(1.0 - NdotL * NdotL));
    real  tangent     = abs(NdotL) > 0.0 ? (sine / NdotL) : 0.0;
           sine        = clamp(sine    * normalBiasScale, normalBiasMin, normalBiasMax);
           tangent     = clamp(tangent * viewBiasScale * lightviewBiasWeight, viewBiasMin, viewBiasMax);
    real3 view_bias   = L        * tangent;
    real3 normal_bias = normalWS * sine;
    return positionWS + (normal_bias + view_bias) * EvalShadow_WorldTexelSize(viewBias, L_dist, perspProj);
#endif
}

// Reimplement SHADOW_USE_SAMPLE_BIASING
// sample bias used by wide PCF filters to offset individual taps
real2 EvalShadow_SampleBias_Persp(real3 positionWS, real3 normalWS, real3 tcs) { return 0.0.xx; }
real2 EvalShadow_SampleBias_Ortho(real3 normalWS)                                { return 0.0.xx; }


//
//  Point shadows
//
real EvalShadow_PunctualDepth(HDShadowData sd, Texture2D tex, SamplerComparisonState samp, real3 positionWS, real3 normalWS, real3 L, real L_dist)
{
    /* bias the world position */
    real recvBiasWeight = EvalShadow_ReceiverBiasWeight(sd, sd.shadowMapSize.xy, sd.atlasOffset, sd.viewBias, sd.shadowFilterParams0.x, sd.flags, tex, samp, positionWS, normalWS, L, L_dist, true);
    positionWS = EvalShadow_ReceiverBias(sd.viewBias, sd.normalBias, positionWS, normalWS, L, L_dist, recvBiasWeight, true);
    /* get shadowmap texcoords */
    real3 posTC = EvalShadow_GetTexcoordsAtlas(sd, sd.shadowMapSize.xy, sd.atlasOffset, positionWS, true);
    /* get the per sample bias */
    real2 sampleBias = EvalShadow_SampleBias_Persp(positionWS, normalWS, posTC);
    /* sample the texture */
    return PUNCTUAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp);
}

//
//  Directional shadows (cascaded shadow map)
//

#define kMaxShadowCascades 4

int EvalShadow_GetSplitIndex(HDShadowContext shadowContext, int index, real3 positionWS, out real alpha, out int cascadeCount)
{
    int   i = 0;
    real  relDistance = 0.0;
    real3 wposDir, splitSphere;

    HDShadowData sd = shadowContext.shadowDatas[index];
    HDDirectionalShadowData dsd = shadowContext.directionalShadowData;

    // find the current cascade
    for (; i < kMaxShadowCascades; i++)
    {
        real4  sphere  = dsd.sphereCascades[i];
                wposDir = -sphere.xyz + positionWS;
        real   distSq  = dot(wposDir, wposDir);
        relDistance = distSq / sphere.w;
        if (relDistance > 0.0 && relDistance <= 1.0)
        {
            splitSphere = sphere.xyz;
            wposDir    /= sqrt(distSq);
            break;
        }
    }
    int shadowSplitIndex = i < kMaxShadowCascades ? i : -1;

    real3 cascadeDir = dsd.cascadeDirection.xyz;
    cascadeCount     = dsd.cascadeDirection.w;
    real border      = dsd.cascadeBorders[shadowSplitIndex];
          alpha      = border <= 0.0 ? 0.0 : saturate((relDistance - (1.0 - border)) / border);
    real  cascDot    = dot(cascadeDir, wposDir);
          alpha      = lerp(alpha, 0.0, saturate(-cascDot * 4.0));

    return shadowSplitIndex;
}

void LoadDirectionalShadowDatas(inout HDShadowData sd, HDShadowContext shadowContext, int index)
{
    sd.proj = shadowContext.shadowDatas[index].proj;
    sd.pos = shadowContext.shadowDatas[index].pos;
    sd.viewBias = shadowContext.shadowDatas[index].viewBias;
    sd.atlasOffset = shadowContext.shadowDatas[index].atlasOffset;
}

real EvalShadow_CascadedDepth_Blend(HDShadowContext shadowContext, Texture2D tex, SamplerComparisonState samp, real3 positionWS, real3 normalWS, int index, real3 L)
{
    real alpha;
    int  cascadeCount;
    int  shadowSplitIndex = EvalShadow_GetSplitIndex(shadowContext, index, positionWS, alpha, cascadeCount);

    if (shadowSplitIndex < 0)
        return 0.0;

    HDShadowData sd = shadowContext.shadowDatas[index];
    LoadDirectionalShadowDatas(sd, shadowContext, index + shadowSplitIndex);

    /* normal based bias */
    real3 orig_pos = positionWS;
    real recvBiasWeight = EvalShadow_ReceiverBiasWeight(sd, sd.shadowMapSize.xy, sd.atlasOffset, sd.viewBias, sd.shadowFilterParams0.x, sd.flags, tex, samp, positionWS, normalWS, L, 1.0, false);
    positionWS = EvalShadow_ReceiverBias(sd.viewBias, sd.normalBias, positionWS, normalWS, L, 1.0, recvBiasWeight, false);

    /* get shadowmap texcoords */
    real3 posTC = EvalShadow_GetTexcoordsAtlas(sd, sd.shadowMapSize.xy, sd.atlasOffset, positionWS, false);
    /* evalute the first cascade */
    real2 sampleBias = EvalShadow_SampleBias_Ortho(normalWS);
    real  shadow     = DIRECTIONAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp);
    real  shadow1    = 1.0;

    shadowSplitIndex++;
    if (shadowSplitIndex < cascadeCount)
    {
        shadow1 = shadow;

        if (alpha > 0.0)
        {
            LoadDirectionalShadowDatas(sd, shadowContext, index + shadowSplitIndex);
            positionWS = EvalShadow_ReceiverBias(sd.viewBias, sd.normalBias, orig_pos, normalWS, L, 1.0, recvBiasWeight, false);
            real3 posNDC;
            posTC = EvalShadow_GetTexcoordsAtlas(sd, sd.shadowMapSize.xy, sd.atlasOffset, positionWS, posNDC, false);
            /* sample the texture */
            sampleBias = EvalShadow_SampleBias_Ortho(normalWS);

            UNITY_BRANCH
            if (all(abs(posNDC.xy) <= (1.0 - sd.shadowMapSize.zw * 0.5)))
                shadow1 = DIRECTIONAL_FILTER_ALGORITHM(sd, posTC, sampleBias, tex, samp);
        }
    }
    shadow = lerp(shadow, shadow1, alpha);
    return shadow;
}

real EvalShadow_hash12(real2 pos)
{
    real3 p3  = frac(pos.xyx * real3(443.8975, 397.2973, 491.1871));
           p3 += dot(p3, p3.yzx + 19.19);
    return frac((p3.x + p3.y) * p3.z);
}

#if 1
real EvalShadow_SampleClosestDistance_Punctual(HDShadowData sd, Texture2D tex, SamplerState sampl, real3 positionWS, real3 L, real3 lightPositionWS)
{
    real4 closestNDC = { 0,0,0,1 };
    real2 texelIdx = EvalShadow_GetTexcoordsAtlas(sd, sd.shadowMapSize.xy, sd.atlasOffset, sd.shadowMapSize.xy, sd.shadowMapSize.zw, positionWS, closestNDC.xy, true);

    // sample the shadow map
    closestNDC.z = SAMPLE_TEXTURE2D_LOD(tex, sampl, texelIdx, 0).x;

    // reconstruct depth position
    real4 closestWS = mul(closestNDC, sd.shadowToWorld);
    real3 occluderPosWS = closestWS.xyz / closestWS.w;

    return distance(occluderPosWS, lightPositionWS);
}
#else
real EvalShadow_SampleClosestDistance_Punctual(HDShadowData sd, Texture2D tex, SamplerState sampl, real3 positionWS, real3 L, real3 lightPositionWS)
{
    real4 closestNDC = { 0,0,0,1 };
    real2 texelIdx = EvalShadow_GetTexcoordsAtlas(sd, sd.shadowMapSize.xy, sd.atlasOffset, sd.shadowMapSize.xy, sd.shadowMapSize.zw, positionWS, closestNDC.xy, true);

    // sample the shadow map
    real depth = SAMPLE_TEXTURE2D_LOD(tex, sampl, texelIdx, 0).x;

    real2 a = closestNDC.xy;

    // zBufferParam = { (f-n)/n, 1, (f-n)/n*f, 1/f }
    return length(real3(a, LinearEyeDepth(depth, sd.zBufferParam)));
}
#endif

// We don't use this for now, see if it will be useful for the future
/*real3 EvalShadow_GetClosestSample_Cascade(HDShadowContext shadowContext, Texture2D tex, real3 positionWS, real3 normalWS, int index, real4 L)
{
    // load the right shadow data for the current face
    real alpha;
    int  cascadeCount;
    int  shadowSplitIndex = EvalShadow_GetSplitIndex(shadowContext, index, positionWS, alpha, cascadeCount);

    if (shadowSplitIndex < 0)
        return 0.0;

    HDShadowData sd = shadowContext.shadowDatas[index + shadowSplitIndex];

    real4 closestNDC = { 0,0,0,1 };
    uint2 texelIdx = EvalShadow_GetIntTexcoordsAtlas(sd.viewProjection, sd.scaleOffset, sd.shadowMapSize.xy, sd.shadowMapSize.zw, sd.textureSize.xy, positionWS, closestNDC.xy, false);

    // load the texel
    closestNDC.z = LOAD_TEXTURE2D_LOD(tex, texelIdx, 0).x;

    // reconstruct depth position
    real4 closestWS = mul(closestNDC, sd.shadowToWorld);
    return closestWS.xyz / closestWS.w;
}

real EvalShadow_SampleClosestDistance_Cascade(HDShadowContext shadowContext, Texture2D tex, SamplerState sampl,
                                               real3 positionWS, real3 normalWS, int index, real4 L, out real3 nearPlanePositionWS)
{
    real alpha;
    int  cascadeCount;
    int shadowSplitIndex = EvalShadow_GetSplitIndex(shadowContext, index, positionWS, alpha, cascadeCount);
    
    HDShadowData sd = shadowContext.shadowDatas[index + shadowSplitIndex];

    real4 closestNDC = { 0,0,0,1 };
    real4 scaleOffset = real4(sd.shadowMapSize.xy * _ShadowAtlasSize.zw, sd.atlasOffset);
    real2 texelIdx = EvalShadow_GetTexcoordsAtlas(shadowContext, index, scaleOffset, sd.shadowMapSize.xy, sd.shadowMapSize.zw, positionWS, closestNDC.xy, false);

    // sample the shadow map
    closestNDC.z = SAMPLE_TEXTURE2D_LOD(tex, sampl, texelIdx, 0).x;

    // reconstruct depth position
    real4 closestWS = mul(closestNDC, sd.shadowToWorld);
    real3 occluderPosWS = closestWS.xyz / closestWS.w;

    // TODO: avoid the matrix multiplication here.
    real4 nearPlanePos = mul(real4(0,0,1,1), sd.shadowToWorld); // Note the reversed Z
    nearPlanePositionWS = nearPlanePos.xyz / nearPlanePos.w;

    return distance(occluderPosWS, nearPlanePositionWS);
}
*/