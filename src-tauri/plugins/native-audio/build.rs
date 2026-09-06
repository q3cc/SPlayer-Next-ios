fn main() {
    tauri_plugin::Builder::new(&[
        "load",
        "control",
        "configure",
        "metadata",
        "status",
        "visibility",
        "siri",
        "readMetadata",
        "register_listener",
        "remove_listener",
    ])
    .ios_path("ios")
    .build();
}
