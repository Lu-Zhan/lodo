#ifndef LODO_RERANKER_H
#define LODO_RERANKER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LodoReranker LodoReranker;

/// 从 safetensors 字节载入模型;失败返回 NULL。字节在调用返回后即可释放。
LodoReranker *lodo_rr_load(const uint8_t *bytes, size_t length);

/// 返回应当提到首位的候选下标,-1 = 不改。字符串均为 UTF-8、以 \0 结尾。
/// answers_key / trusted 各 count 个字节,非 0 为真(含义见 chinese-ime-lm CandidateFacts)。
int32_t lodo_rr_best_where(LodoReranker *reranker, const char *context,
                           const char *const *texts, const uint8_t *answers_key,
                           const uint8_t *trusted, size_t count);

/// 权重头里的语料署名(再分发必须保留),由调用方用 lodo_rr_free_string 释放。
char *lodo_rr_attribution(const LodoReranker *reranker);

void lodo_rr_free_string(char *string);
void lodo_rr_free(LodoReranker *reranker);

#ifdef __cplusplus
}
#endif

#endif
