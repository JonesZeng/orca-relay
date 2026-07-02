use std::{borrow::Cow, collections::HashMap, sync::Arc};

use anyhow::{anyhow, bail, Context, Result};
use axum::{
    extract::{
        ws::{close_code, CloseFrame, Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{mpsc, RwLock};

type Tx = mpsc::UnboundedSender<Message>;

#[derive(Clone)]
struct AppState {
    config: RelayConfig,
    sessions: Arc<RwLock<HashMap<String, Session>>>,
}

#[derive(Clone, Default)]
struct Session {
    server: Option<Tx>,
    clients: HashMap<String, Tx>,
}

pub fn rewrite_pairing_code(input: &str, local_endpoint: &str) -> Result<String> {
    let pairing_code = parse_pairing_code_input(input)?;
    let decoded = URL_SAFE_NO_PAD
        .decode(pairing_code.payload.as_bytes())
        .context("invalid pairing code encoding")?;
    let mut offer: Value =
        serde_json::from_slice(&decoded).context("invalid pairing code payload")?;
    let offer_object = offer
        .as_object_mut()
        .ok_or_else(|| anyhow!("invalid pairing code payload"))?;

    if offer_object.get("v").and_then(Value::as_u64) != Some(2) {
        bail!("unsupported pairing code version");
    }

    for field in ["endpoint", "deviceToken", "publicKeyB64"] {
        if !matches!(offer_object.get(field), Some(value) if value.is_string()) {
            bail!("invalid pairing code payload");
        }
    }

    offer_object.insert(
        "endpoint".to_string(),
        Value::String(local_endpoint.to_string()),
    );

    let encoded = URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(&offer).context("failed to encode pairing code payload")?);

    Ok(match pairing_code.shape {
        PairingCodeShape::Bare => encoded,
        PairingCodeShape::DeepLink => format!("orca://pair?code={encoded}"),
        PairingCodeShape::WebClient { prefix, suffix } => {
            let inner = format!("orca://pair?code={encoded}");
            format!("{prefix}{}{suffix}", encode_uri_component(&inner))
        }
    })
}

struct PairingCodeInput<'a> {
    payload: Cow<'a, str>,
    shape: PairingCodeShape<'a>,
}

enum PairingCodeShape<'a> {
    Bare,
    DeepLink,
    WebClient { prefix: &'a str, suffix: &'a str },
}

fn parse_pairing_code_input(input: &str) -> Result<PairingCodeInput<'_>> {
    let input = input.trim();
    if input.is_empty() {
        bail!("invalid pairing code payload");
    }

    if starts_with_ignore_ascii_case(input, "orca://") {
        return parse_orca_pairing_link(input);
    }

    if starts_with_ignore_ascii_case(input, "http://")
        || starts_with_ignore_ascii_case(input, "https://")
    {
        return parse_web_client_pairing_link(input);
    }

    Ok(PairingCodeInput {
        payload: Cow::Borrowed(input),
        shape: PairingCodeShape::Bare,
    })
}

fn parse_orca_pairing_link(input: &str) -> Result<PairingCodeInput<'_>> {
    Ok(PairingCodeInput {
        payload: Cow::Borrowed(pairing_payload_from_orca_link(input)?),
        shape: PairingCodeShape::DeepLink,
    })
}

fn pairing_payload_from_orca_link(input: &str) -> Result<&str> {
    let rest = &input["orca://".len()..];
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let host = &rest[..authority_end];
    if !host.eq_ignore_ascii_case("pair") {
        bail!("invalid pairing code link");
    }

    let after_authority = &rest[authority_end..];
    let path_end = after_authority
        .find(['?', '#'])
        .unwrap_or(after_authority.len());
    let path = &after_authority[..path_end];
    if !path.is_empty() && path != "/" {
        bail!("invalid pairing code link");
    }

    if let Some(query_start) = input.find('?') {
        let query_end = input[query_start + 1..]
            .find('#')
            .map_or(input.len(), |offset| query_start + 1 + offset);
        for pair in input[query_start + 1..query_end].split('&') {
            if let Some(payload) = pair
                .strip_prefix("code=")
                .filter(|payload| !payload.is_empty())
            {
                return Ok(payload);
            }
        }
    }

    if let Some(hash_start) = input.find('#') {
        let payload = &input[hash_start + 1..];
        if !payload.is_empty() {
            return Ok(payload);
        }
    }

    bail!("invalid pairing code link");
}

