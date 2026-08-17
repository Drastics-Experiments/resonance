use std::{
    fs::File,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use chrono::{Duration as ChronoDuration, Utc};
use reqwest::{Client, header};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter, State};

use crate::{
    account::{SideloaderGuard, SideloaderState},
    device::{SelectedDevice, provider_for, selected_device},
    error::AppError,
};

const LATEST_RELEASE_API: &str =
    "https://api.github.com/repos/Drastics-Experiments/resonance/releases/latest";
const RELEASE_DOWNLOAD_PREFIX: &str =
    "https://github.com/Drastics-Experiments/resonance/releases/download/";
const USER_AGENT: &str = "Resonance-iPhone-Installer";
const MAX_IPA_BYTES: u64 = 256 * 1024 * 1024;
const MAX_CHECKSUM_BYTES: u64 = 4 * 1024;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct InstallStatus {
    step: &'static str,
    message: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallResult {
    installed_at: String,
    expires_at: String,
    version: String,
    device_udid: String,
    device_name: String,
}

#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<GitHubAsset>,
}

#[derive(Debug, Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
    size: u64,
    digest: Option<String>,
}

struct DownloadedIpa {
    _directory: tempfile::TempDir,
    path: PathBuf,
    version: String,
}

fn emit_status(app: &AppHandle, step: &'static str, message: &'static str) {
    let _ = app.emit("install-status", InstallStatus { step, message });
}

fn release_version(tag: &str) -> Result<&str, AppError> {
    let version = tag
        .strip_prefix('v')
        .ok_or_else(|| AppError::resource("The latest GitHub release has an invalid tag."))?;
    let parts: Vec<&str> = version.split('.').collect();
    if parts.len() != 3
        || parts
            .iter()
            .any(|part| part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return Err(AppError::resource(
            "The latest GitHub release is not a semantic version.",
        ));
    }
    Ok(version)
}

fn release_assets(release: &GitHubRelease) -> Result<(&GitHubAsset, &GitHubAsset), AppError> {
    if release.draft || release.prerelease {
        return Err(AppError::resource(
            "GitHub returned a draft or prerelease instead of the latest public release.",
        ));
    }
    let version = release_version(&release.tag_name)?;
    let ipa_name = format!("Resonance-iOS-Device-{version}.ipa");
    let checksum_name = format!("{ipa_name}.sha256");

    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name == ipa_name)
        .ok_or_else(|| {
            AppError::resource(format!(
                "The latest GitHub release ({}) does not contain {ipa_name}.",
                release.tag_name
            ))
        })?;
    let checksum = release
        .assets
        .iter()
        .find(|asset| asset.name == checksum_name)
        .ok_or_else(|| {
            AppError::resource(format!(
                "The latest GitHub release ({}) does not contain {checksum_name}.",
                release.tag_name
            ))
        })?;

    validate_asset_url(release, asset)?;
    validate_asset_url(release, checksum)?;
    Ok((asset, checksum))
}

fn validate_asset_url(release: &GitHubRelease, asset: &GitHubAsset) -> Result<(), AppError> {
    let expected = format!(
        "{RELEASE_DOWNLOAD_PREFIX}{}/{}",
        release.tag_name, asset.name
    );
    if asset.browser_download_url != expected {
        return Err(AppError::resource(format!(
            "The latest GitHub release returned an unexpected URL for {}.",
            asset.name
        )));
    }
    Ok(())
}

fn expected_hash(contents: &str, ipa_name: &str) -> Result<String, AppError> {
    let first_line = contents
        .lines()
        .next()
        .ok_or_else(|| AppError::resource("The release checksum is empty."))?;
    let mut fields = first_line.split_whitespace();
    let hash = fields.next().unwrap_or_default().to_ascii_lowercase();
    let named_file = fields.next().unwrap_or_default().trim_start_matches('*');
    if hash.len() != 64 || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(AppError::resource("The release checksum is invalid."));
    }
    if Path::new(named_file)
        .file_name()
        .and_then(|name| name.to_str())
        != Some(ipa_name)
    {
        return Err(AppError::resource(
            "The release checksum names a different file.",
        ));
    }
    Ok(hash)
}

fn github_client() -> Result<Client, AppError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(180))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(AppError::resource)
}

async fn fetch_latest_release(client: &Client) -> Result<GitHubRelease, AppError> {
    client
        .get(LATEST_RELEASE_API)
        .header(header::ACCEPT, "application/vnd.github+json")
        .header(header::CACHE_CONTROL, "no-cache")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .map_err(AppError::resource)?
        .error_for_status()
        .map_err(AppError::resource)?
        .json()
        .await
        .map_err(AppError::resource)
}

