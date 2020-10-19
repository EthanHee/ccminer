/*!
 * cuda.cu - CUDA Mining for hs-mminer
 * Copyright (c) 2019-2020, The Handshake Developers (MIT License).
 * https://github.com/handshake-org/hs-miner
 */

//#include <host_defines.h>

#include <cuda_helper.h>
#include <miner.h>

#include <stdio.h>
#include "common.h"
#include "hnsblake2b.h"
#include "sha3.h"
#include "header.h"
#include "error.h"
#include "utils.h"

typedef unsigned char BYTE;
typedef unsigned int  HNSWORD;
typedef unsigned long long HNSLONG;


# define int64_t __int64
# define int32_t __int32
# define int16_t __int16
# define int8_t  __int8

# define uint64_t unsigned __int64
# define uint32_t unsigned __int32
# define uint16_t unsigned __int16
# define uint8_t  unsigned __int8


#define BLAKE2B_ROUNDS 12
#define BLAKE2B_BLOCK_LENGTH 128
#define BLAKE2B_CHAIN_SIZE 8
#define BLAKE2B_CHAIN_LENGTH (BLAKE2B_CHAIN_SIZE * sizeof(int64_t))
#define BLAKE2B_STATE_SIZE 16
#define BLAKE2B_STATE_LENGTH (BLAKE2B_STATE_SIZE * sizeof(int64_t))

static uint32_t* d_resNonces[MAX_GPUS] = { 0 };
static bool init[MAX_GPUS] = { 0 };

typedef struct {

	HNSWORD digestlen;

    BYTE buff[BLAKE2B_BLOCK_LENGTH];
    int64_t chain[BLAKE2B_CHAIN_SIZE];
    int64_t state[BLAKE2B_STATE_SIZE];

	HNSWORD pos;
	unsigned long long t0;
	unsigned long long t1;
	unsigned long long f0;

} cuda_blake2b_ctx_t;

typedef cuda_blake2b_ctx_t CUDA_BLAKE2B_CTX;

__constant__ CUDA_BLAKE2B_CTX c_CTX;

__constant__ HNSLONG BLAKE2B_IVS[8] = {
  0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
  0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
};

