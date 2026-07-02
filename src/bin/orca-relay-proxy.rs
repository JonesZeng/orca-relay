use std::{env, net::SocketAddr};

use anyhow::{bail, Context, Result};
use orca_relay::adapter::{run_proxy, ProxyConfig};
use tokio::signal;

const USAGE: &str = "Usage: orca-relay-proxy [--bind <addr>] --relay-url <url> --server-id <id> --client-id <id>\n\nConfiguration:\n  --bind <addr>        Local proxy bind address (or ORCA_RELAY_BIND; default 127.0.0.1:0)\n  --relay-url <url>    Relay WebSocket URL (or ORCA_RELAY_URL)\n  --server-id <id>     Relay server id (or ORCA_RELAY_SERVER_ID)\n  --client-id <id>     Relay client id (or ORCA_RELAY_CLIENT_ID)\n  ORCA_RELAY_TOKEN     Relay bearer token (required; environment only)\n\nThe relay token is intentionally not accepted as a CLI flag.\n";

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse()?;
    if args.help {
        print!("{USAGE}");
        return Ok(());
    }

    let bind = args
        .bind
        .or_else(|| env::var("ORCA_RELAY_BIND").ok())
        .unwrap_or_else(|| "127.0.0.1:0".to_string());
    let bind_addr: SocketAddr = bind.parse().context("invalid proxy bind address")?;
    let relay_url = required(args.relay_url, "ORCA_RELAY_URL", "--relay-url")?;
    let server_id = required(args.server_id, "ORCA_RELAY_SERVER_ID", "--server-id")?;
    let client_id = required(args.client_id, "ORCA_RELAY_CLIENT_ID", "--client-id")?;
    let relay_token = env::var("ORCA_RELAY_TOKEN").context("missing ORCA_RELAY_TOKEN")?;

    let proxy = run_proxy(ProxyConfig {
        bind_addr,
        relay_url,
        server_id: server_id.clone(),
        relay_token,
        client_id: client_id.clone(),
    })
    .await?;

    println!(
        "orca-relay-proxy listening on ws://{}/ws",
        proxy.local_addr()
    );
    println!("forwarding via relay for server_id={server_id} client_id={client_id}");
    println!("press Ctrl-C to stop");
    signal::ctrl_c()
        .await
        .context("failed to wait for Ctrl-C")?;
    Ok(())
}

#[derive(Default)]
struct Args {
    bind: Option<String>,
    relay_url: Option<String>,
    server_id: Option<String>,
    client_id: Option<String>,
    help: bool,
}

impl Args {
    fn parse() -> Result<Self> {
        let mut parsed = Self::default();
        let mut args = env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--help" | "-h" => parsed.help = true,
                "--bind" => parsed.bind = Some(value_after(&mut args, "--bind")?),
                "--relay-url" => parsed.relay_url = Some(value_after(&mut args, "--relay-url")?),
                "--server-id" => parsed.server_id = Some(value_after(&mut args, "--server-id")?),
                "--client-id" => parsed.client_id = Some(value_after(&mut args, "--client-id")?),
                _ if arg.starts_with("--bind=") => {
                    parsed.bind = Some(value_after_equals(&arg, "--bind")?)
                }
                _ if arg.starts_with("--relay-url=") => {
                    parsed.relay_url = Some(value_after_equals(&arg, "--relay-url")?)
                }
                _ if arg.starts_with("--server-id=") => {
                    parsed.server_id = Some(value_after_equals(&arg, "--server-id")?)
                }
                _ if arg.starts_with("--client-id=") => {
                    parsed.client_id = Some(value_after_equals(&arg, "--client-id")?)
                }
                _ if arg.starts_with('-') => bail!("unknown option; run orca-relay-proxy --help"),
                _ => bail!("unexpected positional argument; run orca-relay-proxy --help"),
            }
        }
        Ok(parsed)
    }
}

fn required(flag_value: Option<String>, env_name: &str, flag_name: &str) -> Result<String> {
    flag_value
        .or_else(|| env::var(env_name).ok())
        .with_context(|| format!("missing {env_name} or {flag_name}"))
}

fn value_after(args: &mut impl Iterator<Item = String>, flag_name: &str) -> Result<String> {
    let value = args
        .next()
        .with_context(|| format!("missing value for {flag_name}"))?;
    if value.is_empty() {
        bail!("empty value for {flag_name}");
    }
    Ok(value)
}

fn value_after_equals(arg: &str, flag_name: &str) -> Result<String> {
    let Some((_, value)) = arg.split_once('=') else {
        bail!("missing value for {flag_name}");
    };
    if value.is_empty() {
        bail!("empty value for {flag_name}");
    }
    Ok(value.to_string())
}
