fn main() {
    // Embed an explicit asInvoker manifest so Windows doesn't auto-elevate the binary
    // based on its name containing "setup". Without this, `cargo test` fails in non-admin
    // terminals with "The requested operation requires elevation" (os error 740).
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
