// The Sentry DSN is public and has one source of truth: the macOS app's Diagnostics.plist.
fn main() {
    let plist = "../../app/Diagnostics.plist";
    println!("cargo:rerun-if-changed={plist}");
    let text = std::fs::read_to_string(plist).unwrap_or_default();
    let dsn = text
        .split("<key>SentryDSN</key>")
        .nth(1)
        .and_then(|rest| rest.split("<string>").nth(1))
        .and_then(|rest| rest.split("</string>").next())
        .map(str::trim)
        .filter(|dsn| dsn.starts_with("https://") && dsn.contains(".sentry.io/"))
        .unwrap_or("");
    println!("cargo:rustc-env=LIMITFUEL_SENTRY_DSN={dsn}");
    tauri_build::build();
}