fn parse_web_client_pairing_link(input: &str) -> Result<PairingCodeInput<'_>> {
    let fragment_start = input
        .find('#')
        .ok_or_else(|| anyhow!("invalid web client pairing link"))?
        + 1;
    let mut cursor = fragment_start;

    while cursor <= input.len() {
        let segment_end = input[cursor..]
            .find('&')
            .map_or(input.len(), |offset| cursor + offset);
        let segment = &input[cursor..segment_end];

        if let Some(value_offset) = segment.find('=') {
            if &segment[..value_offset] == "pairing" {
                let value_start = cursor + value_offset + 1;
                if value_start == segment_end {
                    bail!("invalid web client pairing link");
                }
                let decoded = percent_decode_fragment_value(&input[value_start..segment_end])?;
                let payload = if starts_with_ignore_ascii_case(&decoded, "orca://") {
                    pairing_payload_from_orca_link(&decoded)?.to_string()
                } else {
                    decoded
                };
                return Ok(PairingCodeInput {
                    payload: Cow::Owned(payload),
                    shape: PairingCodeShape::WebClient {
                        prefix: &input[..value_start],
                        suffix: &input[segment_end..],
                    },
                });
            }
        }

        if segment_end == input.len() {
            break;
        }
        cursor = segment_end + 1;
    }

    bail!("invalid web client pairing link");
}

fn percent_decode_fragment_value(input: &str) -> Result<String> {
    let mut output = Vec::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = bytes
                .get(index + 1)
                .and_then(|byte| hex_value(*byte))
                .ok_or_else(|| anyhow!("invalid web client pairing link"))?;
            let low = bytes
                .get(index + 2)
                .and_then(|byte| hex_value(*byte))
                .ok_or_else(|| anyhow!("invalid web client pairing link"))?;
            output.push(high << 4 | low);
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }

    String::from_utf8(output).context("invalid web client pairing link")
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn encode_uri_component(input: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";

    let mut output = String::with_capacity(input.len());
    for byte in input.bytes() {
        if byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')'
            )
        {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(HEX[(byte >> 4) as usize] as char);
            output.push(HEX[(byte & 0x0f) as usize] as char);
        }
    }
    output
}

fn starts_with_ignore_ascii_case(input: &str, prefix: &str) -> bool {
    input
        .get(..prefix.len())
        .is_some_and(|actual| actual.eq_ignore_ascii_case(prefix))
}

pub fn app(config: RelayConfig) -> Router {
    let state = AppState {
        config,
        sessions: Arc::new(RwLock::new(HashMap::new())),
    };

    Router::new()
        .route("/health", get(health))
        .route("/ws", get(ws_handler))
        .with_state(state)
}

#[derive(Clone, Debug)]
pub struct RelayConfig {
    pub version: String,
    pub relay_token: String,
}

