fn main() {
    // Embed asInvoker intentionally: all setup writes are HKCU (user PATH) and
    // %LOCALAPPDATA% (install root, plugins, config) — no elevation required.
    #[cfg(target_os = "windows")]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_manifest(include_str!("manifest.xml"));
        if let Err(e) = res.compile() {
            // Non-fatal: rc.exe may not be present in all environments (e.g. Linux cross-compile).
            // The binary still works; it just won't have the embedded manifest on those builds.
            eprintln!("cargo:warning=winresource compile failed (manifest not embedded): {e}");
        }
    }
}
