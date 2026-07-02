use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::Router;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::{net::TcpListener, sync::mpsc, sync::Barrier, task::JoinHandle, time::timeout};
use tokio_tungstenite::{
    accept_async, connect_async,
    tungstenite::{client::IntoClientRequest, http::header::AUTHORIZATION, Message},
};

use orca_relay::{
    adapter::{
        decode_adapter_frame, encode_adapter_frame, run_bridge, run_proxy, AdapterDirection,
        AdapterFrame, AdapterFrameHeader, AdapterOpcode, BridgeConfig, ProxyConfig,
    },
    app, RelayConfig,
};

const TOKEN: &str = "relay-test-token";
const VERSION: &str = "test-version";
const SERVER_ID: &str = "server-a";
const CLIENT_ID: &str = "client-a";
const CONNECTION_ID: &str = "conn-a";
const TEXT_PAYLOAD: &[u8] = b"hello from fake orca cli";
const BINARY_PAYLOAD: &[u8] = b"\x00binary\xffpayload\x7f";
const CLOSE_PAYLOAD: &[u8] = b"\x03\xe8normal shutdown";

#[test]
fn text_adapter_frame_encodes_as_length_prefixed_relay_binary_frame() {
    assert_adapter_frame_codec(
        AdapterOpcode::Text,
        AdapterDirection::ClientToServer,
        TEXT_PAYLOAD,
        "text",
        "client_to_server",
        None,
        None,
    );
}

#[test]
fn binary_adapter_frame_encodes_as_length_prefixed_relay_binary_frame() {
    assert_adapter_frame_codec(
        AdapterOpcode::Binary,
        AdapterDirection::ServerToClient,
        BINARY_PAYLOAD,
        "binary",
        "server_to_client",
        None,
        None,
    );
}

#[test]
fn close_adapter_frame_encodes_metadata_and_preserves_opaque_payload() {
    assert_adapter_frame_codec(
        AdapterOpcode::Close,
        AdapterDirection::ClientToServer,
        CLOSE_PAYLOAD,
        "close",
        "client_to_server",
        Some(1000),
        Some("normal shutdown"),
    );
}

#[tokio::test]
async fn proxy_and_bridge_round_trip_text_and_binary_messages_without_mutating_bytes() {
    let relay = TestRelay::spawn().await;
    let runtime = FakeOrcaRuntime::spawn().await;

    let _bridge = run_bridge(BridgeConfig {
        relay_url: relay.ws_url("/ws"),
        local_runtime_url: runtime.ws_url(),
        server_id: SERVER_ID.to_string(),
        relay_token: TOKEN.to_string(),
    })
    .await
    .expect("bridge should start and connect to the relay and local Orca runtime");

    let proxy = run_proxy(ProxyConfig {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        relay_url: relay.ws_url("/ws"),
        server_id: SERVER_ID.to_string(),
        relay_token: TOKEN.to_string(),
        client_id: CLIENT_ID.to_string(),
    })
    .await
    .expect("proxy should bind and connect to the relay");

    let (mut cli, _) = connect_async(format!("ws://{}/ws", proxy.local_addr()))
        .await
        .expect("fake Orca CLI should connect to the local proxy");

    let text = std::str::from_utf8(TEXT_PAYLOAD).unwrap();
    cli.send(Message::Text(text.to_string()))
        .await
        .expect("CLI text send should succeed");
    assert_eq!(next_text(&mut cli).await.as_bytes(), TEXT_PAYLOAD);

    cli.send(Message::Binary(BINARY_PAYLOAD.to_vec()))
        .await
        .expect("CLI binary send should succeed");
    assert_eq!(next_binary(&mut cli).await, BINARY_PAYLOAD);

    cli.close(None)
        .await
        .expect("CLI close should be forwarded cleanly");
    runtime.assert_observed_expected_messages().await;
}

