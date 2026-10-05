package com.lodo.app.ui.travel

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.outlined.CenterFocusStrong
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.FullscreenExit
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.lodo.app.core.GeoPoint
import com.lodo.app.core.TravelEntry
import com.lodo.app.core.TravelGeo
import com.lodo.app.core.TravelItemKind
import com.lodo.app.core.TravelPlan
import com.lodo.app.ui.L
import com.lodo.app.ui.theme.dayColors
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.views.overlay.TilesOverlay
import org.osmdroid.util.BoundingBox
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.CopyrightOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
import java.io.File
import java.time.LocalDate
import org.osmdroid.util.GeoPoint as OsmPoint

private fun GeoPoint.osm() = OsmPoint(latitude, longitude)

/** 地图标记:彩色圆底 + 白边 + 序号(选中某天时)或类型字,选中的放大一圈。 */
private fun markerIcon(context: Context, color: Int, label: String, selected: Boolean): BitmapDrawable {
    val density = context.resources.displayMetrics.density
    val size = ((if (selected) 38 else 28) * density).toInt()
    val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val p = Paint(Paint.ANTI_ALIAS_FLAG)
    p.color = android.graphics.Color.WHITE
    c.drawCircle(size / 2f, size / 2f, size / 2f, p)
    p.color = color
    c.drawCircle(size / 2f, size / 2f, size / 2f - 2.5f * density, p)
    p.color = android.graphics.Color.WHITE
    p.textAlign = Paint.Align.CENTER
    p.textSize = (if (selected) 15 else 12) * density
    p.isFakeBoldText = true
    c.drawText(label, size / 2f, size / 2f - (p.descent() + p.ascent()) / 2, p)
    return BitmapDrawable(context.resources, bmp)
}

private fun kindLabel(kind: TravelItemKind) = when (kind) {
    TravelItemKind.LODGING -> L("住", "H")
    TravelItemKind.FLIGHT -> "✈"
    TravelItemKind.TRAIN, TravelItemKind.COACH -> L("车", "T")
    TravelItemKind.PLACE -> "•"
}

/**
 * 旅行地图(对应 iOS TravelDetailView 的 Map):只画有坐标的点。
 * - 选「全部」时只画点、一条线都不画(几天的线在酒店交汇,看着像把不同日期串在一起);
 * - 选某一天时画那天的连线:前一晚的酒店 → 当天地点 → 当晚的酒店,先用记下的路线,
 *   没有就请求 OSRM,规划不出来的那段退回虚线直线;镜头框住那一天。
 * - 放针模式:针钉在屏幕正中,拖动地图把目标对准针尖再确认(同 iOS)。
 */
