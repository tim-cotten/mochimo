/*
 * cuda_trigg.cu  Multi-GPU CUDA Mining
 *
 * Copyright (c) 2019 by Adequate Systems, LLC.  All Rights Reserved.
 * See LICENSE.PDF   **** NO WARRANTY ****
 *
 * Date: 23 May 2019
 * Revision: 32 (final)
 *
 * The portions of this code on lines 32 through 227 are work made for hire by 
 * a Mochimo community member, and are not subject to the Mochimo License 
 * Agreement.  The remainder of this file below line 227 is subject to the 
 * license as found in LICENSE.PDF
 * 
 * -FILE NOT IN USE-
 * Effective v2.4 This File Included for Archival Purposes Only
 *    -stackoverflo
 *
 */

#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <unistd.h>

#include <cuda_runtime.h>
extern "C" {
#include "../../crypto/hash/cpu/sha256.h"
}

#include "../../config.h"

__constant__ static uint32_t __align__(8) c_midstate256[8];
__constant__ static uint32_t __align__(8) c_input32[8];
__constant__ static uint32_t __align__(8) c_blockNumber8[2];
__constant__ static uint8_t __align__(8) c_difficulty;

__constant__ static uint32_t __align__(8) c_K[64] =
{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
};

#ifdef __CUDA_ARCH__
__device__ __forceinline__ uint32_t cuda_swab32(uint32_t x)
{
    /* device */
    return __byte_perm(x, x, 0x0123);
}
#else
    /* host */
    #define cuda_swab32(x) \
    ((((x) << 24) & 0xff000000u) | (((x) << 8) & 0x00ff0000u) | \
        (((x) >> 8) & 0x0000ff00u) | (((x) >> 24) & 0x000000ffu))
#endif

#define xor3b(a,b,c) (a ^ b ^ c)
#define ROTR32(x, n) __funnelshift_r( (x), (x), (n) )

__device__ __forceinline__
uint64_t xandx(uint64_t a, uint64_t b, uint64_t c)
{
    uint64_t result;
    asm("{ // xandx \n\t"
        ".reg .u64 n;\n\t"
        "xor.b64 %0, %2, %3;\n\t"
        "and.b64 n, %0, %1;\n\t"
        "xor.b64 %0, n, %3;\n\t"
    "}\n" : "=l"(result) : "l"(a), "l"(b), "l"(c));
    return result;
}

#define AS_UINT2(addr) *((uint2*)(addr))

__device__ __forceinline__ uint32_t bsg2_0(const uint32_t x)
{
    return xor3b(ROTR32(x,2),ROTR32(x,13),ROTR32(x,22));
}

__device__ __forceinline__ uint32_t bsg2_1(const uint32_t x)
{
    return xor3b(ROTR32(x,6),ROTR32(x,11),ROTR32(x,25));
}

__device__ __forceinline__ uint32_t ssg2_0(const uint32_t x)
{
    return xor3b(ROTR32(x,7),ROTR32(x,18),(x>>3));
}

__device__ __forceinline__ uint32_t ssg2_1(const uint32_t x)
{
    return xor3b(ROTR32(x,17),ROTR32(x,19),(x>>10));
}

__device__ __forceinline__ uint32_t andor32(const uint32_t a, const uint32_t b, const uint32_t c)
{
    uint32_t result;
    asm("{\n\t"
        ".reg .u32 m,n,o;\n\t"
        "and.b32 m,  %1, %2;\n\t"
        " or.b32 n,  %1, %2;\n\t"
        "and.b32 o,   n, %3;\n\t"
        " or.b32 %0,  m, o ;\n\t"
        "}\n\t" : "=r"(result) : "r"(a), "r"(b), "r"(c)
    );
    return result;
}

__device__ __forceinline__ uint2 vectorizeswap(uint64_t v)
{
    uint2 result;
    asm("mov.b64 {%0,%1},%2; \n\t"
        : "=r"(result.y), "=r"(result.x) : "l"(v));
    return result;
}

