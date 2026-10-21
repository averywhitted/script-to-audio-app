//! C interface for the Flutter apps (`dart:ffi`). Everything crosses as UTF-8 JSON strings, like the apps' existing
//! worker protocol, so there is no generated binding layer:
//!
//!   char *tr_parse_pdf(const char *pdf_path, const char *config_json, const char *pdfium_path);
//!   char *tr_version(void);
//!   void  tr_free(char *s);          // every returned string must be released with this
//!
//! `tr_parse_pdf` returns `{"ok":true,"script":{...}}` or `{"ok":false,"error":"..."}`; `config_json` (the
//! corrections config) and `pdfium_path` may be NULL. Calls are serialised: PDFium is not re-entrant.

use std::ffi::{c_char, CStr, CString};
use pdfium_render::prelude::Pdfium;
use std::sync::{Mutex, OnceLock};
use table_read_parser::script::Config;

static PARSE_LOCK: Mutex<()> = Mutex::new(());
/// PDFium may be bound only once per process, so the first parse opens it and every later one reuses it.
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();

unsafe fn opt_str(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        Some(CStr::from_ptr(p).to_string_lossy().into_owned())
    }
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

fn run(pdf_path: &str, config_json: Option<&str>, pdfium_path: Option<&str>) -> Result<serde_json::Value, String> {
    let config = match config_json {
        Some(j) => Some(Config::from_json(&serde_json::from_str(j).map_err(|e| format!("bad config JSON: {e}"))?)),
        None => None,
    };
    let _guard = PARSE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    // Only a successful open is kept: a wrong first path must not poison later calls. (Held under PARSE_LOCK.)
    if PDFIUM.get().is_none() {
        let opened = table_read_core::open_pdfium(pdfium_path).map_err(|e| format!("could not open PDFium: {e:?}"))?;
        let _ = PDFIUM.set(opened);
    }
    table_read_core::parse_pdf(PDFIUM.get().unwrap(), pdf_path, config.as_ref()).map_err(|e| format!("could not read this PDF: {e:?}"))
}

/// # Safety
/// `pdf_path` must be a valid NUL-terminated string; the other pointers may be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn tr_parse_pdf(pdf_path: *const c_char, config_json: *const c_char, pdfium_path: *const c_char) -> *mut c_char {
    let path = match opt_str(pdf_path) {
        Some(p) => p,
        None => return to_c(r#"{"ok":false,"error":"no PDF path"}"#.into()),
    };
    let (config, pdfium) = (opt_str(config_json), opt_str(pdfium_path));
    // A panic must never unwind across the C boundary.
    let out = std::panic::catch_unwind(|| run(&path, config.as_deref(), pdfium.as_deref()));
    let json = match out {
        Ok(Ok(script)) => serde_json::json!({"ok": true, "script": script}),
        Ok(Err(e)) => serde_json::json!({"ok": false, "error": e}),
        Err(_) => serde_json::json!({"ok": false, "error": "the parser stopped unexpectedly"}),
    };
    to_c(json.to_string())
}

#[no_mangle]
pub extern "C" fn tr_version() -> *mut c_char {
    to_c(table_read_core::PARSER_VERSION.to_string())
}

/// # Safety
/// `s` must be a pointer returned by this library (or NULL), released exactly once.
#[no_mangle]
pub unsafe extern "C" fn tr_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_pdf_is_an_error_string_not_a_crash() {
        let p = CString::new("/nonexistent/file.pdf").unwrap();
        let out = unsafe { tr_parse_pdf(p.as_ptr(), std::ptr::null(), std::ptr::null()) };
        let s = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { tr_free(out) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"].as_str().unwrap().len() > 3);
    }

    #[test]
    fn parsing_twice_in_one_process_works() {
        // the bug the Dart test found: PDFium bound a second time failed
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let pdf = root.join("Test PDFs/synthetic/screenplay_letter.pdf");
        let dylib = std::fs::read_dir(root.join(".venv/lib")).ok().and_then(|d| {
            d.flatten().map(|e| e.path().join("site-packages/pypdfium2_raw/libpdfium.dylib")).find(|p| p.exists())
        });
        let (Some(dylib), true) = (dylib, pdf.exists()) else { return }; // needs the dev venv and test PDFs
        let (p, d) = (CString::new(pdf.to_str().unwrap()).unwrap(), CString::new(dylib.to_str().unwrap()).unwrap());
        for _ in 0..3 {
            let out = unsafe { tr_parse_pdf(p.as_ptr(), std::ptr::null(), d.as_ptr()) };
            let s = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
            unsafe { tr_free(out) };
            assert!(s.starts_with("{\"ok\":true"), "{s}");
        }
    }

    #[test]
    fn null_path_and_version() {
        let out = unsafe { tr_parse_pdf(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        let s = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { tr_free(out) };
        assert!(s.contains("no PDF path"));
        let v = tr_version();
        assert!(unsafe { CStr::from_ptr(v) }.to_str().unwrap().starts_with("rust-"));
        unsafe { tr_free(v) };
        unsafe { tr_free(std::ptr::null_mut()) };
    }
}
