use std::env;

use anyhow::{bail, Context, Result};
use orca_relay::adapter::{run_bridge, BridgeConfig};
use tokio::signal;

const USAGE: &str = "Usage: orca-relay-bridge --relay-url <url> --runtime-url <url> --server-id <id>\n\nConfiguration:\n  --relay-url <url>    Relay WebSocket URL (or ORCA_RELAY_URL)\n  --runtime-url <url>  Local Orca runtime WebSocket URL (or ORCA_RUNTIME_WS_URL)\n  --server-id <id>     Relay server id (or ORCA_RELAY_SERVER_ID)\n  ORCA_RELAY_TOKEN     Relay bearer token (required; environment only)\n\nThe relay token is intentionally not accepted as a CLI flag.\n";

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse()?;
    if args.help {
        print!("{USAGE}");
        return Ok(());
    }

    let relay_url = required(args.relay_url, "ORCA_RELAY_URL", "--relay-url")?;
    let local_runtime_url = required(args.runtime_url, "ORCA_RUNTIME_WS_URL", "--runtime-url")?;
    let server_id = required(args.server_id, "ORCA_RELAY_SERVER_ID", "--server-id")?;
    let relay_token = env::var("ORCA_RELAY_TOKEN").context("missing ORCA_RELAY_TOKEN")?;

    let _bridge = run_bridge(BridgeConfig {
        relay_url,
        local_runtime_url: local_runtime_url.clone(),
        server_id: server_id.clone(),
        relay_token,
    })
    .await?;

    println!("orca-relay-bridge connected for server_id={server_id}");
    println!("forwarding relay traffic to local runtime {local_runtime_url}");
    println!("press Ctrl-C to stop");
    signal::ctrl_c()
        .await
        .context("failed to wait for Ctrl-C")?;
    Ok(())
}

#[derive(Default)]
struct Args {
    relay_url: Option<String>,
    runtime_url: Option<String>,
    server_id: Option<String>,
    help: bool,
}

impl Args {
    fn parse() -> Result<Self> {
        let mut parsed = Self::default();
        let mut args = env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--help" | "-h" => parsed.help = true,
                "--relay-url" => parsed.relay_url = Some(value_after(&mut args, "--relay-url")?),
                "--runtime-url" => {
                    parsed.runtime_url = Some(value_after(&mut args, "--runtime-url")?)
                }
                "--server-id" => parsed.server_id = Some(value_after(&mut args, "--server-id")?),
                _ if arg.starts_with("--relay-url=") => {
                    parsed.relay_url = Some(value_after_equals(&arg, "--relay-url")?)
                }
                _ if arg.starts_with("--runtime-url=") => {
                    parsed.runtime_url = Some(value_after_equals(&arg, "--runtime-url")?)
                }
                _ if arg.starts_with("--server-id=") => {
                    parsed.server_id = Some(value_after_equals(&arg, "--server-id")?)
                }
                _ if arg.starts_with('-') => bail!("unknown option; run orca-relay-bridge --help"),
                _ => bail!("unexpected positional argument; run orca-relay-bridge --help"),
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