#[tokio::test]
async fn proxy_routes_overlapped_local_websockets_independently() {
    let relay = TestRelay::spawn().await;
    let mut runtime = TwoConnectionEchoRuntime::spawn().await;

    let _bridge = run_bridge(BridgeConfig {
        relay_url: relay.ws_url("/ws"),
        local_runtime_url: runtime.ws_url(),
        server_id: SERVER_ID.to_string(),
        relay_token: TOKEN.to_string(),
    })
    .await
    .expect("bridge should start and connect to the relay and local Orca runtime");

    let proxy = run_proxy(ProxyConfig {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        relay_url: relay.ws_url("/ws"),
        server_id: SERVER_ID.to_string(),
        relay_token: TOKEN.to_string(),
        client_id: CLIENT_ID.to_string(),
    })
    .await
    .expect("proxy should bind and connect to the relay");

    let first_payload = "first overlapped proxied payload";
    let second_payload = "second overlapped proxied payload";
    let (mut first_cli, _) = connect_async(format!("ws://{}/ws", proxy.local_addr()))
        .await
        .expect("first fake Orca CLI should connect to the local proxy");

    first_cli
        .send(Message::Text(first_payload.to_string()))
        .await
        .expect("first CLI text send should succeed");
    assert_eq!(runtime.next_observed_text().await, first_payload);

    let (mut second_cli, _) = connect_async(format!("ws://{}/ws", proxy.local_addr()))
        .await
        .expect("second fake Orca CLI should connect to the local proxy");
    second_cli
        .send(Message::Text(second_payload.to_string()))
        .await
        .expect("second CLI text send should succeed");
    assert_eq!(runtime.next_observed_text().await, second_payload);

    assert_eq!(next_text(&mut first_cli).await, first_payload);
    assert_eq!(next_text(&mut second_cli).await, second_payload);

    first_cli
        .close(None)
        .await
        .expect("first CLI close should be forwarded cleanly");
    second_cli
        .close(None)
        .await
        .expect("second CLI close should be forwarded cleanly");
    runtime.assert_observed_expected_messages().await;
}

#[tokio::test]
async fn bridge_survives_one_local_runtime_connect_failure() {
    let relay = TestRelay::spawn().await;
    let unavailable_runtime = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let runtime_addr = unavailable_runtime.local_addr().unwrap();
    drop(unavailable_runtime);

    let _bridge = run_bridge(BridgeConfig {
        relay_url: relay.ws_url("/ws"),
        local_runtime_url: format!("ws://{runtime_addr}"),
        server_id: SERVER_ID.to_string(),
        relay_token: TOKEN.to_string(),
    })
    .await
    .expect("bridge should connect to the relay even before local runtime is available");

    let mut failing_client = connect_relay_client(&relay, "client-before-runtime").await;
    failing_client
        .send(Message::Binary(
            encode_adapter_frame(&adapter_frame(
                "client-before-runtime",
                "missing-runtime",
                AdapterDirection::ClientToServer,
                AdapterOpcode::Text,
                TEXT_PAYLOAD,
            ))
            .unwrap(),
        ))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    let runtime = FakeOrcaRuntime::spawn_at(runtime_addr).await;
    let mut client = connect_relay_client(&relay, CLIENT_ID).await;

    client
        .send(Message::Binary(
            encode_adapter_frame(&adapter_frame(
                CLIENT_ID,
                CONNECTION_ID,
                AdapterDirection::ClientToServer,
                AdapterOpcode::Text,
                TEXT_PAYLOAD,
            ))
            .unwrap(),
        ))
        .await
        .unwrap();
    let text_reply = next_adapter_frame(&mut client).await;
    assert_eq!(
        text_reply.header.direction,
        AdapterDirection::ServerToClient
    );
    assert_eq!(text_reply.header.opcode, AdapterOpcode::Text);
    assert_eq!(text_reply.payload, TEXT_PAYLOAD);

    client
        .send(Message::Binary(
            encode_adapter_frame(&adapter_frame(
                CLIENT_ID,
                CONNECTION_ID,
                AdapterDirection::ClientToServer,
                AdapterOpcode::Binary,
                BINARY_PAYLOAD,
            ))
            .unwrap(),
        ))
        .await
        .unwrap();
    let binary_reply = next_adapter_frame(&mut client).await;
    assert_eq!(
        binary_reply.header.direction,
        AdapterDirection::ServerToClient
    );
    assert_eq!(binary_reply.header.opcode, AdapterOpcode::Binary);
    assert_eq!(binary_reply.payload, BINARY_PAYLOAD);

    runtime.assert_observed_expected_messages().await;
}

