#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install the rustls crypto provider");
    isideload::init().expect("failed to initialize signing error reporting");
    resonance_iphone_installer_lib::run();
}
