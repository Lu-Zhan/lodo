//! chinese-ime-lm 重排器的 C ABI 包装,给 Swift 用。上游 crate 禁止 unsafe,指针处理都在这一层。

use std::ffi::{c_char, CStr, CString};
use std::sync::Arc;

use chinese_ime_lm::{CandidateFacts, Reranker, SentenceModel};

/// 一个会话:模型 + 上游缓存的上屏前缀。不是线程安全的,Swift 侧串行调用。
pub struct LodoReranker {
    inner: Reranker,
}

/// # Safety
/// `bytes` 指向 `length` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn lodo_rr_load(bytes: *const u8, length: usize) -> *mut LodoReranker {
    if bytes.is_null() {
        return std::ptr::null_mut();
    }
    let slice = std::slice::from_raw_parts(bytes, length);
    match SentenceModel::load(slice) {
        Ok(model) => Box::into_raw(Box::new(LodoReranker {
            inner: Reranker::new(Arc::new(model)),
        })),
        Err(_) => std::ptr::null_mut(),
    }
}

unsafe fn text<'a>(pointer: *const c_char) -> Option<&'a str> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok()
}

/// # Safety
/// `reranker` 来自 `lodo_rr_load`;`texts`、`answers_key`、`trusted` 各有 `count` 项。
#[no_mangle]
pub unsafe extern "C" fn lodo_rr_best_where(
    reranker: *mut LodoReranker,
    context: *const c_char,
    texts: *const *const c_char,
    answers_key: *const u8,
    trusted: *const u8,
    count: usize,
) -> i32 {
    let Some(reranker) = reranker.as_mut() else { return -1 };
    if count == 0 || texts.is_null() || answers_key.is_null() || trusted.is_null() {
        return -1;
    }
    let context = text(context).unwrap_or("");
    let pointers = std::slice::from_raw_parts(texts, count);
    let mut candidates = Vec::with_capacity(count);
    for &pointer in pointers {
        match text(pointer) {
            Some(candidate) => candidates.push(candidate),
            None => return -1,
        }
    }
    let answers = std::slice::from_raw_parts(answers_key, count);
    let trusted = std::slice::from_raw_parts(trusted, count);
    reranker
        .inner
        .best_where(context, &candidates, |index| CandidateFacts {
            answers_key: answers[index] != 0,
            trusted_dictionary_hit: trusted[index] != 0,
        })
        .map_or(-1, |index| index as i32)
}

/// # Safety
/// `reranker` 来自 `lodo_rr_load`。
#[no_mangle]
pub unsafe extern "C" fn lodo_rr_attribution(reranker: *const LodoReranker) -> *mut c_char {
    let Some(reranker) = reranker.as_ref() else { return std::ptr::null_mut() };
    CString::new(reranker.inner.model().attribution())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// `string` 来自 `lodo_rr_attribution`。
#[no_mangle]
pub unsafe extern "C" fn lodo_rr_free_string(string: *mut c_char) {
    if !string.is_null() {
        drop(CString::from_raw(string));
    }
}

/// # Safety
/// `reranker` 来自 `lodo_rr_load`,之后不再使用。
#[no_mangle]
pub unsafe extern "C" fn lodo_rr_free(reranker: *mut LodoReranker) {
    if !reranker.is_null() {
        drop(Box::from_raw(reranker));
    }
}