fn assert_adapter_frame_codec(
    opcode: AdapterOpcode,
    direction: AdapterDirection,
    payload: &[u8],
    expected_opcode: &str,
    expected_direction: &str,
    close_code: Option<u16>,
    close_reason: Option<&str>,
) {
    let frame = AdapterFrame {
        header: AdapterFrameHeader {
            client_id: CLIENT_ID.to_string(),
            connection_id: CONNECTION_ID.to_string(),
            direction,
            opcode,
            close_code,
            close_reason: close_reason.map(str::to_string),
        },
        payload: payload.to_vec(),
    };

    let encoded = encode_adapter_frame(&frame).expect("adapter frame should encode");
    let (raw_header, raw_payload) = split_relay_frame(&encoded);

    assert_eq!(raw_header["clientId"], CLIENT_ID);
    assert_eq!(raw_header["connectionId"], CONNECTION_ID);
    assert_eq!(raw_header["direction"], expected_direction);
    assert_eq!(raw_header["opcode"], expected_opcode);
    assert_eq!(
        raw_header.get("closeCode").and_then(Value::as_u64),
        close_code.map(u64::from)
    );
    assert_eq!(
        raw_header.get("closeReason").and_then(Value::as_str),
        close_reason
    );
    assert_eq!(raw_payload, payload);

    let decoded = decode_adapter_frame(&encoded).expect("adapter frame should decode");
    assert_eq!(decoded.header.client_id, CLIENT_ID);
    assert_eq!(decoded.header.connection_id, CONNECTION_ID);
    assert_eq!(decoded.header.direction, frame.header.direction);
    assert_eq!(decoded.header.opcode, frame.header.opcode);
    assert_eq!(decoded.header.close_code, close_code);
    assert_eq!(decoded.header.close_reason.as_deref(), close_reason);
    assert_eq!(decoded.payload, payload);
}

fn adapter_frame(
    client_id: &str,
    connection_id: &str,
    direction: AdapterDirection,
    opcode: AdapterOpcode,
    payload: &[u8],
) -> AdapterFrame {
    AdapterFrame {
        header: AdapterFrameHeader {
            client_id: client_id.to_string(),
            connection_id: connection_id.to_string(),
            direction,
            opcode,
            close_code: None,
            close_reason: None,
        },
        payload: payload.to_vec(),
    }
}

fn split_relay_frame(frame: &[u8]) -> (Value, Vec<u8>) {
    assert!(
        frame.len() >= 4,
        "relay frame must include a 4-byte header length"
    );
    let header_len = u32::from_be_bytes(frame[0..4].try_into().unwrap()) as usize;
    assert!(
        frame.len() >= 4 + header_len,
        "relay frame must include the declared JSON header bytes"
    );

    let header = serde_json::from_slice(&frame[4..4 + header_len])
        .expect("relay frame header should be JSON");
    let payload = frame[4 + header_len..].to_vec();
    (header, payload)
}

struct TestRelay {
    addr: SocketAddr,
}

impl TestRelay {
    async fn spawn() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = app(RelayConfig::new(VERSION, TOKEN));

        tokio::spawn(async move {
            axum::serve(listener, into_make_service(app)).await.unwrap();
        });

        Self { addr }
    }

    fn ws_url(&self, path: &str) -> String {
        format!("ws://{}{}", self.addr, path)
    }
}

async fn connect_relay_client(
    relay: &TestRelay,
    client_id: &str,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let mut request = relay
        .ws_url(&format!(
            "/ws?role=client&serverId={SERVER_ID}&clientId={client_id}&v=1"
        ))
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert(AUTHORIZATION, format!("Bearer {TOKEN}").parse().unwrap());
    let (socket, _) = connect_async(request).await.unwrap();
    socket
}

fn into_make_service(app: Router) -> Router {
    app
}

struct FakeOrcaRuntime {
    addr: SocketAddr,
    task: JoinHandle<()>,
}

