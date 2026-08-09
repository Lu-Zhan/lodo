package com.lodo.app.ai

import android.content.Context
import com.google.ai.edge.aicore.GenerationConfig
import com.google.ai.edge.aicore.GenerativeAIException
import com.google.ai.edge.aicore.GenerativeModel
import com.google.ai.edge.aicore.generationConfig

/**
 * 端上 AI(Gemini Nano,通过 AICore SDK),对应 iOS FoundationModelsClient——
 * 两者在产品里是同一个位置:"不需要联网、不需要配置 API key 的本机模型",
 * 底层技术不同(Apple Foundation Models vs Google AICore)是平台差异,不是
 * 需要对齐的地方。和 iOS 版一样只做"可用性检查 + 单轮文本生成"这个最小子集,
 * 不做流式输出/多轮对话(iOS 那边本身也只是简单包装)。
 *
 * 现状(写这段代码时的真实情况,供后续维护参考):AICore SDK 处于实验阶段
 * (0.0.1-exp01),端上模型只在少数 Pixel 机型上真正可用,其余设备
 * generateContent 会抛 [GenerativeAIException] 的某个子类(常见是设备不支持/
 * 模型未下载)。这个类把"不可用"这件事显式建模成返回 null,不让调用方假设
 * 端上 AI 一定能用——settings/UI 层应该先调 [isAvailable] 判断要不要展示这个
 * 选项,而不是直接尝试 [generate] 再靠异常兜底当作产品逻辑。
 */
object GeminiNanoClient {
    private fun buildModel(context: Context): GenerativeModel {
        val config = generationConfig {
            this.context = context
            temperature = 0.7f
            maxOutputTokens = 512
        }
        return GenerativeModel(config)
    }

    /** 惰性探测一次是否能拿到可用的推理引擎;探测失败直接判定不可用,不重试。
     * 调用方(如设置页要不要展示"端上 AI"选项)调一次即可,不需要每次生成前
     * 都测一遍。 */
    suspend fun isAvailable(context: Context): Boolean {
        val model = buildModel(context)
        return try {
            model.generateContent("ping")
            true
        } catch (e: GenerativeAIException) {
            false
        } catch (e: Exception) {
            false
        } finally {
            model.close()
        }
    }

    /** 单轮文本生成;失败(模型不可用/推理出错)返回 null,调用方据此回退到
     * 联网的 DeepSeek 或提示端上 AI 暂不可用,不抛异常打断主流程——与
     * DeepSeekClient 那一套"失败即抛 DeepSeekException 展示给用户"的错误
     * 处理刻意不同,因为端上 AI 在这个 SDK 现状下更像是一个"能用就用,不能用
     * 就默默回退"的可选增强,不是用户主动配置、失败了要看到明确报错的路径。 */
    suspend fun generate(context: Context, prompt: String): String? {
        val model = buildModel(context)
        return try {
            model.generateContent(prompt).text?.takeIf { it.isNotBlank() }
        } catch (e: GenerativeAIException) {
            null
        } catch (e: Exception) {
            null
        } finally {
            model.close()
        }
    }
}