__device__
static void sha2_step1(uint32_t a, uint32_t b, uint32_t c, uint32_t &d, uint32_t e, uint32_t f, uint32_t g, uint32_t &h,
    uint32_t in, const uint32_t Kshared)
{
    uint32_t t1,t2;
    uint32_t vxandx = xandx(e, f, g);
    uint32_t bsg21 = bsg2_1(e);
    uint32_t bsg20 = bsg2_0(a);
    uint32_t andorv = andor32(a,b,c);

    t1 = h + bsg21 + vxandx + Kshared + in;
    t2 = bsg20 + andorv;
    d = d + t1;
    h = t1 + t2;
}

__device__
static void sha2_step2(uint32_t a, uint32_t b, uint32_t c, uint32_t &d, uint32_t e, uint32_t f, uint32_t g, uint32_t &h,
    uint32_t* in, uint32_t pc, const uint32_t Kshared)
{
    uint32_t t1,t2;

    int pcidx1 = (pc-2) & 0xF;
    int pcidx2 = (pc-7) & 0xF;
    int pcidx3 = (pc-15) & 0xF;

    uint32_t inx0 = in[pc];
    uint32_t inx1 = in[pcidx1];
    uint32_t inx2 = in[pcidx2];
    uint32_t inx3 = in[pcidx3];

    uint32_t ssg21 = ssg2_1(inx1);
    uint32_t ssg20 = ssg2_0(inx3);
    uint32_t vxandx = xandx(e, f, g);
    uint32_t bsg21 = bsg2_1(e);
    uint32_t bsg20 = bsg2_0(a);
    uint32_t andorv = andor32(a,b,c);

    in[pc] = ssg21 + inx2 + ssg20 + inx0;

    t1 = h + bsg21 + vxandx + Kshared + in[pc];
    t2 = bsg20 + andorv;
    d =  d + t1;
    h = t1 + t2;
}

