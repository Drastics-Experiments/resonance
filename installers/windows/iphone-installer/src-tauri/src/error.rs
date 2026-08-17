use serde::Serialize;

#[derive(Debug, Serialize, thiserror::Error)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AppError {
    #[error("{message}")]
    Apple { message: String },
    #[error("{message}")]
    Device { message: String },
    #[error("{message}")]
    Installer { message: String },
    #[error("{message}")]
    Resource { message: String },
}

impl AppError {
    pub fn apple(error: impl std::fmt::Display) -> Self {
        Self::Apple {
            message: error.to_string(),
        }
    }

    pub fn device(error: impl std::fmt::Display) -> Self {
        Self::Device {
            message: error.to_string(),
        }
    }

    pub fn installer(error: impl std::fmt::Display) -> Self {
        Self::Installer {
            message: error.to_string(),
        }
    }

    pub fn resource(error: impl std::fmt::Display) -> Self {
        Self::Resource {
            message: error.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::AppError;

    #[test]
    fn serializes_for_the_webview_error_handler() {
        let value = serde_json::to_value(AppError::device("Disconnected")).unwrap();
        assert_eq!(value["type"], "device");
        assert_eq!(value["message"], "Disconnected");
    }
}
