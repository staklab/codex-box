use crate::models::{Account, AccountCredentials};
use base64::{
    engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD},
    Engine,
};
use rand::RngCore;
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Mutex;
use url::Url;

const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const REDIRECT_URI: &str = "http://localhost:1455/auth/callback";
const AUTH_URL: &str = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const SCOPE: &str = "openid profile email offline_access api.connectors.read api.connectors.invoke";

#[derive(Debug, Clone)]
struct PendingFlow {
    verifier: String,
    state: String,
}

#[derive(Default)]
pub struct OAuthService {
    pending: Mutex<HashMap<String, PendingFlow>>,
    client: reqwest::Client,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartedFlow {
    pub flow_id: String,
    pub auth_url: String,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    refresh_token: Option<String>,
    id_token: Option<String>,
    client_id: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

impl OAuthService {
    pub fn start(&self) -> anyhow::Result<StartedFlow> {
        let flow_id = uuid::Uuid::new_v4().to_string();
        let state = uuid::Uuid::new_v4().simple().to_string();
        let mut random = [0_u8; 32];
        rand::rng().fill_bytes(&mut random);
        let verifier = URL_SAFE_NO_PAD.encode(random);
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let mut url = Url::parse(AUTH_URL)?;
        url.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", CLIENT_ID)
            .append_pair("redirect_uri", REDIRECT_URI)
            .append_pair("scope", SCOPE)
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("id_token_add_organizations", "true")
            .append_pair("codex_cli_simplified_flow", "true")
            .append_pair("state", &state)
            .append_pair("originator", "Codex Desktop");
        self.pending
            .lock()
            .unwrap()
            .insert(flow_id.clone(), PendingFlow { verifier, state });
        Ok(StartedFlow {
            flow_id,
            auth_url: url.to_string(),
        })
    }

    pub async fn complete(
        &self,
        flow_id: &str,
        callback: &str,
    ) -> anyhow::Result<(Account, AccountCredentials)> {
        let flow = self
            .pending
            .lock()
            .unwrap()
            .get(flow_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("登录流程不存在或已经过期"))?;
        let (code, returned_state) = parse_callback(callback)?;
        if returned_state
            .as_deref()
            .is_some_and(|state| state != flow.state)
        {
            anyhow::bail!("OAuth state 校验失败");
        }
        let response = self
            .client
            .post(TOKEN_URL)
            .form(&[
                ("grant_type", "authorization_code"),
                ("client_id", CLIENT_ID),
                ("code", code.as_str()),
                ("redirect_uri", REDIRECT_URI),
                ("code_verifier", flow.verifier.as_str()),
            ])
            .send()
            .await?
            .json::<TokenResponse>()
            .await?;
        if let Some(error) = response.error {
            anyhow::bail!(
                "{}: {}",
                error,
                response.error_description.unwrap_or_default()
            );
        }
        let credentials = AccountCredentials {
            access_token: response
                .access_token
                .ok_or_else(|| anyhow::anyhow!("授权响应缺少 access_token"))?,
            refresh_token: response
                .refresh_token
                .ok_or_else(|| anyhow::anyhow!("授权响应缺少 refresh_token"))?,
            id_token: response
                .id_token
                .ok_or_else(|| anyhow::anyhow!("授权响应缺少 id_token"))?,
            client_id: response.client_id.or_else(|| Some(CLIENT_ID.to_owned())),
        };
        let account = account_from_credentials(&credentials)?;
        self.pending.lock().unwrap().remove(flow_id);
        Ok((account, credentials))
    }
}

fn parse_callback(input: &str) -> anyhow::Result<(String, Option<String>)> {
    let trimmed = input.trim();
    if let Ok(url) = Url::parse(trimmed) {
        let pairs: HashMap<_, _> = url.query_pairs().into_owned().collect();
        let code = pairs
            .get("code")
            .filter(|value| !value.is_empty())
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("回调链接缺少 code"))?;
        return Ok((code, pairs.get("state").cloned()));
    }
    if trimmed.is_empty() {
        anyhow::bail!("授权码为空");
    }
    Ok((trimmed.to_owned(), None))
}

fn decode_claims(token: &str) -> anyhow::Result<Value> {
    let payload = token
        .split('.')
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("Token 格式无效"))?;
    let bytes = URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| URL_SAFE.decode(payload))?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn string_claim(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

pub(crate) fn account_from_credentials(
    credentials: &AccountCredentials,
) -> anyhow::Result<Account> {
    let access = decode_claims(&credentials.access_token)?;
    let id = decode_claims(&credentials.id_token)?;
    let auth = access
        .get("https://api.openai.com/auth")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow::anyhow!("Token 缺少 OpenAI 账号信息"))?;
    let remote_id = string_claim(auth.get("chatgpt_account_id"));
    let local_id = string_claim(auth.get("chatgpt_account_user_id"))
        .or_else(|| {
            let user = string_claim(auth.get("chatgpt_user_id"))
                .or_else(|| string_claim(auth.get("user_id")))?;
            Some(
                remote_id
                    .as_ref()
                    .map_or(user.clone(), |remote| format!("{user}__{remote}")),
            )
        })
        .or_else(|| remote_id.clone())
        .ok_or_else(|| anyhow::anyhow!("Token 缺少账号 ID"))?;
    Ok(Account {
        id: local_id,
        email: string_claim(id.get("email")).unwrap_or_default(),
        openai_account_id: remote_id.unwrap_or_default(),
        plan_type: string_claim(auth.get("chatgpt_plan_type")).unwrap_or_else(|| "free".into()),
        primary_used_percent: 0.0,
        secondary_used_percent: 0.0,
        primary_reset_at: None,
        secondary_reset_at: None,
        last_checked: None,
        is_active: true,
        is_suspended: false,
        token_expired: false,
        organization_name: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifier_and_authorization_url_use_pkce() {
        let service = OAuthService::default();
        let flow = service.start().unwrap();
        let url = Url::parse(&flow.auth_url).unwrap();
        let query: HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query.get("code_challenge_method").unwrap(), "S256");
        assert_eq!(query.get("redirect_uri").unwrap(), REDIRECT_URI);
        assert!(!query.get("state").unwrap().is_empty());
    }

    #[test]
    fn callback_requires_code() {
        assert!(parse_callback("http://localhost:1455/auth/callback?state=x").is_err());
        assert_eq!(parse_callback("plain-code").unwrap().0, "plain-code");
    }
}