__device__
static void sha256_round(uint32_t* in, uint32_t* state, uint32_t* const Kshared)
{
    uint32_t a = state[0];
    uint32_t b = state[1];
    uint32_t c = state[2];
    uint32_t d = state[3];
    uint32_t e = state[4];
    uint32_t f = state[5];
    uint32_t g = state[6];
    uint32_t h = state[7];

    sha2_step1(a,b,c,d,e,f,g,h,in[ 0], Kshared[ 0]);
    sha2_step1(h,a,b,c,d,e,f,g,in[ 1], Kshared[ 1]);
    sha2_step1(g,h,a,b,c,d,e,f,in[ 2], Kshared[ 2]);
    sha2_step1(f,g,h,a,b,c,d,e,in[ 3], Kshared[ 3]);
    sha2_step1(e,f,g,h,a,b,c,d,in[ 4], Kshared[ 4]);
    sha2_step1(d,e,f,g,h,a,b,c,in[ 5], Kshared[ 5]);
    sha2_step1(c,d,e,f,g,h,a,b,in[ 6], Kshared[ 6]);
    sha2_step1(b,c,d,e,f,g,h,a,in[ 7], Kshared[ 7]);
    sha2_step1(a,b,c,d,e,f,g,h,in[ 8], Kshared[ 8]);
    sha2_step1(h,a,b,c,d,e,f,g,in[ 9], Kshared[ 9]);
    sha2_step1(g,h,a,b,c,d,e,f,in[10], Kshared[10]);
    sha2_step1(f,g,h,a,b,c,d,e,in[11], Kshared[11]);
    sha2_step1(e,f,g,h,a,b,c,d,in[12], Kshared[12]);
    sha2_step1(d,e,f,g,h,a,b,c,in[13], Kshared[13]);
    sha2_step1(c,d,e,f,g,h,a,b,in[14], Kshared[14]);
    sha2_step1(b,c,d,e,f,g,h,a,in[15], Kshared[15]);

    #pragma unroll
    for (int i=0; i<3; i++)
    {
        sha2_step2(a,b,c,d,e,f,g,h,in,0, Kshared[16+16*i]);
        sha2_step2(h,a,b,c,d,e,f,g,in,1, Kshared[17+16*i]);
        sha2_step2(g,h,a,b,c,d,e,f,in,2, Kshared[18+16*i]);
        sha2_step2(f,g,h,a,b,c,d,e,in,3, Kshared[19+16*i]);
        sha2_step2(e,f,g,h,a,b,c,d,in,4, Kshared[20+16*i]);
        sha2_step2(d,e,f,g,h,a,b,c,in,5, Kshared[21+16*i]);
        sha2_step2(c,d,e,f,g,h,a,b,in,6, Kshared[22+16*i]);
        sha2_step2(b,c,d,e,f,g,h,a,in,7, Kshared[23+16*i]);
        sha2_step2(a,b,c,d,e,f,g,h,in,8, Kshared[24+16*i]);
        sha2_step2(h,a,b,c,d,e,f,g,in,9, Kshared[25+16*i]);
        sha2_step2(g,h,a,b,c,d,e,f,in,10,Kshared[26+16*i]);
        sha2_step2(f,g,h,a,b,c,d,e,in,11,Kshared[27+16*i]);
        sha2_step2(e,f,g,h,a,b,c,d,in,12,Kshared[28+16*i]);
        sha2_step2(d,e,f,g,h,a,b,c,in,13,Kshared[29+16*i]);
        sha2_step2(c,d,e,f,g,h,a,b,in,14,Kshared[30+16*i]);
        sha2_step2(b,c,d,e,f,g,h,a,in,15,Kshared[31+16*i]);
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

__device__ int gpu_trigg_eval(uint32_t *h, uint8_t d)
{
    uint32_t *bp, n;
    for (bp = h, n = d >> 5; n; n--) {
        if (*bp++ != 0) return 0;
    }
    return __clz(*bp) >= (d & 31);
}

__constant__ static int Z_PREP[4]  = {12,13,14,15};
__constant__ static int Y_PREP[2]  = {16,17};
__constant__ static int Z_ING[16]  = {18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33};
__constant__ static int Y_ING[8]   = {34,35,36,37,38,39,40,41};
__constant__ static int X_ING[2]   = {42,43};
__constant__ static int Z_INF[16]  = {44,45,46,47,48,50,51,52,53,54,55,56,57,58,59,60};
__constant__ static int Z_ADJ[64]  = {61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,94,95,96,97,98,99,100,101,102,103,104,105,107,108,109,110,112,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128};
__constant__ static int Z_AMB[16]  = {77,94,95,96,126,214,217,218,220,222,223,224,225,226,227,228};
__constant__ static int Z_TIMED[8] = {84,243,249,250,251,252,253,255};
__constant__ static int Z_NS[64]   = {129,130,131,132,133,134,135,136,137,138,145,149,154,155,156,157,177,178,179,180,182,183,184,185,186,187,188,189,190,191,192,193,194,196,197,198,199,200,201,202,203,204,205,206,207,208,209,210,211,212,213,241,244,245,246,247,248,249,250,251,252,253,254,255};
__constant__ static int Z_NPL[32]  = {139,140,141,142,143,144,146,147,148,150,151,153,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,181};
__constant__ static int Z_MASS[16] = {214,215,216,217,218,219,220,221,222,223,224,225,226,227,228,229};
__constant__ static int Y_MASS[8]  = {230,231,232,233,234,235,236,237};
__constant__ static int X_MASS[4]  = {238,239,240,242};
__constant__ static int Z_INGINF[32] = {18,19,20,21,22,25,26,27,28,29,30,36,37,38,39,40,41,42,44,46,47,48,49,51,52,53,54,55,56,57,58,59};
__constant__ static int Z_TIME[16] = {82,83,84,85,86,87,88,243,249,250,251,252,253,254,255,253};
__constant__ static int Z_INGADJ[64] = {18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,23,24,31,32,33,34,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92};

__global__ void trigg(uint32_t threads, int *g_found, uint8_t *g_seed)
{
   const uint32_t thread = blockDim.x * blockIdx.x + threadIdx.x;
   uint8_t seed[16] = {0};
   uint32_t input[16], state[8];

   if (thread <= threads) {
      /* Frame 1 -> Split 6 ways */
      if(thread < 32768) { /* Total Permutations, this frame: 32,768 ( 1 << 15 ) */
         seed[ 0] = Z_PREP[(thread & 3)];       // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 5) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 11) & 15]; // 2^4
      } else
      if(thread < 49152) { /* Total Permutations, this frame: 16,384 ( 1 << 14 ) */
         seed[ 0] = Y_PREP[(thread & 1)];       // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 4) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 10) & 15]; // 2^4
      } else
      if(thread < 65536) { /* Total Permutations, this frame: 16,384 ( 1 << 14 ) */
         seed[ 0] = Z_PREP[(thread & 3)];       // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 5) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 11) & 7]; // 2^3
      } else
      if(thread < 73728) { /* Total Permutations, this frame: 8,192 ( 1 << 13 ) */
         seed[ 0] = Y_PREP[(thread & 1)];       // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 4) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 10) & 7]; // 2^3
      } else
      if(thread < 81920) { /* Total Permutations, this frame: 16,384 ( 1 << 13 ) */
         seed[ 0] = Z_PREP[(thread & 3)];       // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 5) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 11) & 3]; // 2^2
      } else
      if(thread < 86016) { /* Total Permutations, this frame: 8,192 ( 1 << 12 ) */
         seed[ 0] = Y_PREP[(thread & 1)];       // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 4) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 10) & 3];  // 2^2
      } else
      /* END Frame 1 */
      /* Frame 2 -> Split 3 ways */
      if(thread <= 151552) { /* Total Permutations, this frame: 65,536 (1 << 16) */
         seed[ 0] = Z_TIME[(thread & 15)];      // 2^4
         seed[ 1] = Y_MASS[(thread >> 4) & 15]; // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_INF[(thread >> 8) & 15];  // 2^4
         seed[ 4] = 9;
         seed[ 5] = 2;
         seed[ 6] = 1;
         seed[ 7] = Z_AMB[(thread >> 12) & 15]; // 2^4
      } else
      if(thread <= 184320) { /* Total Permutations, this frame: 32,768 (1 << 15) */
         seed[ 0] = Z_TIME[(thread & 15)];      // 2^4
         seed[ 1] = X_MASS[(thread >> 3) & 7];  // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_INF[(thread >> 7) & 15];  // 2^4
         seed[ 4] = 9;
         seed[ 5] = 2;
         seed[ 6] = 1;
         seed[ 7] = Z_AMB[(thread >> 11) & 15]; // 2^4
      } else
      if(thread <= 200704) { /* Total Permutations, this frame: 16,384 (1 << 14) */
         seed[ 0] = Z_TIME[(thread & 15)];      // 2^4
         seed[ 1] = Z_MASS[(thread >> 2) & 3];  // 2^2
         seed[ 2] = 1;
         seed[ 3] = Z_INF[(thread >> 6) & 15];  // 2^4
         seed[ 4] = 9;
         seed[ 5] = 2;
         seed[ 6] = 1;
         seed[ 7] = Z_AMB[(thread >> 10) & 15]; // 2^4
      } else
      /* END Frame 2 */
      /* Frame 3 -> Split 2 ways */
      if(thread < 2297856) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 )*/
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7];    // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 3346432) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 )*/
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7];    // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 4) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      /* END Frame 3 */
      /* Frame 4 -> Split 6 ways */
      if(thread < 5443584) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 6) & 3];     // 2^2
         seed[ 4] = Z_TIMED[(thread >> 8) & 7];    // 2^3
         seed[ 5] = Z_MASS[(thread >> 11) & 15];   // 2^4
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 15) & 63];    // 2^6
      } else
      if(thread < 6492160) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 6) & 1];     // 2^1
         seed[ 4] = Z_TIMED[(thread >> 7) & 7];    // 2^3
         seed[ 5] = Z_MASS[(thread >> 10) & 15];   // 2^4
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 14) & 63];    // 2^6
      } else
      if(thread < 7540736) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 6) & 3];     // 2^2
         seed[ 4] = Z_TIMED[(thread >> 8) & 7];    // 2^3
         seed[ 5] = Y_MASS[(thread >> 11) & 7];    // 2^3
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 14) & 63];    // 2^6
      } else
      if(thread < 8065024) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 6) & 1];     // 2^1
         seed[ 4] = Z_TIMED[(thread >> 7) & 7];    // 2^3
         seed[ 5] = Y_MASS[(thread >> 10) & 7];    // 2^3
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 13) & 63];    // 2^6
      } else
      if(thread < 8589312) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 6) & 3];     // 2^2
         seed[ 4] = Z_TIMED[(thread >> 8) & 7];    // 2^3
         seed[ 5] = X_MASS[(thread >> 11) & 3];    // 2^2
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 13) & 63];    // 2^6
      } else
      if(thread < 8851456) { /* Total Permutations, this frame: 262,144 ( 1 << 18 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 6) & 1];     // 2^1
         seed[ 4] = Z_TIMED[(thread >> 7) & 7];    // 2^3
         seed[ 5] = X_MASS[(thread >> 10) & 3];    // 2^2
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 12) & 63];    // 2^6
      } else
      /* END Frame 4 */
      /* Frame 5 -> Split 6 ways */
      if(thread < 13045760) { /* Total Permutations, this frame: 4,194,304 ( 1 << 22 ) */
         seed[ 0] = Z_PREP[thread & 3];            // 2^2
         seed[ 1] = Z_ADJ[(thread >> 2) & 63];     // 2^6
         seed[ 2] = Z_MASS[(thread >> 8) & 15];    // 2^4
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 12) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 17) & 31]; // 2^5
      } else
      if(thread < 15142912) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Y_PREP[thread & 1];            // 2^1
         seed[ 1] = Z_ADJ[(thread >> 1) & 63];     // 2^6
         seed[ 2] = Z_MASS[(thread >> 7) & 15];    // 2^4
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 17240064) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_PREP[thread & 3];            // 2^2
         seed[ 1] = Z_ADJ[(thread >> 2) & 63];     // 2^6
         seed[ 2] = Y_MASS[(thread >> 8) & 7];     // 2^3
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 18288640) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Y_PREP[thread & 1];            // 2^1
         seed[ 1] = Z_ADJ[(thread >> 1) & 63];     // 2^6
         seed[ 2] = Y_MASS[(thread >> 7) & 7];     // 2^3
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      if(thread < 19337216) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_PREP[thread & 3];            // 2^2
         seed[ 1] = Z_ADJ[(thread >> 2) & 63];     // 2^6
         seed[ 2] = X_MASS[(thread >> 8) & 3];     // 2^2
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      if(thread < 19861504) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = Y_PREP[thread & 1];            // 2^1
         seed[ 1] = Z_ADJ[(thread >> 1) & 63];     // 2^6
         seed[ 2] = X_MASS[(thread >> 7) & 3];     // 2^2
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 9) & 31];     // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 14) & 31]; // 2^5
      } else
      /* END Frame 5 */
      /* Frame 6 -> Split 6 ways */
      if(thread < 24055808) { /* Total Permutations, this frame: 4,194,304 ( 1 << 22 ) */
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = Z_MASS[(thread >> 2) & 15];    // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 6) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 12) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 17) & 31]; // 2^5
      } else
      if(thread < 26152960) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = Z_MASS[(thread >> 1) & 15];    // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 28250112) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = Y_MASS[(thread >> 2) & 7];     // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 29298688) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = Y_MASS[(thread >> 1) & 7];     // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 4) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      if(thread < 30347264) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = X_MASS[(thread >> 2) & 3];     // 2^2
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 30871552) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = X_MASS[(thread >> 1) & 3];     // 2^2
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 4) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      /* END Frame 6 */
      /* Frame 7 -> Split 9 ways */
      if(thread < 35065856) { /* Total Permutations, this frame: 4,194,304 ( 1 << 22 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Z_MASS[(thread >> 14) & 15];   // 2^4
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 18) & 15];    // 2^4
      } else
      if(thread < 37163088) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Y_MASS[(thread >> 14) & 7];    // 2^3
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 17) & 15];    // 2^4
      } else
      if(thread < 38211584) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = X_MASS[(thread >> 14) & 3];    // 2^2
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 16) & 15];    // 2^4
      } else
      if(thread < 40308736) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Z_MASS[(thread >> 14) & 15];   // 2^4
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 18) & 7];     // 2^3
      } else
      if(thread < 41357312) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Y_MASS[(thread >> 14) & 7];    // 2^3
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 17) & 7];     // 2^3
      } else
      if(thread < 41881600) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = X_MASS[(thread >> 14) & 3];    // 2^2
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 16) & 7];     // 2^3
      } else
      if(thread < 42405888) { /* Total Permutations, this frame: 524,288 ( 1 << 19  ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Z_MASS[(thread >> 14) & 15];   // 2^4
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 18) & 1];     // 2^1
      } else
      if(thread < 42668032) { /* Total Permutations, this frame: 262,144 ( 1 << 18 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Y_MASS[(thread >> 14) & 7];    // 2^3
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 17) & 1];     // 2^1
      } else
      if(thread < 42799104) { /* Total Permutations, this frame: 131,072 ( 1 << 17 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = X_MASS[(thread >> 14) & 3];    // 2^2
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 16) & 1];     // 2^1
      } else
      /* END Frame 7 */
      /* Frame 8 -> Split 2 ways */
      if(thread < 311234560) { /* Total Permutations, this frame: 268,435,456 ( 1 << 28 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 8) & 3];     // 2^2
         seed[ 4] = 5;
         seed[ 5] = Z_ADJ[(thread >> 10) & 63];    // 2^6
         seed[ 6] = Z_NS[(thread >> 16) & 63];     // 2^6
         seed[ 7] = 3;
         seed[ 8] = 1;
         seed[ 9] = Z_INGADJ[(thread >> 22) & 63]; // 2^6
      } else
      if(thread < 445452288) { /* Total Permutations, this frame: 134,217,728 ( 1 << 27 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 8) & 1];     // 2^1
         seed[ 4] = 5;
         seed[ 5] = Z_ADJ[(thread >> 9) & 63];     // 2^6
         seed[ 6] = Z_NS[(thread >> 15) & 63];     // 2^6
         seed[ 7] = 3;
         seed[ 8] = 1;
         seed[ 9] = Z_INGADJ[(thread >> 21) & 63]; // 2^6
      }

/* Below Two Frames are Valid, But Require 64-Bit Math: if extra entropy req'd.
   if( < thread <= ) { /* Total Permutations, this frame: 549,755,813,888
	seed[ 0] = Z_ING[(thread & 31)]; 
	seed[ 1] = Z_PREP[(thread << 5) & 7];
	seed[ 2] = Z_TIME[(thread << 8) & 15]; 
	seed[ 3] = Z_MASS[(thread << 12) & 31]; 
	seed[ 4] = 1;
        seed[ 5] = Z_MASS[(thread << 17) & 31]; 
	seed[ 6] = Z_ING[(thread << 22) & 31];  
	seed[ 7] = 3; 
	seed[ 8] = 1;
        seed[ 9] = 5; 
	seed[10] = Z_ADJ[(thread << 27) & 63];
	seed[11] = Z_NS[(thread << 33) & 63];
   }
   if( < thread <= ) { /* Total Permutations, this frame: 4,398,046,511,104
	seed[ 0] = Z_ING[(thread & 31)]; 
	seed[ 1] = Z_PREP[(thread << 5) & 7]; 
	seed[ 2] = 5; 
	seed[ 3] = Z_ADJ[(thread << 8) & 63]; 
	seed[ 4] = Z_NS[(thread << 14) & 63]; 
	seed[ 5] = 1;
        seed[ 6] = Z_MASS[(thread << 19) & 31]; 
	seed[ 7] = Z_ING[(thread << 24) & 31];  
	seed[ 8] = 3; 
	seed[ 9] = 1;
        seed[10] = 5; 
	seed[11] = Z_ADJ[(thread << 30) & 63]; 
	seed[12] = Z_NS[(thread << 36) & 63];
   }
End 64-bit Frames */

        #pragma unroll
        for (int i = 0; i < 8; i++)
        {
            input[i] = c_input32[i];
        }
        #pragma unroll
        for (int i = 0; i < 4; i++)
        {
            input[8 + i] = cuda_swab32(((uint32_t *) seed)[i]);
        }

        input[12] = cuda_swab32(c_blockNumber8[0]);
        input[13] = cuda_swab32(c_blockNumber8[1]);
        input[14] = 0x80000000;
        input[15] = 0;

        #pragma unroll
        for (int i = 0; i < 8; i += 2)
        {
            AS_UINT2(&state[i]) = AS_UINT2(&c_midstate256[i]);
        }

        sha256_round(input, state, c_K);

        #pragma unroll
        for (int i = 0; i < 15; i++)
        {
            input[i] = 0;
        }
        input[15] = 0x9c0;

        sha256_round(input, state, c_K);

        if (gpu_trigg_eval(state, c_difficulty))
        {
            *g_found = 1;
            #pragma unroll
            for (int i = 0; i < 16; i++)
            {
                g_seed[i] = seed[i];
            }
        }
    }
}