async fn download_checksum(client: &Client, asset: &GitHubAsset) -> Result<String, AppError> {
    if asset.size == 0 || asset.size > MAX_CHECKSUM_BYTES {
        return Err(AppError::resource(
            "The latest release checksum has an invalid size.",
        ));
    }
    let bytes = client
        .get(&asset.browser_download_url)
        .header(header::ACCEPT, "application/octet-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .send()
        .await
        .map_err(AppError::resource)?
        .error_for_status()
        .map_err(AppError::resource)?
        .bytes()
        .await
        .map_err(AppError::resource)?;
    if bytes.is_empty()
        || bytes.len() as u64 > MAX_CHECKSUM_BYTES
        || bytes.len() as u64 != asset.size
    {
        return Err(AppError::resource(
            "The downloaded release checksum has an invalid size.",
        ));
    }
    String::from_utf8(bytes.to_vec()).map_err(AppError::resource)
}

async fn download_verified_ipa(
    client: &Client,
    asset: &GitHubAsset,
    expected: &str,
    destination: &Path,
) -> Result<(), AppError> {
    if asset.size == 0 || asset.size > MAX_IPA_BYTES {
        return Err(AppError::resource(
            "The latest release iPhone build has an invalid size.",
        ));
    }
    let mut response = client
        .get(&asset.browser_download_url)
        .header(header::ACCEPT, "application/octet-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .send()
        .await
        .map_err(AppError::resource)?
        .error_for_status()
        .map_err(AppError::resource)?;
    let mut file = File::create(destination).map_err(AppError::resource)?;
    let mut hasher = Sha256::new();
    let mut downloaded = 0_u64;

    while let Some(chunk) = response.chunk().await.map_err(AppError::resource)? {
        downloaded = downloaded
            .checked_add(chunk.len() as u64)
            .ok_or_else(|| AppError::resource("The release download is too large."))?;
        if downloaded > MAX_IPA_BYTES {
            return Err(AppError::resource("The release download is too large."));
        }
        file.write_all(&chunk).map_err(AppError::resource)?;
        hasher.update(&chunk);
    }
    file.flush().map_err(AppError::resource)?;

    if downloaded != asset.size {
        return Err(AppError::resource(
            "The release download size does not match GitHub's asset metadata.",
        ));
    }
    let actual = hex::encode(hasher.finalize());
    if actual != expected {
        return Err(AppError::resource(
            "The latest release iPhone build failed its SHA-256 check.",
        ));
    }
    if let Some(digest) = &asset.digest {
        if digest != &format!("sha256:{actual}") {
            return Err(AppError::resource(
                "The latest release iPhone build does not match GitHub's digest.",
            ));
        }
    }
    Ok(())
}

async fn download_latest_ipa() -> Result<DownloadedIpa, AppError> {
    let client = github_client()?;
    let release = fetch_latest_release(&client).await?;
    let version = release_version(&release.tag_name)?.to_string();
    let (asset, checksum_asset) = release_assets(&release)?;
    let checksum = download_checksum(&client, checksum_asset).await?;
    let expected = expected_hash(&checksum, &asset.name)?;
    let directory = tempfile::Builder::new()
        .prefix("resonance-iphone-release-")
        .tempdir()
        .map_err(AppError::resource)?;
    let path = directory.path().join(&asset.name);
    download_verified_ipa(&client, asset, &expected, &path).await?;
    Ok(DownloadedIpa {
        _directory: directory,
        path,
        version,
    })
}

#[tauri::command]
pub async fn install_resonance(
    app: AppHandle,
    selected: State<'_, SelectedDevice>,
    sideloader: State<'_, SideloaderState>,
) -> Result<InstallResult, AppError> {
    emit_status(
        &app,
        "verify",
        "Downloading the latest Resonance release from GitHub…",
    );
    let ipa = download_latest_ipa().await?;

    let device = selected_device(&selected)?;
    let provider = provider_for(&device).await?;
    let mut sideloader = SideloaderGuard::take(&sideloader)?;
    emit_status(&app, "profile", "Preparing your Apple development profile…");

    let transfer_started = Arc::new(AtomicBool::new(false));
    let progress_app = app.clone();
    let progress_transfer_started = transfer_started.clone();
    sideloader
        .get_mut()
        .install_app(
            &provider,
            ipa.path,
            false,
            Some(move |progress| {
                let app = progress_app.clone();
                let transfer_started = progress_transfer_started.clone();
                async move {
                    if progress >= 0.99 && !transfer_started.swap(true, Ordering::Relaxed) {
                        emit_status(&app, "transfer", "Installing Resonance on your iPhone…");
                    } else {
                        emit_status(&app, "sign", "Signing Resonance for your Apple Account…");
                    }
                }
            }),
        )
        .await
        .map_err(AppError::installer)?;

    if !transfer_started.load(Ordering::Relaxed) {
        emit_status(&app, "transfer", "Finishing installation on your iPhone…");
    }
    let installed_at = Utc::now();
    Ok(InstallResult {
        installed_at: installed_at.to_rfc3339(),
        expires_at: (installed_at + ChronoDuration::days(7)).to_rfc3339(),
        version: ipa.version,
        device_udid: device.udid,
        device_name: device.name,
    })
}

#[cfg(test)]
mod tests {
    use super::{GitHubAsset, GitHubRelease, expected_hash, release_assets};

    fn asset(name: &str) -> GitHubAsset {
        GitHubAsset {
            name: name.to_string(),
            browser_download_url: format!(
                "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.3/{name}"
            ),
            size: 1,
            digest: None,
        }
    }

    #[test]
    fn accepts_standard_sha256_sidecar() {
        let name = "Resonance-iOS-Device-1.2.3.ipa";
        assert_eq!(
            expected_hash(
                &format!(
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  {name}\n"
                ),
                name,
            )
            .unwrap(),
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        );
    }

    #[test]
    fn selects_only_versioned_device_assets_from_latest_release() {
        let ipa = "Resonance-iOS-Device-1.2.3.ipa";
        let release = GitHubRelease {
            tag_name: "v1.2.3".to_string(),
            draft: false,
            prerelease: false,
            assets: vec![
                asset("Resonance-iOS-Simulator-1.2.3.zip"),
                asset(ipa),
                asset(&format!("{ipa}.sha256")),
            ],
        };
        let (selected, checksum) = release_assets(&release).unwrap();
        assert_eq!(selected.name, ipa);
        assert_eq!(checksum.name, format!("{ipa}.sha256"));
    }

    #[test]
    fn rejects_release_without_device_ipa() {
        let release = GitHubRelease {
            tag_name: "v1.2.3".to_string(),
            draft: false,
            prerelease: false,
            assets: vec![asset("Resonance-iOS-Simulator-1.2.3.zip")],
        };
        assert!(release_assets(&release).is_err());
    }
}
