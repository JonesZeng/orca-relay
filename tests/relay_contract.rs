use std::{net::SocketAddr, time::Duration};

use axum::Router;
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use tokio::{net::TcpListener, time::timeout};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{
        client::IntoClientRequest,
        handshake::client::Response,
        http::header::AUTHORIZATION,
        protocol::{frame::coding::CloseCode, CloseFrame, Message},
        Error as WsError,
    },
    MaybeTlsStream, WebSocketStream,
};

use orca_relay::{app, RelayConfig};

const TOKEN: &str = "relay-test-token";
const VERSION: &str = "test-version";
type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;
type WsConnectResult = Result<(WsStream, Response), WsError>;

#[derive(Debug, Deserialize)]
struct HealthBody {
    status: String,
    version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct RelayHeader {
    v: u8,
    #[serde(rename = "type")]
    kind: String,
    request_id: String,
    client_id: String,
    direction: String,
}

#[tokio::test]
async fn health_returns_ok_and_version() {
    let relay = TestRelay::spawn().await;

    let response = reqwest::get(relay.http_url("/health")).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.json::<HealthBody>().await.unwrap();
    assert_eq!(body.status, "ok");
    assert_eq!(body.version, VERSION);
}

#[tokio::test]
async fn ws_rejects_missing_bearer_token() {
    let relay = TestRelay::spawn().await;

    let error = expect_connect_error(
        connect_without_token(&relay.ws_url("/ws?role=server&serverId=s1&v=1")).await,
        "missing bearer token should reject the websocket upgrade",
    );

    assert_http_error_status(error, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn ws_rejects_invalid_bearer_token() {
    let relay = TestRelay::spawn().await;

    let error = expect_connect_error(
        connect_with_token(
            &relay.ws_url("/ws?role=server&serverId=s1&v=1"),
            "not-the-token",
        )
        .await,
        "invalid bearer token should reject the websocket upgrade",
    );

    assert_http_error_status(error, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn client_fails_fast_when_no_server_is_connected() {
    let relay = TestRelay::spawn().await;

    let error = expect_connect_error(
        connect_with_token(
            &relay.ws_url("/ws?role=client&serverId=absent&clientId=c1&v=1"),
            TOKEN,
        )
        .await,
        "client should fail fast when no server socket exists",
    );

    assert_http_error_status(error, StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn relay_routes_opaque_binary_payload_round_trip_by_header() {
    let relay = TestRelay::spawn().await;
    let (mut server, _) =
        connect_with_token(&relay.ws_url("/ws?role=server&serverId=s1&v=1"), TOKEN)
            .await
            .unwrap();
    let (mut client, _) = connect_with_token(
        &relay.ws_url("/ws?role=client&serverId=s1&clientId=c1&v=1"),
        TOKEN,
    )
    .await
    .unwrap();

    let request_header = RelayHeader {
        v: 1,
        kind: "data".to_string(),
        request_id: "req-1".to_string(),
        client_id: "c1".to_string(),
        direction: "client_to_server".to_string(),
    };
    let request_payload = b"\x00opaque-client-bytes\xff".to_vec();
    client
        .send(Message::Binary(encode_frame(
            &request_header,
            &request_payload,
        )))
        .await
        .unwrap();

    let server_message = next_binary(&mut server).await;
    let (server_header, server_payload) = decode_frame(&server_message);
    assert_eq!(server_header, request_header);
    assert_eq!(server_payload, request_payload);

    let response_header = RelayHeader {
        direction: "server_to_client".to_string(),
        ..server_header
    };
    let response_payload = b"\xffopaque-server-bytes\x00".to_vec();
    server
        .send(Message::Binary(encode_frame(
            &response_header,
            &response_payload,
        )))
        .await
        .unwrap();

    let client_message = next_binary(&mut client).await;
    let (client_header, client_payload) = decode_frame(&client_message);
    assert_eq!(client_header, response_header);
    assert_eq!(client_payload, response_payload);
}

#[tokio::test]
async fn replacement_server_closes_old_server_socket() {
    let relay = TestRelay::spawn().await;
    let (mut old_server, _) =
        connect_with_token(&relay.ws_url("/ws?role=server&serverId=s1&v=1"), TOKEN)
            .await
            .unwrap();

    let (_new_server, _) =
        connect_with_token(&relay.ws_url("/ws?role=server&serverId=s1&v=1"), TOKEN)
            .await
            .unwrap();

    let close = timeout(Duration::from_secs(1), old_server.next())
        .await
        .expect("old server should be closed when a replacement connects")
        .expect("old server stream should yield a close frame or close result")
        .expect("old server close should not be a websocket error");

    assert_eq!(
        close,
        Message::Close(Some(CloseFrame {
            code: CloseCode::Normal,
            reason: "server replaced".into(),
        }))
    );
}

#[tokio::test]
async fn replacement_client_closes_old_client_socket() {
    let relay = TestRelay::spawn().await;
    let (_server, _) = connect_with_token(&relay.ws_url("/ws?role=server&serverId=s1&v=1"), TOKEN)
        .await
        .unwrap();
    let (mut old_client, _) = connect_with_token(
        &relay.ws_url("/ws?role=client&serverId=s1&clientId=c1&v=1"),
        TOKEN,
    )
    .await
    .unwrap();

    let (_new_client, _) = connect_with_token(
        &relay.ws_url("/ws?role=client&serverId=s1&clientId=c1&v=1"),
        TOKEN,
    )
    .await
    .unwrap();

    let close = timeout(Duration::from_secs(1), old_client.next())
        .await
        .expect("old client should be closed when a replacement connects")
        .expect("old client stream should yield a close frame or close result")
        .expect("old client close should not be a websocket error");

    assert_eq!(
        close,
        Message::Close(Some(CloseFrame {
            code: CloseCode::Normal,
            reason: "client replaced".into(),
        }))
    );
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

    fn http_url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    fn ws_url(&self, path: &str) -> String {
        format!("ws://{}{}", self.addr, path)
    }
}

fn into_make_service(app: Router) -> Router {
    app
}

async fn connect_without_token(url: &str) -> WsConnectResult {
    connect_async(url).await
}

async fn connect_with_token(url: &str, token: &str) -> WsConnectResult {
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());

    connect_async(request).await
}

fn expect_connect_error(result: WsConnectResult, context: &str) -> WsError {
    match result {
        Ok(_) => panic!("{context}"),
        Err(error) => error,
    }
}

fn assert_http_error_status(error: WsError, expected: StatusCode) {
    let WsError::Http(response) = error else {
        panic!("expected HTTP {expected} handshake failure, got {error:?}");
    };

    assert_eq!(response.status(), expected);
}

fn encode_frame(header: &RelayHeader, payload: &[u8]) -> Vec<u8> {
    let header = serde_json::to_vec(header).unwrap();
    let header_len: u32 = header.len().try_into().unwrap();
    let mut frame = Vec::with_capacity(4 + header.len() + payload.len());
    frame.extend_from_slice(&header_len.to_be_bytes());
    frame.extend_from_slice(&header);
    frame.extend_from_slice(payload);
    frame
}

fn decode_frame(frame: &[u8]) -> (RelayHeader, Vec<u8>) {
    assert!(frame.len() >= 4, "relay frame must include header length");
    let header_len = u32::from_be_bytes(frame[0..4].try_into().unwrap()) as usize;
    assert!(
        frame.len() >= 4 + header_len,
        "relay frame is shorter than declared header length"
    );
    let header = serde_json::from_slice(&frame[4..4 + header_len]).unwrap();
    let payload = frame[4 + header_len..].to_vec();
    (header, payload)
}

async fn next_binary<S>(socket: &mut S) -> Vec<u8>
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    let message = timeout(Duration::from_secs(1), socket.next())
        .await
        .expect("timed out waiting for websocket message")
        .expect("websocket stream ended before binary message")
        .expect("websocket stream returned an error");

    match message {
        Message::Binary(bytes) => bytes,
        other => panic!("expected binary websocket frame, got {other:?}"),
    }
}
