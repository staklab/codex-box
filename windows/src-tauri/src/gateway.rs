use crate::models::{Account, AccountCredentials, GatewayStatus, Provider};
use axum::{
    body::{Body, Bytes},
    extract::State,
    http::{HeaderMap, HeaderValue, StatusCode, Uri},
    response::Response,
    routing::post,
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;

#[derive(Clone)]
struct GatewayDeps {
    bearer_token: String,
    account_header: Option<String>,
    upstream_base: String,
    api_key: String,
    client: reqwest::Client,
}

pub struct GatewayRuntime {
    pub status: GatewayStatus,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for GatewayRuntime {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn start(
    account: Account,
    credentials: AccountCredentials,
) -> anyhow::Result<GatewayRuntime> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let mut key_bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut key_bytes);
    let api_key = format!("cbx_{}", URL_SAFE_NO_PAD.encode(key_bytes));
    let status = GatewayStatus {
        base_url: format!("http://127.0.0.1:{}/v1", address.port()),
        api_key: api_key.clone(),
        account_id: account.id.clone(),
        account_email: account.email.clone(),
        route_model: None,
    };
    let deps = GatewayDeps {
        bearer_token: credentials.access_token,
        account_header: Some(account.remote_account_id().to_owned()),
        upstream_base: "https://chatgpt.com/backend-api/codex".into(),
        api_key,
        client: reqwest::Client::builder().build()?,
    };
    serve(listener, status, deps).await
}

pub async fn start_provider(
    provider: Provider,
    api_token: String,
) -> anyhow::Result<GatewayRuntime> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let mut key_bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut key_bytes);
    let api_key = format!("cbx_{}", URL_SAFE_NO_PAD.encode(key_bytes));
    let status = GatewayStatus {
        base_url: format!("http://127.0.0.1:{}/v1", address.port()),
        api_key: api_key.clone(),
        account_id: provider.id.clone(),
        account_email: provider.label.clone(),
        route_model: Some(provider.model.clone()),
    };
    let deps = GatewayDeps {
        bearer_token: api_token,
        account_header: None,
        upstream_base: provider.base_url.trim_end_matches('/').to_owned(),
        api_key,
        client: reqwest::Client::builder().build()?,
    };
    serve(listener, status, deps).await
}

async fn serve(
    listener: tokio::net::TcpListener,
    status: GatewayStatus,
    deps: GatewayDeps,
) -> anyhow::Result<GatewayRuntime> {
    let router = Router::new()
        .route("/v1/responses", post(proxy_responses))
        .route("/responses", post(proxy_responses))
        .route("/backend-api/codex/responses", post(proxy_responses))
        .route("/v1/responses/compact", post(proxy_compact))
        .route("/responses/compact", post(proxy_compact))
        .with_state(deps);
    let task = tokio::spawn(async move {
        if let Err(error) = axum::serve(listener, router).await {
            eprintln!("codex-box gateway stopped: {error}");
        }
    });
    Ok(GatewayRuntime { status, task })
}

async fn proxy_responses(
    state: State<GatewayDeps>,
    headers: HeaderMap,
    uri: Uri,
    body: Bytes,
) -> Response<Body> {
    proxy(state.0, headers, uri, body, "responses").await
}

async fn proxy_compact(
    state: State<GatewayDeps>,
    headers: HeaderMap,
    uri: Uri,
    body: Bytes,
) -> Response<Body> {
    proxy(state.0, headers, uri, body, "responses/compact").await
}