impl FakeOrcaRuntime {
    async fn spawn() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        Self::spawn_from_listener(listener).await
    }

    async fn spawn_at(addr: SocketAddr) -> Self {
        let listener = TcpListener::bind(addr).await.unwrap();
        Self::spawn_from_listener(listener).await
    }

    async fn spawn_from_listener(listener: TcpListener) -> Self {
        let addr = listener.local_addr().unwrap();

        let task = tokio::spawn(async move {
            let (stream, _) = listener
                .accept()
                .await
                .expect("bridge should connect to fake local Orca runtime");
            let mut socket = accept_async(stream)
                .await
                .expect("bridge should complete local Orca runtime websocket handshake");

            match next_runtime_message(&mut socket).await {
                Message::Text(text) => {
                    assert_eq!(text.as_bytes(), TEXT_PAYLOAD);
                    socket
                        .send(Message::Text(text))
                        .await
                        .expect("runtime text echo should succeed");
                }
                other => panic!("expected text from bridge, got {other:?}"),
            }

            match next_runtime_message(&mut socket).await {
                Message::Binary(bytes) => {
                    assert_eq!(bytes, BINARY_PAYLOAD);
                    socket
                        .send(Message::Binary(bytes))
                        .await
                        .expect("runtime binary echo should succeed");
                }
                other => panic!("expected binary from bridge, got {other:?}"),
            }
        });

        Self { addr, task }
    }

    fn ws_url(&self) -> String {
        format!("ws://{}", self.addr)
    }

    async fn assert_observed_expected_messages(self) {
        timeout(Duration::from_secs(1), self.task)
            .await
            .expect("fake local Orca runtime did not observe the expected messages")
            .expect("fake local Orca runtime task panicked");
    }
}

struct TwoConnectionEchoRuntime {
    addr: SocketAddr,
    task: JoinHandle<()>,
    observed_rx: mpsc::UnboundedReceiver<String>,
}

impl TwoConnectionEchoRuntime {
    async fn spawn() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let (observed_tx, observed_rx) = mpsc::unbounded_channel();

        let task = tokio::spawn(async move {
            let mut handlers = Vec::new();
            for _ in 0..2 {
                let (stream, _) = listener
                    .accept()
                    .await
                    .expect("bridge should connect to fake local Orca runtime");
                let barrier = Arc::clone(&barrier);
                let observed_tx = observed_tx.clone();

                handlers.push(tokio::spawn(async move {
                    let mut socket = accept_async(stream)
                        .await
                        .expect("bridge should complete local Orca runtime websocket handshake");

                    match next_runtime_message(&mut socket).await {
                        Message::Text(text) => {
                            observed_tx
                                .send(text.clone())
                                .expect("runtime text observation should be received by test");
                            barrier.wait().await;
                            socket
                                .send(Message::Text(text))
                                .await
                                .expect("runtime text echo should succeed");
                        }
                        other => panic!("expected text from bridge, got {other:?}"),
                    }
                }));
            }

            drop(observed_tx);
            for handler in handlers {
                handler
                    .await
                    .expect("fake local Orca runtime connection task panicked");
            }
        });

        Self {
            addr,
            task,
            observed_rx,
        }
    }

    fn ws_url(&self) -> String {
        format!("ws://{}", self.addr)
    }

    async fn next_observed_text(&mut self) -> String {
        timeout(Duration::from_secs(1), self.observed_rx.recv())
            .await
            .expect("timed out waiting for fake local Orca runtime websocket message")
            .expect("fake local Orca runtime websocket ended before expected message")
    }

    async fn assert_observed_expected_messages(self) {
        timeout(Duration::from_secs(1), self.task)
            .await
            .expect("fake local Orca runtime did not observe the expected messages")
            .expect("fake local Orca runtime task panicked");
    }
}

async fn next_runtime_message<S>(socket: &mut S) -> Message
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    timeout(Duration::from_secs(1), socket.next())
        .await
        .expect("timed out waiting for fake local Orca runtime websocket message")
        .expect("fake local Orca runtime websocket ended before expected message")
        .expect("fake local Orca runtime websocket returned an error")
}

async fn next_text<S>(socket: &mut S) -> String
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    match next_runtime_message(socket).await {
        Message::Text(text) => text,
        other => panic!("expected text websocket frame, got {other:?}"),
    }
}

async fn next_binary<S>(socket: &mut S) -> Vec<u8>
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    match next_runtime_message(socket).await {
        Message::Binary(bytes) => bytes,
        other => panic!("expected binary websocket frame, got {other:?}"),
    }
}

async fn next_adapter_frame<S>(socket: &mut S) -> AdapterFrame
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    decode_adapter_frame(&next_binary(socket).await).expect("adapter frame should decode")
}
