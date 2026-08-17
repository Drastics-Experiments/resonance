use std::sync::Mutex;

use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};
use serde::{Deserialize, Serialize};
use tauri::State;

use crate::error::AppError;

const CLIENT_NAME: &str = "Resonance iPhone Installer";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub name: String,
    pub id: u32,
    pub udid: String,
    pub connection_type: String,
    pub version: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceScanResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<DeviceInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub type SelectedDevice = Mutex<Option<DeviceInfo>>;

async fn usbmuxd() -> Result<UsbmuxdConnection, AppError> {
    UsbmuxdConnection::default().await.map_err(|error| {
        AppError::device(format!(
            "Apple Mobile Device support is unavailable: {error}"
        ))
    })
}

async fn inspect_device(
    device: &UsbmuxdDevice,
    address: UsbmuxdAddr,
) -> Result<DeviceInfo, AppError> {
    let provider = device.to_provider(address, CLIENT_NAME);
    let mut lockdown = LockdownClient::connect(&provider)
        .await
        .map_err(|error| AppError::device(format!("Unlock and trust this iPhone: {error}")))?;

    let name = lockdown
        .get_value(Some("DeviceName"), None)
        .await
        .map_err(AppError::device)?
        .as_string()
        .ok_or_else(|| AppError::device("The iPhone did not report its name."))?
        .to_string();
    let version = lockdown
        .get_value(Some("ProductVersion"), None)
        .await
        .map_err(AppError::device)?
        .as_string()
        .ok_or_else(|| AppError::device("The iPhone did not report its iOS version."))?
        .to_string();
    let connection_type = match device.connection_type {
        Connection::Usb => "USB",
        Connection::Network(_) => "Network",
        Connection::Unknown(_) => "Unknown",
    }
    .to_string();

    Ok(DeviceInfo {
        name,
        id: device.device_id,
        udid: device.udid.clone(),
        connection_type,
        version,
    })
}

#[tauri::command]
pub async fn list_devices() -> Result<Vec<DeviceScanResult>, AppError> {
    let mut connection = usbmuxd().await?;
    let devices = connection.get_devices().await.map_err(AppError::device)?;
    let address = UsbmuxdAddr::from_env_var().map_err(AppError::device)?;
    let mut results = Vec::with_capacity(devices.len());

    for device in devices {
        match inspect_device(&device, address.clone()).await {
            Ok(device) => results.push(DeviceScanResult {
                device: Some(device),
                error: None,
            }),
            Err(error) => results.push(DeviceScanResult {
                device: None,
                error: Some(error.to_string()),
            }),
        }
    }
    Ok(results)
}

#[tauri::command]
pub async fn select_device(
    device: DeviceInfo,
    selected: State<'_, SelectedDevice>,
) -> Result<(), AppError> {
    let provider = provider_for(&device).await?;
    LockdownClient::connect(&provider)
        .await
        .map_err(|error| AppError::device(format!("Unlock and trust this iPhone: {error}")))?;
    *selected.lock().map_err(AppError::device)? = Some(device);
    Ok(())
}

pub fn selected_device(selected: &SelectedDevice) -> Result<DeviceInfo, AppError> {
    selected
        .lock()
        .map_err(AppError::device)?
        .clone()
        .ok_or_else(|| AppError::device("Select an iPhone before installing."))
}

pub async fn provider_for(device: &DeviceInfo) -> Result<UsbmuxdProvider, AppError> {
    let mut connection = usbmuxd().await?;
    let current = connection
        .get_device(&device.udid)
        .await
        .map_err(|error| AppError::device(format!("The selected iPhone disconnected: {error}")))?;
    let address = UsbmuxdAddr::from_env_var().map_err(AppError::device)?;
    Ok(current.to_provider(address, CLIENT_NAME))
}