async fn proxy(
    deps: GatewayDeps,
    headers: HeaderMap,
    _uri: Uri,
    body: Bytes,
    upstream_path: &str,
) -> Response<Body> {
    let expected = format!("Bearer {}", deps.api_key);
    if headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        != Some(expected.as_str())
    {
        return json_error(StatusCode::UNAUTHORIZED, "本地网关密钥无效");
    }
    let upstream = format!("{}/{}", deps.upstream_base, upstream_path);
    let mut request = deps
        .client
        .post(upstream)
        .body(body)
        .bearer_auth(&deps.bearer_token)
        .header("originator", "Codex Desktop")
        .header("OpenAI-Beta", "responses=experimental");
    if let Some(account) = &deps.account_header {
        request = request.header("chatgpt-account-id", account);
    }
    for name in [
        "content-type",
        "accept",
        "version",
        "session_id",
        "conversation_id",
        "user-agent",
    ] {
        if let Some(value) = headers.get(name) {
            request = request.header(name, value);
        }
    }
    let upstream_response = match request.send().await {
        Ok(response) => response,
        Err(error) => {
            return json_error(
                StatusCode::BAD_GATEWAY,
                &format!("无法连接 OpenAI 上游：{error}"),
            )
        }
    };
    let status = upstream_response.status();
    let upstream_headers = upstream_response.headers().clone();
    let mut builder = Response::builder().status(status);
    for name in [
        "content-type",
        "cache-control",
        "openai-request-id",
        "x-request-id",
    ] {
        if let Some(value) = upstream_headers.get(name) {
            builder = builder.header(name, value);
        }
    }
    builder
        .body(Body::from_stream(upstream_response.bytes_stream()))
        .unwrap_or_else(|_| json_error(StatusCode::INTERNAL_SERVER_ERROR, "无法建立上游响应"))
}

fn json_error(status: StatusCode, message: &str) -> Response<Body> {
    let body = serde_json::json!({"error":{"message":message}}).to_string();
    Response::builder()
        .status(status)
        .header("content-type", HeaderValue::from_static("application/json"))
        .body(Body::from(body))
        .expect("静态响应构建失败")
}

#[cfg(test)]
mod tests {
    use super::*;
    use httpmock::Method::POST;
    use httpmock::MockServer;

    #[tokio::test]
    async fn gateway_binds_only_to_loopback_and_uses_random_key() {
        let account = Account {
            id: "a".into(),
            email: "a@example.com".into(),
            openai_account_id: "org".into(),
            plan_type: "plus".into(),
            primary_used_percent: 0.0,
            secondary_used_percent: 0.0,
            primary_reset_at: None,
            secondary_reset_at: None,
            last_checked: None,
            is_active: true,
            is_suspended: false,
            token_expired: false,
            organization_name: None,
        };
        let credentials = AccountCredentials {
            access_token: "secret".into(),
            refresh_token: "refresh".into(),
            id_token: "id".into(),
            client_id: None,
        };
        let runtime = start(account, credentials).await.unwrap();
        assert!(runtime.status.base_url.starts_with("http://127.0.0.1:"));
        assert!(runtime.status.api_key.starts_with("cbx_"));
        assert!(runtime.status.api_key.len() > 30);
    }

    #[tokio::test]
    async fn provider_gateway_routes_to_the_configured_responses_endpoint() {
        let upstream = MockServer::start_async().await;
        let response_mock = upstream
            .mock_async(|when, then| {
                when.method(POST)
                    .path("/v1/responses")
                    .header("authorization", "Bearer provider-key");
                then.status(200)
                    .header("content-type", "application/json")
                    .body(r#"{"ok":true}"#);
            })
            .await;
        let provider = Provider {
            id: "provider".into(),
            label: "Provider".into(),
            kind: "openAiCompatible".into(),
            base_url: format!("{}/v1", upstream.base_url()),
            model: "model".into(),
            accounts: Vec::new(),
            active_account_id: None,
        };
        let runtime = start_provider(provider, "provider-key".into())
            .await
            .unwrap();
        let response = reqwest::Client::new()
            .post(format!("{}/responses", runtime.status.base_url))
            .bearer_auth(&runtime.status.api_key)
            .json(&serde_json::json!({"model":"model"}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        response_mock.assert_async().await;
    }
}
