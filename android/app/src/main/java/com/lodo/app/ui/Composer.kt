package com.lodo.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp

/**
 * 全 app 的对话输入框只有这一种样子:AI 页/问问 AI 弹层的输入框、各页底部「问问 AI」条、
 * 反问卡片里的「其他…」。高度和旁边的发送键一样(`height`),圆角是高度的一半——
 * 单行时就是胶囊,多行长高时四角仍是同一个圆角。
 */
object ComposerMetrics {
    val height = 52.dp
    val shape = RoundedCornerShape(26.dp)
    /** 输入行外侧的留白(AI 输入栏与「问问 AI」条同一个值,切换时位置不跳)。 */
    val outerPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
}

@Composable
fun composerContainerColor() = MaterialTheme.colorScheme.surfaceContainerHigh

/** 输入框本体:不用 M3 TextField(最小高度 56dp、带指示线,压不到和按钮一样高)。 */
@Composable
fun ComposerField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = false,
    maxLines: Int = 6,
    trailing: (@Composable () -> Unit)? = null,
) {
    val textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = singleLine,
        maxLines = if (singleLine) 1 else maxLines,
        textStyle = textStyle,
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        modifier = modifier,
        decorationBox = { inner ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .heightIn(min = ComposerMetrics.height)
                    .clip(ComposerMetrics.shape)
                    .background(composerContainerColor())
                    .padding(start = 20.dp, end = if (trailing != null) 4.dp else 20.dp),
            ) {
                Box(Modifier.weight(1f).padding(vertical = 14.dp)) {
                    if (value.isEmpty()) {
                        Text(placeholder, style = textStyle, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    inner()
                }
                trailing?.invoke()
            }
        },
    )
}