impl RelayConfig {
    pub fn new(version: impl Into<String>, relay_token: impl Into<String>) -> Self {
        Self {
            version: version.into(),
            relay_token: relay_token.into(),
        }
    }
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    version: String,
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: state.config.version,
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WsParams {
    role: String,
    server_id: String,
    client_id: Option<String>,
    v: String,
}

async fn ws_handler(
    State(state): State<AppState>,
    Query(params): Query<WsParams>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !authorized(&headers, &state.config.relay_token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if params.v != "1" {
        return StatusCode::BAD_REQUEST.into_response();
    }

    match params.role.as_str() {
        "server" => ws
            .on_upgrade(move |socket| handle_server(socket, state, params.server_id))
            .into_response(),
        "client" => {
            let Some(client_id) = params.client_id else {
                return StatusCode::BAD_REQUEST.into_response();
            };
            let has_server = {
                let sessions = state.sessions.read().await;
                sessions
                    .get(&params.server_id)
                    .and_then(|session| session.server.as_ref())
                    .is_some()
            };
            if !has_server {
                return StatusCode::SERVICE_UNAVAILABLE.into_response();
            }

            ws.on_upgrade(move |socket| handle_client(socket, state, params.server_id, client_id))
                .into_response()
        }
        _ => StatusCode::BAD_REQUEST.into_response(),
    }
}

fn authorized(headers: &HeaderMap, token: &str) -> bool {
    let Some(value) = headers.get(AUTHORIZATION) else {
        return false;
    };
    value
        .to_str()
        .map(|value| value == format!("Bearer {token}"))
        .unwrap_or(false)
}

async fn handle_server(socket: WebSocket, state: AppState, server_id: String) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let old_server = {
        let mut sessions = state.sessions.write().await;
        let session = sessions.entry(server_id.clone()).or_default();
        session.server.replace(tx.clone())
    };
    if let Some(old_server) = old_server {
        let _ = old_server.send(Message::Close(Some(CloseFrame {
            code: close_code::NORMAL,
            reason: "server replaced".into(),
        })));
    }

    let (mut writer, mut reader) = socket.split();
    let writer_task = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if writer.send(message).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(message)) = reader.next().await {
        match message {
            Message::Binary(frame) => {
                if let Some(client_id) = frame_client_id(&frame) {
                    let client = {
                        let sessions = state.sessions.read().await;
                        sessions
                            .get(&server_id)
                            .and_then(|session| session.clients.get(&client_id))
                            .cloned()
                    };
                    if let Some(client) = client {
                        let _ = client.send(Message::Binary(frame));
                    }
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    {
        let mut sessions = state.sessions.write().await;
        if let Some(session) = sessions.get_mut(&server_id) {
            if session
                .server
                .as_ref()
                .map(|current| current.same_channel(&tx))
                .unwrap_or(false)
            {
                session.server = None;
            }
            if session.server.is_none() && session.clients.is_empty() {
                sessions.remove(&server_id);
            }
        }
    }
    writer_task.abort();
}

async fn handle_client(socket: WebSocket, state: AppState, server_id: String, client_id: String) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    {
        let mut sessions = state.sessions.write().await;
        let Some(session) = sessions.get_mut(&server_id) else {
            let _ = tx.send(Message::Close(Some(CloseFrame {
                code: close_code::AGAIN,
                reason: "server absent".into(),
            })));
            return;
        };
        if session.server.is_none() {
            let _ = tx.send(Message::Close(Some(CloseFrame {
                code: close_code::AGAIN,
                reason: "server absent".into(),
            })));
            return;
        }
        if let Some(old_client) = session.clients.insert(client_id.clone(), tx.clone()) {
            let _ = old_client.send(Message::Close(Some(CloseFrame {
                code: close_code::NORMAL,
                reason: "client replaced".into(),
            })));
        }
    }

    let (mut writer, mut reader) = socket.split();
    let writer_task = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if writer.send(message).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(message)) = reader.next().await {
        match message {
            Message::Binary(frame) => {
                let server = {
                    let sessions = state.sessions.read().await;
                    sessions
                        .get(&server_id)
                        .and_then(|session| session.server.as_ref())
                        .cloned()
                };
                if let Some(server) = server {
                    let _ = server.send(Message::Binary(frame));
                } else {
                    break;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    {
        let mut sessions = state.sessions.write().await;
        if let Some(session) = sessions.get_mut(&server_id) {
            if session
                .clients
                .get(&client_id)
                .map(|current| current.same_channel(&tx))
                .unwrap_or(false)
            {
                session.clients.remove(&client_id);
            }
            if session.server.is_none() && session.clients.is_empty() {
                sessions.remove(&server_id);
            }
        }
    }
    writer_task.abort();
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayHeader {
    client_id: String,
}

fn frame_client_id(frame: &[u8]) -> Option<String> {
    let header_len = u32::from_be_bytes(frame.get(0..4)?.try_into().ok()?) as usize;
    let header_end = 4usize.checked_add(header_len)?;
    let header = frame.get(4..header_end)?;
    serde_json::from_slice::<RelayHeader>(header)
        .ok()
        .map(|header| header.client_id)
}

pub mod adapter {
    use std::{
        collections::HashMap,
        fmt::Write as _,
        net::SocketAddr,
        sync::{
            atomic::{AtomicU64, Ordering},
            Arc,
        },
    };

    use anyhow::{anyhow, bail, Context, Result};
    use axum::{
        extract::{
            ws::{
                CloseFrame as AxumCloseFrame, Message as AxumMessage, WebSocket, WebSocketUpgrade,
            },
            State,
        },
        response::IntoResponse,
        routing::get,
        Router,
    };
    use futures_util::{SinkExt, StreamExt};
    use rustls::crypto::{ring, CryptoProvider};
    use serde::{Deserialize, Serialize};
    use tokio::{net::TcpListener, sync::mpsc, task::JoinHandle};
    use tokio_tungstenite::{
        connect_async,
        tungstenite::{
            client::IntoClientRequest,
            http::{header::AUTHORIZATION as WS_AUTHORIZATION, HeaderValue},
            protocol::{frame::coding::CloseCode, CloseFrame as TungsteniteCloseFrame},
            Message as TungsteniteMessage,
        },
        MaybeTlsStream, WebSocketStream,
    };

    type RelayWebSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

    #[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
    #[serde(rename_all = "snake_case")]
    pub enum AdapterDirection {
        ClientToServer,
        ServerToClient,
    }

    #[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
    #[serde(rename_all = "snake_case")]
    pub enum AdapterOpcode {
        Text,
        Binary,
        Close,
    }

    #[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    pub struct AdapterFrameHeader {
        pub client_id: String,
        pub connection_id: String,
        pub direction: AdapterDirection,
        pub opcode: AdapterOpcode,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub close_code: Option<u16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub close_reason: Option<String>,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct AdapterFrame {
        pub header: AdapterFrameHeader,
        pub payload: Vec<u8>,
    }

    #[derive(Clone, Debug)]
    pub struct ProxyConfig {
        pub bind_addr: SocketAddr,
        pub relay_url: String,
        pub server_id: String,
        pub relay_token: String,
        pub client_id: String,
    }

    #[derive(Clone, Debug)]
    pub struct BridgeConfig {
        pub relay_url: String,
        pub local_runtime_url: String,
        pub server_id: String,
        pub relay_token: String,
    }

    pub struct ProxyHandle {
        local_addr: SocketAddr,
        task: JoinHandle<()>,
    }

    impl ProxyHandle {
        pub fn local_addr(&self) -> SocketAddr {
            self.local_addr
        }
    }

    impl Drop for ProxyHandle {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    pub struct BridgeHandle {
        task: JoinHandle<()>,
    }

    impl Drop for BridgeHandle {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    pub fn encode_adapter_frame(frame: &AdapterFrame) -> Result<Vec<u8>> {
        let header =
            serde_json::to_vec(&frame.header).context("failed to encode adapter header")?;
        let header_len = u32::try_from(header.len()).context("adapter header too large")?;
        let mut encoded = Vec::with_capacity(4 + header.len() + frame.payload.len());
        encoded.extend_from_slice(&header_len.to_be_bytes());
        encoded.extend_from_slice(&header);
        encoded.extend_from_slice(&frame.payload);
        Ok(encoded)
    }

    pub fn decode_adapter_frame(frame: &[u8]) -> Result<AdapterFrame> {
        if frame.len() < 4 {
            bail!("adapter frame missing header length");
        }

        let header_len =
            u32::from_be_bytes(frame[0..4].try_into().expect("slice has 4 bytes")) as usize;
        let header_end = 4usize
            .checked_add(header_len)
            .ok_or_else(|| anyhow!("adapter header length overflow"))?;
        let header = frame
            .get(4..header_end)
            .ok_or_else(|| anyhow!("adapter frame shorter than declared header length"))?;

        Ok(AdapterFrame {
            header: serde_json::from_slice(header).context("failed to decode adapter header")?,
            payload: frame[header_end..].to_vec(),
        })
    }

    pub async fn run_proxy(config: ProxyConfig) -> Result<ProxyHandle> {
        install_tls_provider();
        let listener = TcpListener::bind(config.bind_addr)
            .await
            .context("failed to bind local proxy listener")?;
        let local_addr = listener
            .local_addr()
            .context("failed to read local proxy address")?;
        let state = ProxyState {
            relay_url: config.relay_url,
            server_id: config.server_id,
            relay_token: config.relay_token,
            client_id: config.client_id,
            next_connection_id: Arc::new(AtomicU64::new(1)),
        };
        let app = Router::new()
            .route("/ws", get(proxy_ws_handler))
            .with_state(state);
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        Ok(ProxyHandle { local_addr, task })
    }

    pub async fn run_bridge(config: BridgeConfig) -> Result<BridgeHandle> {
        install_tls_provider();
        let relay_url = relay_url(
            &config.relay_url,
            &[
                ("role", "server"),
                ("serverId", &config.server_id),
                ("v", "1"),
            ],
        );
        let relay = connect_with_bearer(&relay_url, &config.relay_token)
            .await
            .context("failed to connect bridge to relay")?;
        let task = tokio::spawn(async move {
            let _ = bridge_loop(config, relay).await;
        });
        tokio::task::yield_now().await;
        Ok(BridgeHandle { task })
    }

    #[derive(Clone)]
    struct ProxyState {
        relay_url: String,
        server_id: String,
        relay_token: String,
        client_id: String,
        next_connection_id: Arc<AtomicU64>,
    }

    impl ProxyState {
        fn next_connection_id(&self) -> String {
            let id = self.next_connection_id.fetch_add(1, Ordering::Relaxed);
            format!("{}-{id}", self.client_id)
        }
    }

    async fn proxy_ws_handler(
        State(state): State<ProxyState>,
        ws: WebSocketUpgrade,
    ) -> impl IntoResponse {
        ws.on_upgrade(move |socket| async move {
            let _ = handle_proxy_ws(socket, state).await;
        })
    }

    async fn handle_proxy_ws(socket: WebSocket, state: ProxyState) -> Result<()> {
        let connection_id = state.next_connection_id();
        let relay_client_id = connection_id.clone();
        let relay_url = relay_url(
            &state.relay_url,
            &[
                ("role", "client"),
                ("serverId", &state.server_id),
                ("clientId", &relay_client_id),
                ("v", "1"),
            ],
        );
        let relay = connect_with_bearer(&relay_url, &state.relay_token)
            .await
            .context("failed to connect proxy to relay")?;

        let (mut local_tx, mut local_rx) = socket.split();
        let (mut relay_tx, mut relay_rx) = relay.split();

        let client_id = relay_client_id;
        let to_relay = async {
            while let Some(message) = local_rx.next().await {
                let message = message.context("failed to read local websocket message")?;
                let Some((frame, closes_connection)) =
                    adapter_frame_from_axum(message, &client_id, &connection_id)
                else {
                    continue;
                };
                relay_tx
                    .send(TungsteniteMessage::Binary(encode_adapter_frame(&frame)?))
                    .await
                    .context("failed to write relay websocket message")?;
                if closes_connection {
                    break;
                }
            }
            Ok::<(), anyhow::Error>(())
        };

        let to_local = async {
            while let Some(message) = relay_rx.next().await {
                match message.context("failed to read relay websocket message")? {
                    TungsteniteMessage::Binary(frame) => {
                        let frame = decode_adapter_frame(&frame)?;
                        if frame.header.connection_id != connection_id
                            || frame.header.direction != AdapterDirection::ServerToClient
                        {
                            continue;
                        }
                        let closes_connection = frame.header.opcode == AdapterOpcode::Close;
                        local_tx
                            .send(axum_message_from_adapter_frame(frame)?)
                            .await
                            .context("failed to write local websocket message")?;
                        if closes_connection {
                            break;
                        }
                    }
                    TungsteniteMessage::Close(_) => break,
                    _ => {}
                }
            }
            Ok::<(), anyhow::Error>(())
        };

        tokio::select! {
            result = to_relay => result?,
            result = to_local => result?,
        }

        Ok(())
    }

    async fn bridge_loop(config: BridgeConfig, relay: RelayWebSocket) -> Result<()> {
        let (mut relay_writer, mut relay_reader) = relay.split();
        let (relay_tx, mut relay_rx) = mpsc::unbounded_channel::<AdapterFrame>();
        let relay_writer_task = tokio::spawn(async move {
            while let Some(frame) = relay_rx.recv().await {
                let Ok(encoded) = encode_adapter_frame(&frame) else {
                    continue;
                };
                if relay_writer
                    .send(TungsteniteMessage::Binary(encoded))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });

        let mut runtimes = HashMap::<String, mpsc::UnboundedSender<TungsteniteMessage>>::new();
        while let Some(message) = relay_reader.next().await {
            match message.context("failed to read bridge relay websocket message")? {
                TungsteniteMessage::Binary(frame) => {
                    let frame = decode_adapter_frame(&frame)?;
                    if frame.header.direction != AdapterDirection::ClientToServer {
                        continue;
                    }

                    if frame.header.opcode == AdapterOpcode::Close {
                        if let Some(runtime) = runtimes.remove(&frame.header.connection_id) {
                            let _ = runtime.send(tungstenite_close_message(&frame.header));
                        }
                        continue;
                    }

                    let runtime = if let Some(runtime) = runtimes.get(&frame.header.connection_id) {
                        runtime.clone()
                    } else {
                        let runtime = match open_runtime_connection(
                            &config.local_runtime_url,
                            frame.header.client_id.clone(),
                            frame.header.connection_id.clone(),
                            relay_tx.clone(),
                        )
                        .await
                        {
                            Ok(runtime) => runtime,
                            Err(_) => {
                                let reason = "local runtime unavailable".to_string();
                                let _ = relay_tx.send(AdapterFrame {
                                    header: AdapterFrameHeader {
                                        client_id: frame.header.client_id,
                                        connection_id: frame.header.connection_id,
                                        direction: AdapterDirection::ServerToClient,
                                        opcode: AdapterOpcode::Close,
                                        close_code: Some(1013),
                                        close_reason: Some(reason.clone()),
                                    },
                                    payload: close_payload(1013, &reason),
                                });
                                continue;
                            }
                        };
                        runtimes.insert(frame.header.connection_id.clone(), runtime.clone());
                        runtime
                    };

                    if runtime
                        .send(tungstenite_message_from_adapter_frame(frame)?)
                        .is_err()
                    {
                        runtimes.retain(|_, sender| !sender.is_closed());
                    }
                }
                TungsteniteMessage::Close(_) => break,
                _ => {}
            }
        }

        relay_writer_task.abort();
        Ok(())
    }

    async fn open_runtime_connection(
        local_runtime_url: &str,
        client_id: String,
        connection_id: String,
        relay_tx: mpsc::UnboundedSender<AdapterFrame>,
    ) -> Result<mpsc::UnboundedSender<TungsteniteMessage>> {
        let (runtime, _) = connect_async(local_runtime_url)
            .await
            .context("failed to connect local Orca runtime websocket")?;
        let (mut runtime_writer, mut runtime_reader) = runtime.split();
        let (runtime_tx, mut runtime_rx) = mpsc::unbounded_channel::<TungsteniteMessage>();

        tokio::spawn(async move {
            let write_runtime = async {
                while let Some(message) = runtime_rx.recv().await {
                    let closes_connection = matches!(message, TungsteniteMessage::Close(_));
                    if runtime_writer.send(message).await.is_err() {
                        break;
                    }
                    if closes_connection {
                        break;
                    }
                }
            };

            let read_runtime = async {
                while let Some(Ok(message)) = runtime_reader.next().await {
                    let Some(frame) = adapter_frame_from_tungstenite(
                        message,
                        &client_id,
                        &connection_id,
                        AdapterDirection::ServerToClient,
                    ) else {
                        continue;
                    };
                    let closes_connection = frame.header.opcode == AdapterOpcode::Close;
                    if relay_tx.send(frame).is_err() || closes_connection {
                        break;
                    }
                }
            };

            tokio::select! {
                _ = write_runtime => {},
                _ = read_runtime => {},
            }
        });

        Ok(runtime_tx)
    }

    fn install_tls_provider() {
        if CryptoProvider::get_default().is_none() {
            let _ = ring::default_provider().install_default();
        }
    }

    async fn connect_with_bearer(url: &str, token: &str) -> Result<RelayWebSocket> {
        let mut request = url
            .into_client_request()
            .context("invalid relay websocket URL")?;
        let header_value = HeaderValue::from_str(&format!("Bearer {token}"))
            .context("invalid relay authorization header")?;
        request.headers_mut().insert(WS_AUTHORIZATION, header_value);
        let (socket, _) = connect_async(request)
            .await
            .context("relay websocket connection failed")?;
        Ok(socket)
    }

    fn adapter_frame_from_axum(
        message: AxumMessage,
        client_id: &str,
        connection_id: &str,
    ) -> Option<(AdapterFrame, bool)> {
        let (opcode, payload, close_code, close_reason, closes_connection) = match message {
            AxumMessage::Text(text) => (AdapterOpcode::Text, text.into_bytes(), None, None, false),
            AxumMessage::Binary(bytes) => (AdapterOpcode::Binary, bytes, None, None, false),
            AxumMessage::Close(close) => {
                let (close_code, close_reason, payload) = axum_close_parts(close);
                (
                    AdapterOpcode::Close,
                    payload,
                    close_code,
                    close_reason,
                    true,
                )
            }
            AxumMessage::Ping(_) | AxumMessage::Pong(_) => return None,
        };

        Some((
            AdapterFrame {
                header: AdapterFrameHeader {
                    client_id: client_id.to_string(),
                    connection_id: connection_id.to_string(),
                    direction: AdapterDirection::ClientToServer,
                    opcode,
                    close_code,
                    close_reason,
                },
                payload,
            },
            closes_connection,
        ))
    }

    fn adapter_frame_from_tungstenite(
        message: TungsteniteMessage,
        client_id: &str,
        connection_id: &str,
        direction: AdapterDirection,
    ) -> Option<AdapterFrame> {
        let (opcode, payload, close_code, close_reason) = match message {
            TungsteniteMessage::Text(text) => (AdapterOpcode::Text, text.into_bytes(), None, None),
            TungsteniteMessage::Binary(bytes) => (AdapterOpcode::Binary, bytes, None, None),
            TungsteniteMessage::Close(close) => {
                let (close_code, close_reason, payload) = tungstenite_close_parts(close);
                (AdapterOpcode::Close, payload, close_code, close_reason)
            }
            _ => return None,
        };

        Some(AdapterFrame {
            header: AdapterFrameHeader {
                client_id: client_id.to_string(),
                connection_id: connection_id.to_string(),
                direction,
                opcode,
                close_code,
                close_reason,
            },
            payload,
        })
    }

    fn axum_message_from_adapter_frame(frame: AdapterFrame) -> Result<AxumMessage> {
        match frame.header.opcode {
            AdapterOpcode::Text => Ok(AxumMessage::Text(
                String::from_utf8(frame.payload).context("adapter text payload was not UTF-8")?,
            )),
            AdapterOpcode::Binary => Ok(AxumMessage::Binary(frame.payload)),
            AdapterOpcode::Close => Ok(axum_close_message(&frame.header)),
        }
    }

    fn tungstenite_message_from_adapter_frame(frame: AdapterFrame) -> Result<TungsteniteMessage> {
        match frame.header.opcode {
            AdapterOpcode::Text => Ok(TungsteniteMessage::Text(
                String::from_utf8(frame.payload).context("adapter text payload was not UTF-8")?,
            )),
            AdapterOpcode::Binary => Ok(TungsteniteMessage::Binary(frame.payload)),
            AdapterOpcode::Close => Ok(tungstenite_close_message(&frame.header)),
        }
    }

    fn axum_close_message(header: &AdapterFrameHeader) -> AxumMessage {
        AxumMessage::Close(header.close_code.map(|code| AxumCloseFrame {
            code,
            reason: header.close_reason.clone().unwrap_or_default().into(),
        }))
    }

    fn tungstenite_close_message(header: &AdapterFrameHeader) -> TungsteniteMessage {
        TungsteniteMessage::Close(header.close_code.map(|code| TungsteniteCloseFrame {
            code: CloseCode::from(code),
            reason: header.close_reason.clone().unwrap_or_default().into(),
        }))
    }

    fn axum_close_parts(
        close: Option<AxumCloseFrame<'static>>,
    ) -> (Option<u16>, Option<String>, Vec<u8>) {
        match close {
            Some(close) => {
                let reason = close.reason.into_owned();
                let payload = close_payload(close.code, &reason);
                (Some(close.code), Some(reason), payload)
            }
            None => (None, None, Vec::new()),
        }
    }

    fn tungstenite_close_parts(
        close: Option<TungsteniteCloseFrame<'static>>,
    ) -> (Option<u16>, Option<String>, Vec<u8>) {
        match close {
            Some(close) => {
                let code = u16::from(close.code);
                let reason = close.reason.into_owned();
                let payload = close_payload(code, &reason);
                (Some(code), Some(reason), payload)
            }
            None => (None, None, Vec::new()),
        }
    }

    fn close_payload(code: u16, reason: &str) -> Vec<u8> {
        let mut payload = Vec::with_capacity(2 + reason.len());
        payload.extend_from_slice(&code.to_be_bytes());
        payload.extend_from_slice(reason.as_bytes());
        payload
    }

    fn relay_url(base: &str, params: &[(&str, &str)]) -> String {
        let mut url = String::from(base);
        url.push(if base.contains('?') { '&' } else { '?' });
        for (index, (key, value)) in params.iter().enumerate() {
            if index > 0 {
                url.push('&');
            }
            url.push_str(key);
            url.push('=');
            push_query_component(&mut url, value);
        }
        url
    }

    fn push_query_component(url: &mut String, value: &str) {
        for byte in value.bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                    url.push(byte as char);
                }
                _ => {
                    let _ = write!(url, "%{byte:02X}");
                }
            }
        }
    }
}