@Composable
fun TripMap(
    entries: List<TravelEntry>,
    days: List<LocalDate>,
    selectedDay: Int?,
    onSelectDay: (Int?) -> Unit,
    selectedId: String?,
    onSelectEntry: (String) -> Unit,
    status: String?,
    busy: Boolean,
    onDismissStatus: () -> Unit,
    statusAction: Pair<String, () -> Unit>?,
    pinMode: Boolean,
    pinStart: GeoPoint?,
    onPinConfirm: (GeoPoint) -> Unit,
    onPinCancel: () -> Unit,
    expanded: Boolean,
    onToggleExpanded: (() -> Unit)?,
    loadLeg: suspend (GeoPoint, GeoPoint) -> List<GeoPoint>?,
    cachedLeg: (GeoPoint, GeoPoint) -> List<GeoPoint>?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val map = remember {
        Configuration.getInstance().apply {
            userAgentValue = context.packageName
            osmdroidBasePath = File(context.cacheDir, "osmdroid")
            osmdroidTileCache = File(context.cacheDir, "osmdroid/tiles")
        }
        MapView(context).apply {
            setMultiTouchControls(true)
            zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
            isTilesScaledToDpi = true
            minZoomLevel = 2.0
            controller.setZoom(3.0)
        }
    }
    DisposableEffect(Unit) {
        map.onResume()
        onDispose { map.onPause(); map.onDetach() }
    }
    // OpenStreetMap 标准瓦片(不要 key,按 OSM 瓦片使用规定带可识别的 User-Agent);
    // 深色模式把瓦片反色,不另找一套暗色瓦片服务(CARTO 现在要 key,实测带水印)。
    LaunchedEffect(dark) {
        map.setTileSource(TileSourceFactory.MAPNIK)
        map.overlayManager.tilesOverlay.setColorFilter(if (dark) TilesOverlay.INVERT_COLORS else null)
    }

    val day = selectedDay?.let { days.getOrNull(it) }
    val route = remember(entries, day) { day?.let { TravelGeo.dayRoute(it, entries) } ?: emptyList() }
    val legs = remember { mutableStateMapOf<String, List<GeoPoint>?>() }
    LaunchedEffect(route) {
        route.zipWithNext().forEach { (a, b) ->
            val pa = GeoPoint(a.latitude!!, a.longitude!!)
            val pb = GeoPoint(b.latitude!!, b.longitude!!)
            val key = TravelGeo.legKey(pa, pb)
            if (key !in legs) legs[key] = cachedLeg(pa, pb) ?: loadLeg(pa, pb)
        }
    }

    // 哪些点画出来:选某天时只画那天(含早晚的酒店),全部时画所有有坐标的。
    val visible = remember(entries, day, route) {
        val withCoord = entries.filter { it.hasCoordinate }
        if (day == null) withCoord else (route + withCoord.filter { e -> e.kind.isTransport && TravelPlan.covers(e, day) }).distinctBy { it.id }
    }
    val dayIndexOf = remember(entries, days) {
        entries.associate { e -> e.id to days.indexOfFirst { TravelPlan.covers(e, it) } }
    }

    // 取景:天数/点集变了就框一次;那天一个点都没有时不动镜头(甩到 (0,0) 更糟)。
    LaunchedEffect(visible.map { it.id }, selectedDay) {
        if (pinMode) return@LaunchedEffect
        val pts = (if (day == null) visible.filter { !it.kind.isTransport }.ifEmpty { visible } else visible)
            .map { OsmPoint(it.latitude!!, it.longitude!!) }
        if (pts.isEmpty()) return@LaunchedEffect
        map.post {
            if (pts.size == 1) { map.controller.setZoom(15.0); map.controller.setCenter(pts[0]) }
            else runCatching { map.zoomToBoundingBox(BoundingBox.fromGeoPoints(pts).increaseByScale(1.6f), false, 60) }
        }
    }
    LaunchedEffect(selectedId) {
        val e = entries.firstOrNull { it.id == selectedId && it.hasCoordinate } ?: return@LaunchedEffect
        map.controller.animateTo(OsmPoint(e.latitude!!, e.longitude!!), maxOf(map.zoomLevelDouble, 14.0), 600L)
    }
    LaunchedEffect(pinMode) {
        if (pinMode && pinStart != null) map.controller.animateTo(pinStart.osm(), maxOf(map.zoomLevelDouble, 15.0), 400L)
    }

    // osmdroid 的 MapView 不裁剪自己的绘制,瓦片会画到地图框外面(实测盖住了下面的标题和切换条)。
    Box(modifier.clipToBounds()) {
        AndroidView(factory = { map }, modifier = Modifier.fillMaxSize().clipToBounds(), update = { mv ->
            mv.overlays.clear()
            val color = selectedDay?.let { dayColors[it % dayColors.size].toArgb() }
            route.zipWithNext().forEach { (a, b) ->
                val pa = GeoPoint(a.latitude!!, a.longitude!!)
                val pb = GeoPoint(b.latitude!!, b.longitude!!)
                val pts = legs[TravelGeo.legKey(pa, pb)]
                mv.overlays += Polyline(mv).apply {
                    setPoints((pts ?: listOf(pa, pb)).map { it.osm() })
                    outlinePaint.color = color ?: android.graphics.Color.BLUE
                    outlinePaint.strokeWidth = 5f * context.resources.displayMetrics.density
                    outlinePaint.strokeCap = Paint.Cap.ROUND
                    if (pts == null) outlinePaint.pathEffect = DashPathEffect(floatArrayOf(18f, 14f), 0f)
                    isGeodesic = pts == null
                }
            }
            val order = route.filter { it.kind == TravelItemKind.PLACE }.mapIndexed { i, e -> e.id to "${i + 1}" }.toMap()
            visible.sortedBy { it.id == selectedId }.forEach { e ->
                val idx = dayIndexOf[e.id] ?: -1
                val c = (color ?: if (idx >= 0) dayColors[idx % dayColors.size].toArgb() else android.graphics.Color.GRAY)
                mv.overlays += Marker(mv).apply {
                    position = OsmPoint(e.latitude!!, e.longitude!!)
                    icon = markerIcon(context, c, order[e.id] ?: kindLabel(e.kind), e.id == selectedId)
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    title = e.title
                    setInfoWindow(null)
                    setOnMarkerClickListener { _, _ -> onSelectEntry(e.id); true }
                }
            }
            mv.overlays += CopyrightOverlay(context).apply { setTextSize(9) }
            mv.invalidate()
        })

        if (pinMode) {
            Icon(Icons.Filled.Place, null, tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.align(Alignment.Center).size(44.dp).offset(y = (-20).dp))
            Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
                modifier = Modifier.align(Alignment.TopCenter).padding(12.dp)) {
                Text(L("拖动地图,把针尖对准目标", "Drag the map to put the pin on the spot"), Modifier.padding(horizontal = 14.dp, vertical = 8.dp))
            }
            Row(Modifier.align(Alignment.BottomCenter).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onPinCancel, colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surface)) { Text(L("取消", "Cancel")) }
                Button(onClick = { val c = map.mapCenter; onPinConfirm(GeoPoint(c.latitude, c.longitude)) }) { Text(L("确认", "Confirm")) }
            }
            return@Box
        }

        // 按天筛选(同 iOS 地图左侧那条竖排胶囊,手机上改成横排)。
        Column(Modifier.align(Alignment.TopStart).fillMaxWidth()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                item {
                    FilterChip(selectedDay == null, { onSelectDay(null) }, label = { Text(L("全部", "All")) },
                        colors = FilterChipDefaults.filterChipColors(containerColor = MaterialTheme.colorScheme.surface))
                }
                items(days.indices.toList()) { i ->
                    FilterChip(selectedDay == i, { onSelectDay(i) }, label = { Text(L("第 ${i + 1} 天", "Day ${i + 1}")) },
                        leadingIcon = { Surface(shape = CircleShape, color = dayColors[i % dayColors.size], modifier = Modifier.size(10.dp)) {} },
                        colors = FilterChipDefaults.filterChipColors(containerColor = MaterialTheme.colorScheme.surface))
                }
            }
            if (status != null) {
                Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 2.dp,
                    modifier = Modifier.padding(horizontal = 10.dp).fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp)) {
                        if (busy) { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)) }
                        Text(status, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                        statusAction?.let { (label, action) -> TextButton(onClick = action) { Text(label) } }
                        if (!busy) IconButton(onClick = onDismissStatus, modifier = Modifier.size(32.dp)) { Icon(Icons.Filled.Close, L("关闭", "Close"), Modifier.size(16.dp)) }
                    }
                }
            }
        }
        Column(Modifier.align(Alignment.BottomEnd).padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            MapButton(Icons.Outlined.CenterFocusStrong, L("显示全部", "Fit")) {
                val pts = visible.map { OsmPoint(it.latitude!!, it.longitude!!) }
                if (pts.size == 1) map.controller.animateTo(pts[0], 15.0, 400L)
                else if (pts.size > 1) runCatching { map.zoomToBoundingBox(BoundingBox.fromGeoPoints(pts).increaseByScale(1.6f), true, 60) }
            }
            onToggleExpanded?.let { MapButton(if (expanded) Icons.Outlined.FullscreenExit else Icons.Outlined.Fullscreen, L("放大地图", "Expand"), it) }
        }
        if (entries.none { it.hasCoordinate } && status == null) {
            Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
                modifier = Modifier.align(Alignment.Center).padding(24.dp)) {
                Text(L("还没有找到坐标的地点", "No places located yet"), Modifier.padding(12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun MapButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = CircleShape, color = MaterialTheme.colorScheme.surface, shadowElevation = 3.dp, modifier = Modifier.size(44.dp)) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, label) }
    }
}
