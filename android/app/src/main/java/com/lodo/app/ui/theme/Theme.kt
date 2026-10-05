package com.lodo.app.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.lodo.app.ui.L

/**
 * 强调色:dynamic = Material You 跟随壁纸取色(Android 12+ 的系统标准),其余六档与 iOS
 * AccentPalette 同名同色系(赤陶/靛蓝/靛紫/松绿/玫红/石墨)。每档给明暗两套主色与容器色,
 * 中性色走 M3 默认;明暗两套都按 WCAG AA 取值(暗色下主色是浅色,上面的字是深色)。
 */
enum class AccentPalette(
    val raw: String,
    val lightPrimary: Long, val lightContainer: Long, val lightOnContainer: Long,
    val darkPrimary: Long, val darkOnPrimary: Long, val darkContainer: Long, val darkOnContainer: Long,
) {
    TERRACOTTA("terracotta", 0xFFB3420F, 0xFFFFDBCD, 0xFF380D00, 0xFFFFB596, 0xFF5A1B00, 0xFF7E2D05, 0xFFFFDBCD),
    INDIGO("indigo", 0xFF4555C5, 0xFFDFE0FF, 0xFF000E5E, 0xFFBCC2FF, 0xFF0F2195, 0xFF2C3CAC, 0xFFDFE0FF),
    VIOLET("violet", 0xFF7342C9, 0xFFEBDCFF, 0xFF270058, 0xFFD3BBFF, 0xFF41008B, 0xFF5A25AF, 0xFFEBDCFF),
    TEAL("teal", 0xFF006A62, 0xFF9DF2E6, 0xFF00201D, 0xFF81D5CA, 0xFF003732, 0xFF005049, 0xFF9DF2E6),
    ROSE("rose", 0xFFB0255E, 0xFFFFD9E2, 0xFF3E001C, 0xFFFFB1C7, 0xFF650031, 0xFF8E0547, 0xFFFFD9E2),
    GRAPHITE("graphite", 0xFF475A6B, 0xFFD2E4F7, 0xFF021D2C, 0xFFB6C9DC, 0xFF203242, 0xFF374859, 0xFFD2E4F7);

    val label: String
        get() = when (this) {
            TERRACOTTA -> L("赤陶", "Terracotta")
            INDIGO -> L("靛蓝", "Indigo")
            VIOLET -> L("靛紫", "Violet")
            TEAL -> L("松绿", "Teal")
            ROSE -> L("玫红", "Rose")
            GRAPHITE -> L("石墨", "Graphite")
        }

    companion object {
        fun from(raw: String) = entries.firstOrNull { it.raw == raw }
    }
}

private fun paletteScheme(p: AccentPalette, dark: Boolean): ColorScheme = if (dark) darkColorScheme(
    primary = Color(p.darkPrimary), onPrimary = Color(p.darkOnPrimary),
    primaryContainer = Color(p.darkContainer), onPrimaryContainer = Color(p.darkOnContainer),
    secondary = Color(p.darkPrimary).copy(alpha = 0.85f), secondaryContainer = Color(p.darkContainer).copy(alpha = 0.7f),
    onSecondaryContainer = Color(p.darkOnContainer),
    tertiaryContainer = Color(0xFF3B4858), onTertiaryContainer = Color(0xFFD6E3F7),
) else lightColorScheme(
    primary = Color(p.lightPrimary), onPrimary = Color.White,
    primaryContainer = Color(p.lightContainer), onPrimaryContainer = Color(p.lightOnContainer),
    secondary = Color(p.lightPrimary).copy(alpha = 0.85f), secondaryContainer = Color(p.lightContainer).copy(alpha = 0.7f),
    onSecondaryContainer = Color(p.lightOnContainer),
    tertiaryContainer = Color(0xFFD6E3F7), onTertiaryContainer = Color(0xFF0E1D2C),
)

/** 表达式风格的形状:圆角整体大一档(M3 Expressive)。 */
private val LodoShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun LodoTheme(
    accent: String = "dynamic",
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val palette = AccentPalette.from(accent)
    val colorScheme = when {
        palette != null -> paletteScheme(palette, darkTheme)
        Build.VERSION.SDK_INT >= 31 -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        else -> paletteScheme(AccentPalette.TERRACOTTA, darkTheme)
    }
    MaterialExpressiveTheme(colorScheme = colorScheme, shapes = LodoShapes, content = content)
}

/**
 * 状态色和强调色分开(同 iOS LodoColor):逾期/错误红、完成绿、稍等灰。不随强调色变。
 */
object LodoColor {
    val critical: Color
        @Composable @ReadOnlyComposable get() = if (isDark()) Color(0xFFFF8A80) else Color(0xFFC9252D)
    val positive: Color
        @Composable @ReadOnlyComposable get() = if (isDark()) Color(0xFF7BD88F) else Color(0xFF1E7A35)
    val warning: Color
        @Composable @ReadOnlyComposable get() = if (isDark()) Color(0xFFFFC46B) else Color(0xFF9A5B00)

    @Composable @ReadOnlyComposable
    private fun isDark() = MaterialTheme.colorScheme.surface.luminance() < 0.5f
}

private fun Color.luminance(): Float = 0.2126f * red + 0.7152f * green + 0.0722f * blue

/** 按天区分行程的颜色(只用来区分第几天,不承载语义,同 iOS dayColors)。 */
val dayColors = listOf(
    Color(0xFF3B82F6), Color(0xFFEF6C00), Color(0xFF16A34A), Color(0xFF9333EA),
    Color(0xFFDB2777), Color(0xFF0891B2), Color(0xFFCA8A04),
)