__constant__ unsigned char BLAKE2B_SIGMAS[12][16] = {
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
  { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
  { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
  { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
  { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
  { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
  { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
  { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
  { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
  { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
  { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 }
};

__device__ HNSLONG cuda_blake2b_leuint64(BYTE *in)
{
  HNSLONG a;
  memcpy(&a, in, 8);
  return a;
}

__device__ HNSLONG cuda_blake2b_ROTR64(HNSLONG a, BYTE b)
{
  return (a >> b) | (a << (64 - b));
}

__device__ void cuda_blake2b_G(cuda_blake2b_ctx_t *ctx, int64_t m1, int64_t m2, int32_t a, int32_t b, int32_t c, int32_t d)
{
    ctx->state[a] = ctx->state[a] + ctx->state[b] + m1;
    ctx->state[d] = cuda_blake2b_ROTR64(ctx->state[d] ^ ctx->state[a], 32);
    ctx->state[c] = ctx->state[c] + ctx->state[d];
    ctx->state[b] = cuda_blake2b_ROTR64(ctx->state[b] ^ ctx->state[c], 24);
    ctx->state[a] = ctx->state[a] + ctx->state[b] + m2;
    ctx->state[d] = cuda_blake2b_ROTR64(ctx->state[d] ^ ctx->state[a], 16);
    ctx->state[c] = ctx->state[c] + ctx->state[d];
    ctx->state[b] = cuda_blake2b_ROTR64(ctx->state[b] ^ ctx->state[c], 63);
}

__device__ __forceinline__ void cuda_blake2b_init_state(cuda_blake2b_ctx_t *ctx)
{

    memcpy(ctx->state, ctx->chain, BLAKE2B_CHAIN_LENGTH);

    // Set blake2b initialization vectors 0-3
    ctx->state[BLAKE2B_CHAIN_SIZE + 0] = 0x6a09e667f3bcc908;
    ctx->state[BLAKE2B_CHAIN_SIZE + 1] = 0xbb67ae8584caa73b;
    ctx->state[BLAKE2B_CHAIN_SIZE + 2] = 0x3c6ef372fe94f82b;
    ctx->state[BLAKE2B_CHAIN_SIZE + 3] = 0xa54ff53a5f1d36f1;

    // Hard code blake2b initialization vectors 4-7
    ctx->state[12] = ctx->t0 ^ 0x510e527fade682d1;
    ctx->state[13] = ctx->t1 ^ 0x9b05688c2b3e6c1f;
    ctx->state[14] = ctx->f0 ^ 0x1f83d9abfb41bd6b;
    ctx->state[15] = 0x5be0cd19137e2179;
}

__device__ __forceinline__ void cuda_blake2b_compress(cuda_blake2b_ctx_t *ctx, BYTE* in, HNSWORD inoffset)
{
    cuda_blake2b_init_state(ctx);

    HNSLONG  m[16] = {0};
#pragma unroll
    for (int j = 0; j < 16; j++)
        m[j] = cuda_blake2b_leuint64(in + inoffset + (j << 3));

    // 12 blake2b rounds in total
    // round 0
    cuda_blake2b_G(ctx, m[0], m[1], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[2], m[3], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[4], m[5], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[6], m[7], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[8], m[9], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[10], m[11], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[12], m[13], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[14], m[15], 3, 4, 9, 14);

    // round 1
    cuda_blake2b_G(ctx, m[14], m[10], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[4], m[8], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[9], m[15], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[13], m[6], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[1], m[12], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[0], m[2], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[11], m[7], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[5], m[3], 3, 4, 9, 14);


    // round 2
    cuda_blake2b_G(ctx, m[11], m[8], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[12], m[0], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[5], m[2], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[15], m[13], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[10], m[14], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[3], m[6], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[7], m[1], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[9], m[4], 3, 4, 9, 14);

    // round 3
    cuda_blake2b_G(ctx, m[7], m[9], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[3], m[1], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[13], m[12], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[11], m[14], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[2], m[6], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[5], m[10], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[4], m[0], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[15], m[8], 3, 4, 9, 14);

    // round 4
    cuda_blake2b_G(ctx, m[9], m[0], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[5], m[7], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[2], m[4], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[10], m[15], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[14], m[1], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[11], m[12], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[6], m[8], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[3], m[13], 3, 4, 9, 14);

    // round 5
    cuda_blake2b_G(ctx, m[2], m[12], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[6], m[10], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[0], m[11], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[8], m[3], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[4], m[13], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[7], m[5], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[15], m[14], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[1], m[9], 3, 4, 9, 14);


    // round 6
    cuda_blake2b_G(ctx, m[12], m[5], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[1], m[15], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[14], m[13], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[4], m[10], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[0], m[7], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[6], m[3], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[9], m[2], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[8], m[11], 3, 4, 9, 14);

    // round 7
    cuda_blake2b_G(ctx, m[13], m[11], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[7], m[14], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[12], m[1], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[3], m[9], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[5], m[0], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[15], m[4], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[8], m[6], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[2], m[10], 3, 4, 9, 14);

    // round 8
    cuda_blake2b_G(ctx, m[6], m[15], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[14], m[9], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[11], m[3], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[0], m[8], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[12], m[2], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[13], m[7], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[1], m[4], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[10], m[5], 3, 4, 9, 14);

    // round 9
    cuda_blake2b_G(ctx, m[10], m[2], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[8], m[4], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[7], m[6], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[1], m[5], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[15], m[11], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[9], m[14], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[3], m[12], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[13], m[0], 3, 4, 9, 14);

    // round 10
    cuda_blake2b_G(ctx, m[0], m[1], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[2], m[3], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[4], m[5], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[6], m[7], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[8], m[9], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[10], m[11], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[12], m[13], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[14], m[15], 3, 4, 9, 14);

    // round 11
    cuda_blake2b_G(ctx, m[14], m[10], 0, 4, 8, 12);
    cuda_blake2b_G(ctx, m[4], m[8], 1, 5, 9, 13);
    cuda_blake2b_G(ctx, m[9], m[15], 2, 6, 10, 14);
    cuda_blake2b_G(ctx, m[13], m[6], 3, 7, 11, 15);
    cuda_blake2b_G(ctx, m[1], m[12], 0, 5, 10, 15);
    cuda_blake2b_G(ctx, m[0], m[2], 1, 6, 11, 12);
    cuda_blake2b_G(ctx, m[11], m[7], 2, 7, 8, 13);
    cuda_blake2b_G(ctx, m[5], m[3], 3, 4, 9, 14);

    for (int offset = 0; offset < BLAKE2B_CHAIN_SIZE; offset++)
        ctx->chain[offset] = ctx->chain[offset] ^ ctx->state[offset] ^ ctx->state[offset + 8];
}

__device__ void cuda_blake2b_init(cuda_blake2b_ctx_t *ctx, HNSWORD digestbitlen)
{
    memset(ctx, 0, sizeof(cuda_blake2b_ctx_t));

    ctx->digestlen = digestbitlen >> 3;
    ctx->pos = 0;
    ctx->t0 = 0;
    ctx->t1 = 0;
    ctx->f0 = 0;

    // Inline the blake2b initialization vectors 0-7
    ctx->chain[0] = 0x6a09e667f3bcc908 ^ (ctx->digestlen | 0x1010000);
    ctx->chain[1] = 0xbb67ae8584caa73b;
    ctx->chain[2] = 0x3c6ef372fe94f82b;
    ctx->chain[3] = 0xa54ff53a5f1d36f1;
    ctx->chain[4] = 0x510e527fade682d1;
    ctx->chain[5] = 0x9b05688c2b3e6c1f;
    ctx->chain[6] = 0x1f83d9abfb41bd6b;
    ctx->chain[7] = 0x5be0cd19137e2179;
}

__device__ void cuda_blake2b_update(cuda_blake2b_ctx_t *ctx, BYTE* in, HNSLONG inlen)
{
    if (inlen == 0)
        return;

	HNSWORD start = 0;
    int64_t in_index = 0, block_index = 0;

    if (ctx->pos)
    {
        start = BLAKE2B_BLOCK_LENGTH - ctx->pos;
        if (start < inlen){
            memcpy(ctx->buff + ctx->pos, in, start);
            ctx->t0 += BLAKE2B_BLOCK_LENGTH;

            if (ctx->t0 == 0) ctx->t1++;

            cuda_blake2b_compress(ctx, ctx->buff, 0);
            ctx->pos = 0;
            memset(ctx->buff, 0, BLAKE2B_BLOCK_LENGTH);
        } else {
            memcpy(ctx->buff + ctx->pos, in, inlen);//read the whole *in
            ctx->pos += inlen;
            return;
        }
    }

    block_index =  inlen - BLAKE2B_BLOCK_LENGTH;
    for (in_index = start; in_index < block_index; in_index += BLAKE2B_BLOCK_LENGTH)
    {
        ctx->t0 += BLAKE2B_BLOCK_LENGTH;
        if (ctx->t0 == 0)
            ctx->t1++;

        cuda_blake2b_compress(ctx, in, in_index);
    }

    memcpy(ctx->buff, in + in_index, inlen - in_index);
    ctx->pos += inlen - in_index;
}

__device__ void cuda_blake2b_final(cuda_blake2b_ctx_t *ctx, BYTE* out)
{
    ctx->f0 = 0xFFFFFFFFFFFFFFFFL;
    ctx->t0 += ctx->pos;
    if (ctx->pos > 0 && ctx->t0 == 0)
        ctx->t1++;

    cuda_blake2b_compress(ctx, ctx->buff, 0);
    memset(ctx->buff, 0, BLAKE2B_BLOCK_LENGTH);
    memset(ctx->state, 0, BLAKE2B_STATE_LENGTH);

    int i8 = 0;
    for (int i = 0; i < BLAKE2B_CHAIN_SIZE && ((i8 = i * 8) < ctx->digestlen); i++)
    {
        BYTE * BYTEs = (BYTE*)(&ctx->chain[i]);
        if (i8 < ctx->digestlen - 8)
            memcpy(out + i8, BYTEs, 8);
        else
            memcpy(out + i8, BYTEs, ctx->digestlen - i8);
    }
}

__global__ void kernel_blake2b_hash(BYTE* indata, HNSWORD inlen, BYTE* outdata, HNSWORD n_batch, HNSWORD BLAKE2B_BLOCK_SIZE)
{
	HNSWORD thread = blockIdx.x * blockDim.x + threadIdx.x;
	             
    if (thread >= n_batch)
    {
        return;
    }
    BYTE* in = indata  + thread * inlen;
    BYTE* out = outdata  + thread * BLAKE2B_BLOCK_SIZE;
    CUDA_BLAKE2B_CTX ctx = c_CTX;
    //if not precomputed CTX, call cuda_blake2b_init() with key
    cuda_blake2b_update(&ctx, in, inlen);
    cuda_blake2b_final(&ctx, out);
}

#define KECCAK_ROUND 24
#define KECCAK_STATE_SIZE 25
#define KECCAK_Q_SIZE 192

__constant__ HNSLONG CUDA_KECCAK_CONSTS[24] = {
  0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
  0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
  0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
  0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
  0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
  0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
};

typedef struct {

    BYTE sha3_flag;
	HNSWORD digestbitlen;
    HNSLONG rate_bits;
    HNSLONG rate_BYTEs;
    HNSLONG absorb_round;

    int64_t state[KECCAK_STATE_SIZE];
    BYTE q[KECCAK_Q_SIZE];

    HNSLONG bits_in_queue;

} cuda_keccak_ctx_t;
typedef cuda_keccak_ctx_t CUDA_KECCAK_CTX;

__device__ HNSLONG cuda_keccak_leuint64(void *in)
{
    HNSLONG a;
    memcpy(&a, in, 8);
    return a;
}

__device__ int64_t cuda_keccak_MIN(int64_t a, int64_t b)
{
    if (a > b) return b;
    return a;
}

__device__ HNSLONG cuda_keccak_UMIN(HNSLONG a, HNSLONG b)
{
    if (a > b) return b;
    return a;
}

__device__ void cuda_keccak_extract(cuda_keccak_ctx_t *ctx)
{
    HNSLONG len = ctx->rate_bits >> 6;
    int64_t a;
    int s = sizeof(HNSLONG);

    for (int i = 0;i < len;i++) {
        a = cuda_keccak_leuint64((int64_t*)&ctx->state[i]);
        memcpy(ctx->q + (i * s), &a, s);
    }
}

__device__ __forceinline__ HNSLONG cuda_keccak_ROTL64(HNSLONG a, HNSLONG  b)
{
    return (a << b) | (a >> (64 - b));
}

__device__ void cuda_keccak_permutations(cuda_keccak_ctx_t * ctx)
{

    int64_t* A = ctx->state;;

    int64_t *a00 = A, *a01 = A + 1, *a02 = A + 2, *a03 = A + 3, *a04 = A + 4;
    int64_t *a05 = A + 5, *a06 = A + 6, *a07 = A + 7, *a08 = A + 8, *a09 = A + 9;
    int64_t *a10 = A + 10, *a11 = A + 11, *a12 = A + 12, *a13 = A + 13, *a14 = A + 14;
    int64_t *a15 = A + 15, *a16 = A + 16, *a17 = A + 17, *a18 = A + 18, *a19 = A + 19;
    int64_t *a20 = A + 20, *a21 = A + 21, *a22 = A + 22, *a23 = A + 23, *a24 = A + 24;

    for (int i = 0; i < KECCAK_ROUND; i++) {

        /* Theta */
        int64_t c0 = *a00 ^ *a05 ^ *a10 ^ *a15 ^ *a20;
        int64_t c1 = *a01 ^ *a06 ^ *a11 ^ *a16 ^ *a21;
        int64_t c2 = *a02 ^ *a07 ^ *a12 ^ *a17 ^ *a22;
        int64_t c3 = *a03 ^ *a08 ^ *a13 ^ *a18 ^ *a23;
        int64_t c4 = *a04 ^ *a09 ^ *a14 ^ *a19 ^ *a24;

        int64_t d1 = cuda_keccak_ROTL64(c1, 1) ^ c4;
        int64_t d2 = cuda_keccak_ROTL64(c2, 1) ^ c0;
        int64_t d3 = cuda_keccak_ROTL64(c3, 1) ^ c1;
        int64_t d4 = cuda_keccak_ROTL64(c4, 1) ^ c2;
        int64_t d0 = cuda_keccak_ROTL64(c0, 1) ^ c3;

        *a00 ^= d1;
        *a05 ^= d1;
        *a10 ^= d1;
        *a15 ^= d1;
        *a20 ^= d1;
        *a01 ^= d2;
        *a06 ^= d2;
        *a11 ^= d2;
        *a16 ^= d2;
        *a21 ^= d2;
        *a02 ^= d3;
        *a07 ^= d3;
        *a12 ^= d3;
        *a17 ^= d3;
        *a22 ^= d3;
        *a03 ^= d4;
        *a08 ^= d4;
        *a13 ^= d4;
        *a18 ^= d4;
        *a23 ^= d4;
        *a04 ^= d0;
        *a09 ^= d0;
        *a14 ^= d0;
        *a19 ^= d0;
        *a24 ^= d0;

        /* Rho pi */
        c1 = cuda_keccak_ROTL64(*a01, 1);
        *a01 = cuda_keccak_ROTL64(*a06, 44);
        *a06 = cuda_keccak_ROTL64(*a09, 20);
        *a09 = cuda_keccak_ROTL64(*a22, 61);
        *a22 = cuda_keccak_ROTL64(*a14, 39);
        *a14 = cuda_keccak_ROTL64(*a20, 18);
        *a20 = cuda_keccak_ROTL64(*a02, 62);
        *a02 = cuda_keccak_ROTL64(*a12, 43);
        *a12 = cuda_keccak_ROTL64(*a13, 25);
        *a13 = cuda_keccak_ROTL64(*a19, 8);
        *a19 = cuda_keccak_ROTL64(*a23, 56);
        *a23 = cuda_keccak_ROTL64(*a15, 41);
        *a15 = cuda_keccak_ROTL64(*a04, 27);
        *a04 = cuda_keccak_ROTL64(*a24, 14);
        *a24 = cuda_keccak_ROTL64(*a21, 2);
        *a21 = cuda_keccak_ROTL64(*a08, 55);
        *a08 = cuda_keccak_ROTL64(*a16, 45);
        *a16 = cuda_keccak_ROTL64(*a05, 36);
        *a05 = cuda_keccak_ROTL64(*a03, 28);
        *a03 = cuda_keccak_ROTL64(*a18, 21);
        *a18 = cuda_keccak_ROTL64(*a17, 15);
        *a17 = cuda_keccak_ROTL64(*a11, 10);
        *a11 = cuda_keccak_ROTL64(*a07, 6);
        *a07 = cuda_keccak_ROTL64(*a10, 3);
        *a10 = c1;

        /* Chi */
        c0 = *a00 ^ (~*a01 & *a02);
        c1 = *a01 ^ (~*a02 & *a03);
        *a02 ^= ~*a03 & *a04;
        *a03 ^= ~*a04 & *a00;
        *a04 ^= ~*a00 & *a01;
        *a00 = c0;
        *a01 = c1;

        c0 = *a05 ^ (~*a06 & *a07);
        c1 = *a06 ^ (~*a07 & *a08);
        *a07 ^= ~*a08 & *a09;
        *a08 ^= ~*a09 & *a05;
        *a09 ^= ~*a05 & *a06;
        *a05 = c0;
        *a06 = c1;

        c0 = *a10 ^ (~*a11 & *a12);
        c1 = *a11 ^ (~*a12 & *a13);
        *a12 ^= ~*a13 & *a14;
        *a13 ^= ~*a14 & *a10;
        *a14 ^= ~*a10 & *a11;
        *a10 = c0;
        *a11 = c1;

        c0 = *a15 ^ (~*a16 & *a17);
        c1 = *a16 ^ (~*a17 & *a18);
        *a17 ^= ~*a18 & *a19;
        *a18 ^= ~*a19 & *a15;
        *a19 ^= ~*a15 & *a16;
        *a15 = c0;
        *a16 = c1;

        c0 = *a20 ^ (~*a21 & *a22);
        c1 = *a21 ^ (~*a22 & *a23);
        *a22 ^= ~*a23 & *a24;
        *a23 ^= ~*a24 & *a20;
        *a24 ^= ~*a20 & *a21;
        *a20 = c0;
        *a21 = c1;

        /* Iota */
        *a00 ^= CUDA_KECCAK_CONSTS[i];
    }
}


__device__ void cuda_keccak_absorb(cuda_keccak_ctx_t *ctx, BYTE* in)
{

    HNSLONG offset = 0;
    for (HNSLONG i = 0; i < ctx->absorb_round; ++i) {
        ctx->state[i] ^= cuda_keccak_leuint64(in + offset);
        offset += 8;
    }

    cuda_keccak_permutations(ctx);
}

__device__ void cuda_keccak_pad(cuda_keccak_ctx_t *ctx)
{
    ctx->q[ctx->bits_in_queue >> 3] |= (1L << (ctx->bits_in_queue & 7));

    if (++(ctx->bits_in_queue) == ctx->rate_bits) {
        cuda_keccak_absorb(ctx, ctx->q);
        ctx->bits_in_queue = 0;
    }

    HNSLONG full = ctx->bits_in_queue >> 6;
    HNSLONG partial = ctx->bits_in_queue & 63;

    HNSLONG offset = 0;
    for (int i = 0; i < full; ++i) {
        ctx->state[i] ^= cuda_keccak_leuint64(ctx->q + offset);
        offset += 8;
    }

    if (partial > 0) {
        HNSLONG mask = (1L << partial) - 1;
        ctx->state[full] ^= cuda_keccak_leuint64(ctx->q + offset) & mask;
    }

    ctx->state[(ctx->rate_bits - 1) >> 6] ^= 9223372036854775808ULL;/* 1 << 63 */

    cuda_keccak_permutations(ctx);
    cuda_keccak_extract(ctx);

    ctx->bits_in_queue = ctx->rate_bits;
}

/*
 * Digestbitlen must be 128 224 256 288 384 512
 */
__device__ void cuda_keccak_init(cuda_keccak_ctx_t *ctx, HNSWORD digestbitlen)
{
    memset(ctx, 0, sizeof(cuda_keccak_ctx_t));
    ctx->sha3_flag = 1;
    ctx->digestbitlen = digestbitlen;
    ctx->rate_bits = 1600 - ((ctx->digestbitlen) << 1);
    ctx->rate_BYTEs = ctx->rate_bits >> 3;
    ctx->absorb_round = ctx->rate_bits >> 6;
    ctx->bits_in_queue = 0;
}

/*
 * Digestbitlen must be 224 256 384 512
 */
__device__ void cuda_keccak_sha3_init(cuda_keccak_ctx_t *ctx, HNSWORD digestbitlen)
{
    cuda_keccak_init(ctx, digestbitlen);
    ctx->sha3_flag = 1;
}

__device__ void cuda_keccak_update(cuda_keccak_ctx_t *ctx, BYTE *in, HNSLONG inlen)
{
    int64_t BYTEs = ctx->bits_in_queue >> 3;
    int64_t count = 0;
    while (count < inlen) {
        if (BYTEs == 0 && count <= ((int64_t)(inlen - ctx->rate_BYTEs))) {
            do {
                cuda_keccak_absorb(ctx, in + count);
                count += ctx->rate_BYTEs;
            } while (count <= ((int64_t)(inlen - ctx->rate_BYTEs)));
        } else {
            int64_t partial = cuda_keccak_MIN(ctx->rate_BYTEs - BYTEs, inlen - count);
            memcpy(ctx->q + BYTEs, in + count, partial);

            BYTEs += partial;
            count += partial;

            if (BYTEs == ctx->rate_BYTEs) {
                cuda_keccak_absorb(ctx, ctx->q);
                BYTEs = 0;
            }
        }
    }
    ctx->bits_in_queue = BYTEs << 3;
}

__device__ void cuda_keccak_final(cuda_keccak_ctx_t *ctx, BYTE *out)
{
    if (ctx->sha3_flag) {
        int mask = (1 << 2) - 1;
        ctx->q[ctx->bits_in_queue >> 3] = (BYTE)(0x02 & mask);
        ctx->bits_in_queue += 2;
    }

    cuda_keccak_pad(ctx);
    HNSLONG i = 0;

    while (i < ctx->digestbitlen) {
        if (ctx->bits_in_queue == 0) {
            cuda_keccak_permutations(ctx);
            cuda_keccak_extract(ctx);
            ctx->bits_in_queue = ctx->rate_bits;
        }

        HNSLONG partial_block = cuda_keccak_UMIN(ctx->bits_in_queue, ctx->digestbitlen - i);
        memcpy(out + (i >> 3), ctx->q + (ctx->rate_BYTEs - (ctx->bits_in_queue >> 3)), partial_block >> 3);
        ctx->bits_in_queue -= partial_block;
        i += partial_block;
    }
}

__global__ void kernel_keccak_hash(BYTE* indata, HNSWORD inlen, BYTE* outdata, HNSWORD n_batch, HNSWORD KECCAK_BLOCK_SIZE)
{
	HNSWORD thread = blockIdx.x * blockDim.x + threadIdx.x;
    if (thread >= n_batch)
    {
        return;
    }
    BYTE* in = indata  + thread * inlen;
    BYTE* out = outdata  + thread * KECCAK_BLOCK_SIZE;
    CUDA_KECCAK_CTX ctx;
    cuda_keccak_init(&ctx, KECCAK_BLOCK_SIZE << 3);
    cuda_keccak_update(&ctx, in, inlen);
    cuda_keccak_final(&ctx, out);
}


/**
 * The miner serialized header:
 *  nonce         - 4
 *  time          - 8
 *  padding       - 20
 *  prev_block    - 32
 *  tree_root     - 32
 *  mask hash     - 32
 *  extra_nonce   - 24
 *  reserved_root - 32
 *  witness_root  - 32
 *  merkle_root   - 32
 *  version       - 4
 *  bits          - 4
 */

// Global memory is underscore prefixed
__constant__ uint8_t _pre_header[96];
__constant__ uint8_t _target[32];
__constant__ uint8_t _padding[32];
__constant__ uint8_t _commit_hash[32];

__device__ int cuda_memcmp(const void *s1, const void *s2, size_t n) {
    const unsigned char *us1 = (const unsigned char *) s1;
    const unsigned char *us2 = (const unsigned char *) s2;
    while (n-- != 0) {
        if (*us1 != *us2) {
            return (*us1 < *us2) ? -1 : +1;
        }
        us1++;
        us2++;
    }
    return 0;
}



__global__ void kernel_hs_hash(
	uint8_t *d_hash,
    uint32_t *out_nonce,
    bool *out_match,
    unsigned int start_nonce,
    unsigned int range,
    unsigned int threads
)
{
    uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid >= threads || tid >= range) {
		printf("tid >= threads || tid >= range \n");
        return;
    }
	//printf("------------------------>blockIdx.x = %d \n", blockIdx.x);
    // Set the nonce based on the start_nonce and thread.
    uint32_t nonce = start_nonce + tid;

    CUDA_BLAKE2B_CTX b_ctx;
    CUDA_KECCAK_CTX s_ctx;

    uint8_t hash[32];
    uint8_t left[64];
    uint8_t right[32];
    uint8_t share[128];

    // Create the share using the nonce,
    // pre_header and commit_hash.
    memcpy(share, &nonce, 4);
    memcpy(share + 4, _pre_header + 4, 92);
    memcpy(share + 96, _commit_hash, 32);

    // Generate left by hashing the share
    // with blake2b-512.
    cuda_blake2b_init(&b_ctx, 512);
    cuda_blake2b_update(&b_ctx, share, 128);
    cuda_blake2b_final(&b_ctx, left);

    // Generate right by hashing the share
    // and first 8 bytes of padding with
    // sha3-256.
    cuda_keccak_init(&s_ctx, 256);
    cuda_keccak_update(&s_ctx, share, 128);
    cuda_keccak_update(&s_ctx, _padding, 8);
    cuda_keccak_final(&s_ctx, right);

    // Generate share hash by hashing together
    // the left, 32 bytes of padding and the
    // right with blake2b-256.
    cuda_blake2b_init(&b_ctx, 256);
    cuda_blake2b_update(&b_ctx, left, 64);
    cuda_blake2b_update(&b_ctx, _padding, 32);
    cuda_blake2b_update(&b_ctx, right, 32);
    cuda_blake2b_final(&b_ctx, hash);

    // Do a bytewise comparison to see if the
    // hash satisfies the target. This could be
    // either the network target or the pool target.
	//char *strhash = bin2hex(hash,32);
	
	if (cuda_memcmp(hash, _target, 32) <= 0) {
        *out_nonce = nonce;
        *out_match = true;
		for (int i = 0; i < 32; i++)
		{
			d_hash[i] = hash[i];
		}
        return;
    }

}

// Calculate the commit hash on the CPU and copy to the GPU
// before starting the GPU kernel. This saves the need for each
// GPU thread to compute the exact same commit_hash.
void hs_commit_hash(const uint8_t *sub_header, const uint8_t *mask_hash)
{
    uint8_t sub_hash[32];
    uint8_t commit_hash[32];

    // Create the sub_hash by hashing the
    // sub_header with blake2b-256.
    hs_blake2b_ctx b_ctx;
    hs_blake2b_init(&b_ctx, 32);
    hs_blake2b_update(&b_ctx, sub_header, 128);
    hs_blake2b_final(&b_ctx, sub_hash, 32);

    // Create the commit_hash by hashing together
    // the sub_hash and the mask_hash with blake2b-256.
    // The mask_hash is included in the miner header serialization
    // that comes from `getwork` or stratum.
    hs_blake2b_init(&b_ctx, 32);
    hs_blake2b_update(&b_ctx, sub_hash, 32);
    hs_blake2b_update(&b_ctx, mask_hash, 32);
    hs_blake2b_final(&b_ctx, commit_hash, 32);

    cudaMemcpyToSymbol(_commit_hash, commit_hash, 32);
}

// At most 32 bytes of padding are needed, so calculate all 32
// bytes and then copy it to the GPU.
void hs_padding(const uint8_t *prev_block, const uint8_t *tree_root, size_t len)
{
  //  uint8_t padding[len];
	uint8_t padding[32];

    size_t i;
    for (i = 0; i < len; i++)
      padding[i] = prev_block[i % 32] ^ tree_root[i % 32];

    cudaMemcpyToSymbol(_padding, padding, 32);

}


void generateBlockHeader(
	const char * prevBlock_,
	const char * treeRoot_,
	const char * reservedRoot_,
	const char * witnessRoot_,
	const char * merkleRoot_,
	const char *nonce2,
	hs_header_t *header,
	uint64_t &ntime,
	uint32_t &version,
    uint32_t &bits) {

	header->time = ntime;
	hs_hex_decode(prevBlock_, header->prev_block);
	/*
	vector<char> mask_bin;
	Hex2Bin(share.mask().c_str(), 64, mask_bin);
	if (!isSubmit) {
		hs_header_mask(
			header->prev_block, (uint8_t *)mask_bin.data(), header->mask_hash);
	}
	else {
		string strmask(mask_bin.begin(), mask_bin.end());
		hs_hex_decode(strmask.c_str(), header->mask_hash);
	}
	*/
	hs_hex_decode(treeRoot_, header->name_root);

	hs_header_padding(header, header->padding, 20);

	hs_hex_decode(reservedRoot_, header->reserved_root);
	hs_hex_decode(witnessRoot_, header->witness_root);
	hs_hex_decode(merkleRoot_, header->merkle_root);

	hs_hex_decode(nonce2, header->extra_nonce);

	
	/*

	string extranonce = Strings::Format("%08x", share.sessionid()) + share.extranonce2();
	hs_hex_decode(extranonce.c_str(), header->extra_nonce);
	*/


	header->version = version;
	header->bits = bits;
//	hs_header_print(header, "-----hns header -----");
}



void generateBlockHeader_bin(uint8_t *header_bin,struct work* work)
{
	auto header = hs_header_alloc();

	char *version, *prevhash, *merkleRoot, *witnessRoot, *treeRoot, *reservedRoot, *nbits, *stime, *nonce2;


	unsigned char ntimetest[4];
	le32enc(ntimetest, work->data[1]);
	stime = bin2hex(ntimetest, 4);
	uint64_t nTime = 0;
	sscanf(stime, "%x", &nTime);


	unsigned char nbitdtest[4];
	le32enc(nbitdtest, work->data[63]);
	nbits = bin2hex(nbitdtest, 4);
	uint32_t nBits = 0;
	sscanf(nbits, "%x", &nBits);



	unsigned char nversiontest[4];
	le32enc(nversiontest, work->data[62]);
	version = bin2hex(nversiontest, 4);
	uint32_t nVersion = 0;
	sscanf(version, "%x", &nVersion);



	prevhash = bin2hex(work->prevhash, 32);
	treeRoot = bin2hex(work->treeRoot, 32);

	reservedRoot = bin2hex(work->reservedRoot, 32);
	witnessRoot = bin2hex(work->witnessRoot, 32);
	merkleRoot = bin2hex(work->merkleRoot, 32);
	nonce2 = bin2hex(work->xnonce2, 24);

	generateBlockHeader(prevhash, treeRoot, reservedRoot, witnessRoot, merkleRoot, nonce2, header, nTime, nVersion, nBits);

	free(version);
	free(prevhash);
	free(merkleRoot);
	free(witnessRoot);
	free(treeRoot);
	free(reservedRoot);
	free(nbits);
	free(stime);

	//uint8_t header_bin[256];
	hs_header_encode(header, header_bin);
	free(header);
}

__host__
void hns_hash_256(int thr_id, uint32_t threads, uint32_t startNonce, uint32_t *resNonces)
{
	const uint32_t threadsperblock = 256;

	dim3 grid(threads / threadsperblock);
	dim3 block(threadsperblock);
	CUDA_SAFE_CALL(cudaMemset(d_resNonces[thr_id], 0xFF, 2 * sizeof(uint32_t)));
	cudaThreadSynchronize();
//	sha256d_gpu_hash_shared << <grid, block >> > (threads, startNonce, d_resNonces[thr_id]);
	cudaThreadSynchronize();

	CUDA_SAFE_CALL(cudaMemcpy(resNonces, d_resNonces[thr_id], 2 * sizeof(uint32_t), cudaMemcpyDeviceToHost));
	if (resNonces[0] == resNonces[1]) {
		resNonces[1] = UINT32_MAX;
	}
}


__host__
void hns_setBlock_256(uint32_t *pdata, uint32_t *ptarget)
{
	
}

// hs_miner_func for the cuda backend
//extern  int scanhash_hns(/*hs_options_t *options*/struct work* work, uint32_t *result, uint8_t *extra_nonce, bool *match)
extern int scanhash_hns(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done)
{
	uint32_t result = 0;	
	bool match=false;

    uint32_t *out_nonce = 0;
    bool *out_match = false;

	
    uint64_t first_nonce = 0;// pdata[19];
	uint32_t throughput = cuda_default_throughput(thr_id, 1U << 25);
	if (init[thr_id]) throughput = min(throughput, (max_nonce - first_nonce));

	const uint32_t threadsperblock = 256;

	dim3 grid(throughput / threadsperblock);
	dim3 block(threadsperblock);


	if (!init[thr_id])
	{
		cudaSetDevice(device_map[thr_id]);
		if (opt_cudaschedule == -1 && gpu_threads == 1) {
			cudaDeviceReset();
			// reduce cpu usage
			cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
			CUDA_LOG_ERROR();
		}
//		gpulog(LOG_INFO, thr_id, "Intensity set to %g, %u cuda threads", throughput2intensity(throughput), throughput);
		init[thr_id] = true;
	}

  //cudaSetDevice(options->device);
    cudaMalloc(&out_nonce, sizeof(uint32_t));
	cudaMemset(out_nonce, 0, sizeof(uint32_t));

    cudaMalloc(&out_match, sizeof(bool));
    cudaMemset(out_match, 0, sizeof(bool));


	uint8_t *d_hash = 0;
	cudaMalloc(&d_hash, sizeof(uint8_t) * 32);
	cudaMemset(d_hash, 0, sizeof(uint8_t) * 32);

	uint8_t header_bin[256];
    generateBlockHeader_bin(header_bin,work);



    // preheader + mask hash
    // nonce       - 4 bytes
    // time        - 8 bytes
    // pad         - 20 bytes
    // prev        - 32 bytes
    // tree root   - 32 bytes
    // mask hash   - 32 bytes
    // total       - 128 bytes

    // subheader
    // extra nonce - 24 bytes
    // reserved    - 32 bytes
    // witness     - 32 bytes
    // merkle      - 32 bytes
    // version     - 4 bytes
    // bits        - 4 bytes
    // total       - 128 bytes

	cudaMemcpyToSymbol(_pre_header, header_bin, 96);


	//simulate the target
//	char *target = "0000000000000011e28a00000000000000000000000000000000000000000000";
	char *target = "00000011e28a0000000000000000000000000000000000000000000000000000";
	unsigned char targetbin[32];
	hex2bin(targetbin, target, 32);
	cudaMemcpyToSymbol(_target, targetbin, 32);


    // Pointers to prev block and tree root.
	hs_padding(header_bin + 32, header_bin + 64, 32);  
    // Pointers to the subheader and mask hash
	hs_commit_hash(_padding + 128, _padding + 96);

//	applog(LOG_DEBUG, "DEBUG: kernel_hs_hash begin: throughput:%d", throughput);

	do{

//		applog(LOG_DEBUG, "kernel_hs_hash()---------->: first_nonce->%llu   ", first_nonce);
		cudaThreadSynchronize();
		
		kernel_hs_hash <<<grid,block>>>(
			d_hash,
			out_nonce,
			out_match,
			first_nonce,
			throughput,
			throughput
			);

		cudaThreadSynchronize();
	
		

	    CUDA_SAFE_CALL(cudaMemcpy(&result, out_nonce, sizeof(uint32_t), cudaMemcpyDeviceToHost));
//		applog(LOG_DEBUG, "kernel_hs_hash()---------->: result->%llu   ", result);

	    CUDA_SAFE_CALL(cudaMemcpy(&match, out_match, sizeof(bool), cudaMemcpyDeviceToHost));
		first_nonce += throughput;

	} while (!/*work_restart[thr_id].restart*/match);

//	applog(LOG_INFO, "kernel_hs_hash()---------->: first_nonce->%llu   ", first_nonce);


	uint8_t hash[32];
	cudaMemcpy(hash, d_hash, sizeof(uint8_t) * 32, cudaMemcpyDeviceToHost);
	char *strhash = bin2hex(hash, 32);
	applog(LOG_INFO, "kernel_hs_hash()---------->: strhash->%s   ", strhash);


    cudaError_t error = cudaGetLastError();
    if (error != cudaSuccess) {
      printf("error hs cuda hash: error->%s \n", cudaGetErrorString(error));
      // TOOD: cudaFree?
	  return -2;// HS_ENOSOLUTION;
    }
    cudaFree(out_nonce);
    cudaFree(out_match);

    if (match)
      return HS_SUCCESS;

	return 0;// HS_ENOSOLUTION;
}