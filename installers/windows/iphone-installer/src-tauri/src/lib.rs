mod account;
mod device;
mod error;
mod installer;

use account::{SideloaderState, login_new};
use device::{SelectedDevice, list_devices, select_device};
use installer::install_resonance;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(SelectedDevice::new(None))
        .manage(SideloaderState::new(None))
        .invoke_handler(tauri::generate_handler![
            list_devices,
            select_device,
            login_new,
            install_resonance,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Resonance iPhone Installer");
}
