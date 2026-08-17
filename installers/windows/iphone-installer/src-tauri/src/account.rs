use std::{sync::Mutex, time::Duration};

use futures::FutureExt;
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession},
    sideload::{SideloaderBuilder, builder::MaxCertsBehavior, sideloader::Sideloader},
    util::storage::InMemoryStorage,
};
use rootcause::prelude::*;
use serde::Serialize;
use tauri::{Emitter, Listener, State, Window};

use crate::error::AppError;

pub type SideloaderState = Mutex<Option<Sideloader>>;

pub struct SideloaderGuard<'a> {
    state: &'a SideloaderState,
    sideloader: Option<Sideloader>,
}

impl<'a> SideloaderGuard<'a> {
    pub fn take(state: &'a SideloaderState) -> Result<Self, AppError> {
        let sideloader = state
            .lock()
            .map_err(AppError::installer)?
            .take()
            .ok_or_else(|| AppError::apple("Sign in with Apple before installing."))?;
        Ok(Self {
            state,
            sideloader: Some(sideloader),
        })
    }

    pub fn get_mut(&mut self) -> &mut Sideloader {
        self.sideloader.as_mut().expect("sideloader guard is empty")
    }
}

impl Drop for SideloaderGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock() {
            *state = self.sideloader.take();
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CertificateInfo {
    name: Option<String>,
    serial_number: Option<String>,
    machine_name: Option<String>,
}

async fn build_sideloader(
    window: &Window,
    email: &str,
    password: &str,
) -> Result<Sideloader, AppError> {
    let two_factor = {
        let window = window.clone();
        move |params: TwoFactorCallbackParams| {
            let window = window.clone();
            async move {
                window
                    .emit("2fa-required", params)
                    .context("Failed to request the Apple verification code")?;
                let (sender, receiver) = std::sync::mpsc::channel::<String>();
                let listener = window.listen("2fa-received", move |event| {
                    let value = event.payload().trim_matches('"').to_owned();
                    let _ = sender.send(value);
                });
                let result = receiver.recv_timeout(Duration::from_secs(120));
                window.unlisten(listener);
                let code = result.context("Timed out waiting for the Apple verification code")?;
                Ok(TwoFactorCallbackResponse::SubmitCode(code))
            }
            .boxed()
        }
    };

    let storage = || Box::new(InMemoryStorage::new());
    let normalized_email = email.trim().to_lowercase();
    let provider = RemoteV3AnisetteProvider::default()
        .map_err(AppError::apple)?
        .set_serial_number("0".to_string())
        .set_storage(storage());
    let mut account = AppleAccount::builder(&normalized_email)
        .anisette_provider(provider)
        .login(password, Box::new(two_factor))
        .await
        .map_err(AppError::apple)?;
    let developer_session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(AppError::apple)?;

    let max_certificates = {
        let window = window.clone();
        move |certificates: &Vec<DevelopmentCertificate>| -> Option<Vec<String>> {
            let payload: Vec<CertificateInfo> = certificates
                .iter()
                .map(|certificate| CertificateInfo {
                    name: certificate.name.clone(),
                    serial_number: certificate.serial_number.clone(),
                    machine_name: certificate.machine_name.clone(),
                })
                .collect();
            if window.emit("max-certs-reached", payload).is_err() {
                return None;
            }
            let (sender, receiver) = std::sync::mpsc::channel::<Option<Vec<String>>>();
            let listener = window.listen("max-certs-response", move |event| {
                let response = serde_json::from_str(event.payload()).unwrap_or(None);
                let _ = sender.send(response);
            });
            let response = receiver
                .recv_timeout(Duration::from_secs(300))
                .ok()
                .flatten();
            window.unlisten(listener);
            response
        }
    };

    Ok(SideloaderBuilder::new(developer_session, normalized_email)
        .machine_name("Resonance iPhone Installer".to_string())
        .storage(storage())
        .max_certs_behavior(MaxCertsBehavior::Prompt(Box::new(max_certificates)))
        .build())
}

#[tauri::command]
pub async fn login_new(
    window: Window,
    sideloader: State<'_, SideloaderState>,
    email: String,
    password: String,
) -> Result<(), AppError> {
    let account = build_sideloader(&window, &email, &password).await?;
    *sideloader.lock().map_err(AppError::installer)? = Some(account);
    Ok(())
}
