use std::{env, net::SocketAddr};

use anyhow::{bail, Context, Result};
use orca_relay::{app, rewrite_pairing_code, RelayConfig};
use tokio::net::TcpListener;

const REWRITE_PAIRING_CODE_USAGE: &str = "usage: orca-relay rewrite-pairing-code --endpoint <endpoint> <pairing_code>\n\n<pairing_code> may be a bare pairing payload, an orca://pair?... link, or an Orca Desktop browser URL containing #pairing=.\n";

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    if matches!(args.next().as_deref(), Some("rewrite-pairing-code")) {
        return run_rewrite_pairing_code(args);
    }

    let bind = arg_value("--bind")
        .or_else(|| env::var("ORCA_RELAY_BIND").ok())
        .unwrap_or_else(|| "127.0.0.1:8080".to_string());
    let token = env::var("ORCA_RELAY_TOKEN").context("missing ORCA_RELAY_TOKEN")?;
    let version =
        env::var("ORCA_RELAY_VERSION").unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    let addr: SocketAddr = bind.parse().context("invalid bind address")?;
    let listener = TcpListener::bind(addr).await?;

    axum::serve(listener, app(RelayConfig::new(version, token))).await?;
    Ok(())
}

fn run_rewrite_pairing_code(mut args: impl Iterator<Item = String>) -> Result<()> {
    let Some(endpoint_flag) = args.next() else {
        bail!("{REWRITE_PAIRING_CODE_USAGE}");
    };
    if endpoint_flag == "--help" || endpoint_flag == "-h" {
        print!("{REWRITE_PAIRING_CODE_USAGE}");
        return Ok(());
    }
    if endpoint_flag != "--endpoint" {
        bail!("{REWRITE_PAIRING_CODE_USAGE}");
    }
    let Some(endpoint) = args.next() else {
        bail!("{REWRITE_PAIRING_CODE_USAGE}");
    };
    let Some(pairing_code) = args.next() else {
        bail!("{REWRITE_PAIRING_CODE_USAGE}");
    };
    if args.next().is_some() {
        bail!("{REWRITE_PAIRING_CODE_USAGE}");
    }

    println!("{}", rewrite_pairing_code(&pairing_code, &endpoint)?);
    Ok(())
}

fn arg_value(name: &str) -> Option<String> {
    let mut args = env::args();
    while let Some(arg) = args.next() {
        if arg == name {
            return args.next();
        }
    }
    None
}
