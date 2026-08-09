package com.lodo.app.ui.memory

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.data.MemoryEntity
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** "记忆"tab 的状态与操作,对应 iOS MemoryListView(纯文字/链接收藏 + 资产/
 * 人脉子功能;不含 pdf/image/file 收藏)。查询/标签筛选是纯 UI 状态,过滤在
 * Composable 侧对 [items] 现算,不需要额外的 Flow 组合。 */
class MemoryViewModel(application: Application) : AndroidViewModel(application) {
    private val app get() = getApplication<LodoApp>()

    val items = app.memoryRepository.observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val relationships = app.memoryRepository.observeRelationships()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    var showGraph by mutableStateOf(false)

    var query by mutableStateOf("")
    var selectedTag by mutableStateOf<String?>(null)
        private set

    /** 资产/人脉默认从列表隐藏,和普通标签筛选是两个独立开关——与 iOS
     * showAssets/showContacts 一致。 */
    var showAssets by mutableStateOf(false)
    var showContacts by mutableStateOf(false)

    val allTags: List<String> get() = items.value
        .flatMap(MemoryEntity::tagsList)
        .filterNot { it == MemoryEntity.assetTagName || it == MemoryEntity.contactTagName }
        .distinct().sorted()

    var showCompose by mutableStateOf(false)
    var showAssetCompose by mutableStateOf(false)
    var showContactCompose by mutableStateOf(false)
    var detailUuid by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false)
        private set
    var errorText by mutableStateOf<String?>(null)

    fun toggleTag(tag: String) { selectedTag = if (selectedTag == tag) null else tag }

    fun save(text: String) = viewModelScope.launch {
        if (text.isBlank() || busy) return@launch
        busy = true
        errorText = null
        try {
            app.memoryRepository.saveText(app.settings.aiConfig(), text)
            showCompose = false
        } catch (e: Exception) {
            errorText = e.message
        } finally {
            busy = false
        }
    }

    fun saveAsset(title: String, value: Double?, currency: String, liability: Double?, interestRate: Double?) =
        viewModelScope.launch {
            app.memoryRepository.saveAsset(title, value, currency, liability, interestRate)
            showAssetCompose = false
        }

    fun updateAsset(uuid: String, title: String, value: Double?, currency: String, liability: Double?, interestRate: Double?) =
        viewModelScope.launch {
            app.memoryRepository.updateAsset(uuid, title, value, currency, liability, interestRate)
        }

    fun saveContact(nickname: String, phone: String?, email: String?, birthdayMillis: Long?, preferences: String?) =
        viewModelScope.launch {
            app.memoryRepository.saveContact(nickname, phone, email, birthdayMillis, preferences)
            showContactCompose = false
        }

    fun updateContact(uuid: String, nickname: String, phone: String?, email: String?, birthdayMillis: Long?, preferences: String?) =
        viewModelScope.launch {
            app.memoryRepository.updateContact(uuid, nickname, phone, email, birthdayMillis, preferences)
        }

    fun retry(uuid: String) = viewModelScope.launch {
        app.memoryRepository.retry(app.settings.aiConfig(), uuid)
    }

    fun delete(uuid: String) = viewModelScope.launch {
        app.memoryRepository.delete(uuid)
        if (detailUuid == uuid) detailUuid = null
    }

    fun updateTitleAndTags(uuid: String, title: String, tags: List<String>) = viewModelScope.launch {
        app.memoryRepository.updateTitleAndTags(uuid, title, tags)
    }

    fun addRelationship(fromUuid: String, toUuid: String, label: String) = viewModelScope.launch {
        app.memoryRepository.addRelationship(fromUuid, toUuid, label)
    }

    fun deleteRelationship(uuid: String) = viewModelScope.launch {
        app.memoryRepository.deleteRelationship(uuid)
    }
}
