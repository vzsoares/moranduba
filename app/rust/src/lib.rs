//! MLS group engine for Moranduba: MDK behind one JSON call, so the same
//! code serves the desktop FFI and the browser wasm build.

mod engine;

use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

use engine::{Engine, OpenArgs};

struct Registry {
    next: u32,
    engines: BTreeMap<u32, Engine>,
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        Mutex::new(Registry {
            next: 1,
            engines: BTreeMap::new(),
        })
    })
}

/// Runs `method` on engine `handle`. `open` ignores the handle and returns a
/// new one; `close` drops the engine. Replies `{"ok": …}` or `{"err": "…"}`.
pub fn call(handle: u32, method: &str, args: &str) -> String {
    let reply = match dispatch(handle, method, args) {
        Ok(value) => json!({ "ok": value }),
        Err(message) => json!({ "err": message }),
    };
    reply.to_string()
}

fn dispatch(handle: u32, method: &str, args: &str) -> Result<Value, String> {
    let args: Value = if args.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(args).map_err(|e| e.to_string())?
    };
    let mut registry = registry().lock().map_err(|_| "engine registry poisoned")?;
    match method {
        "open" => {
            let open: OpenArgs = serde_json::from_value(args).map_err(|e| e.to_string())?;
            let engine = Engine::open(open)?;
            let id = registry.next;
            registry.next += 1;
            registry.engines.insert(id, engine);
            Ok(json!(id))
        }
        "close" => {
            registry.engines.remove(&handle);
            Ok(Value::Null)
        }
        _ => registry
            .engines
            .get_mut(&handle)
            .ok_or_else(|| format!("no engine with handle {handle}"))?
            .call(method, args),
    }
}

#[cfg(not(target_arch = "wasm32"))]
mod ffi {
    use std::ffi::{c_char, CStr, CString};

    /// # Safety
    /// `method` and `args` must be valid NUL-terminated UTF-8 strings. The
    /// result must be released with `moranduba_mls_free`.
    #[no_mangle]
    pub unsafe extern "C" fn moranduba_mls_call(
        handle: u32,
        method: *const c_char,
        args: *const c_char,
    ) -> *mut c_char {
        let reply = std::panic::catch_unwind(|| {
            let method = CStr::from_ptr(method).to_string_lossy();
            let args = CStr::from_ptr(args).to_string_lossy();
            super::call(handle, &method, &args)
        })
        .unwrap_or_else(|_| r#"{"err":"engine panicked"}"#.to_string());
        CString::new(reply)
            .unwrap_or_else(|_| CString::from(c"{\"err\":\"reply contained NUL\"}"))
            .into_raw()
    }

    /// # Safety
    /// `reply` must come from `moranduba_mls_call` and be freed once.
    #[no_mangle]
    pub unsafe extern "C" fn moranduba_mls_free(reply: *mut c_char) {
        if !reply.is_null() {
            drop(CString::from_raw(reply));
        }
    }
}

#[cfg(target_arch = "wasm32")]
mod wasm {
    use std::sync::Once;

    use wasm_bindgen::prelude::wasm_bindgen;

    #[wasm_bindgen]
    extern "C" {
        #[wasm_bindgen(js_namespace = console)]
        fn error(message: &str);
    }

    /// A panic traps the instance; afterwards it must be reloaded.
    #[wasm_bindgen(js_name = mlsCall)]
    pub fn mls_call(handle: u32, method: &str, args: &str) -> String {
        static HOOK: Once = Once::new();
        HOOK.call_once(|| {
            std::panic::set_hook(Box::new(|info| error(&format!("moranduba_mls: {info}"))));
        });
        super::call(handle, method, args)
    }
}

#[cfg(test)]
mod tests;