extern "C" {

typedef struct __trigg_cuda_ctx {
    byte curr_seed[16], next_seed[16];
    char cp[256], next_cp[256];
    int *found, *d_found;
    uint8_t *seed, *d_seed;
    uint32_t *midstate, *input;
    cudaStream_t stream;
} TriggCudaCTX;

TriggCudaCTX trigg_ctx[64];    /* Max 64 GPUs Supported */
int trigg_threads = 445452288;
dim3 trigg_grid(435012);
dim3 trigg_block(1024);
char nullcp = '\0';
byte *trigg_diff;
byte *trigg_bnum;
int trigg_nGPU = 0;
int32_t *trigg_found;

int trigg_init_cuda(byte difficulty, byte *blockNumber) {
    /* Obtain and check system GPU count */
    trigg_nGPU = 0;
    cudaGetDeviceCount(&trigg_nGPU);
    if(trigg_nGPU<1 || trigg_nGPU>64) return trigg_nGPU;
    /* Allocate pinned host memory */
    cudaMallocHost(&trigg_found, 4);
    cudaMallocHost(&trigg_diff, 1);
    cudaMallocHost(&trigg_bnum, 8);
    /* Copy immediate block data to pinned memory */
    *trigg_found = 0;
    memcpy(trigg_diff, &difficulty, 1);
    memcpy(trigg_bnum, blockNumber, 8);

    int i = 0;
    for ( ; i<trigg_nGPU; i++) {
        cudaSetDevice(i);
        /* Create Stream */
        cudaStreamCreate(&trigg_ctx[i].stream);
        /* Allocate device memory */
        cudaMalloc(&trigg_ctx[i].d_found, 4);
        cudaMalloc(&trigg_ctx[i].d_seed, 16);
        /* Allocate associated device-host memory */
        cudaMallocHost(&trigg_ctx[i].found, 4);
        cudaMallocHost(&trigg_ctx[i].seed, 16);
        cudaMallocHost(&trigg_ctx[i].midstate, 32);
        cudaMallocHost(&trigg_ctx[i].input, 32);
        /* Copy immediate block data to device memory */
        cudaMemcpyToSymbolAsync(c_blockNumber8, trigg_bnum, 8, 0,
                                cudaMemcpyHostToDevice, trigg_ctx[i].stream);
        cudaMemcpyToSymbolAsync(c_difficulty, trigg_diff, 1, 0,
                                cudaMemcpyHostToDevice, trigg_ctx[i].stream);
        /* Set remaining device memory */
        cudaMemsetAsync(trigg_ctx[i].d_found, 0, 4, trigg_ctx[i].stream);
        cudaMemsetAsync(trigg_ctx[i].d_seed, 0, 16, trigg_ctx[i].stream);
        /* Set initial round variables */
        trigg_ctx[i].next_cp[0] = nullcp;
    }

    return trigg_nGPU;
}

void trigg_free_cuda() {
    /* Free pinned host memory */
    cudaFreeHost(trigg_found);
    cudaFreeHost(trigg_diff);
    cudaFreeHost(trigg_bnum);

    int i = 0;
    for ( ; i<trigg_nGPU; i++) {
        cudaSetDevice(i);
        /* Destroy Stream */
        cudaStreamDestroy(trigg_ctx[i].stream);
        /* Free device memory */
        cudaFree(trigg_ctx[i].d_found);
        cudaFree(trigg_ctx[i].d_seed);
        /* Free associated device-host memory */
        cudaFreeHost(trigg_ctx[i].found);
        cudaFreeHost(trigg_ctx[i].seed);
        cudaFreeHost(trigg_ctx[i].midstate);
        cudaFreeHost(trigg_ctx[i].input);
    }
}

extern byte Tchain[32 + 256 + 16 + 8];
extern byte *trigg_gen(byte *in);
extern char *trigg_expand(byte *in);
extern char *trigg_check(byte *in, byte d, byte *bnum);

__host__ void trigg_generate_cuda(byte *mroot, word32 *hps, byte *runflag)
{
    int i;
    uint64_t lastnHaiku, nHaiku = 0;
    time_t seconds = time(NULL);
    for( ; *runflag && *trigg_found == 0; ) {
       for(i=0; i<trigg_nGPU; i++) {
           /* Prepare next seed for GPU... */
           if(trigg_ctx[i].next_cp[0] == nullcp) {
               /* ... generate first GPU seed (and expand as Haiku) */
               trigg_gen(trigg_ctx[i].next_seed);
               strcpy(trigg_ctx[i].next_cp, trigg_expand(trigg_ctx[i].next_seed));

               /* ... copy mroot to Tchain */
               memcpy(Tchain, mroot, 32);

               /* ... and prepare sha256 midstate for next round */
               SHA256_CTX sha256;
               sha256_init(&sha256);
               sha256_update(&sha256, Tchain, 256);
               memcpy(trigg_ctx[i].midstate, sha256.state, 32);
               memcpy(trigg_ctx[i].input, Tchain + 256, 32);
           }
           /* Check if GPU has finished */
           cudaSetDevice(i);
           if(cudaStreamQuery(trigg_ctx[i].stream) == cudaSuccess) {
               cudaMemcpy(trigg_found, trigg_ctx[i].d_found, 4, cudaMemcpyDeviceToHost);
               if(*trigg_found==1) { /* SOLVED A BLOCK! */
                   cudaMemcpy(trigg_ctx[i].seed, trigg_ctx[i].d_seed, 16, cudaMemcpyDeviceToHost);
                   memcpy(mroot + 32, trigg_ctx[i].curr_seed, 16);
                   memcpy(mroot + 32 + 16, trigg_ctx[i].seed, 16);
               }
               /* Send new GPU round Data */
               cudaMemcpyToSymbolAsync(c_midstate256, trigg_ctx[i].midstate, 32, 0,
                                       cudaMemcpyHostToDevice, trigg_ctx[i].stream);
               cudaMemcpyToSymbolAsync(c_input32, trigg_ctx[i].input, 32, 0,
                                       cudaMemcpyHostToDevice, trigg_ctx[i].stream);
               /* Start GPU round */
               trigg<<<trigg_grid, trigg_block, 0, trigg_ctx[i].stream>>>
                   (trigg_threads, trigg_ctx[i].d_found, trigg_ctx[i].d_seed);

               /* Add to haiku count */
               nHaiku += trigg_threads;

               /* Store round vars aside for checks next loop */
               memcpy(trigg_ctx[i].curr_seed,trigg_ctx[i].next_seed,16);
               strcpy(trigg_ctx[i].cp,trigg_ctx[i].next_cp);
               trigg_ctx[i].next_cp[0] = nullcp;
           }
       }
      
      /* Chill a bit if nothing is happening */
      if(lastnHaiku == nHaiku) usleep(1000);
      else lastnHaiku = nHaiku;
    }
    
   seconds = time(NULL) - seconds;
   if(seconds == 0) seconds = 1;
   nHaiku /= seconds;
   *hps = (word32) nHaiku;
}

}
