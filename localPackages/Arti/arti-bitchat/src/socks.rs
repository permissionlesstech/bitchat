//! SOCKS5 protocol handler for Arti
//!
//! Implements a minimal SOCKS5 server that forwards connections through Tor.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;

use arti_client::{TorClient, IntoTorAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tor_rtcompat::PreferredRuntime;

// SOCKS5 constants
const SOCKS5_VERSION: u8 = 0x05;
const SOCKS5_AUTH_NONE: u8 = 0x00;
const SOCKS5_CMD_CONNECT: u8 = 0x01;
const SOCKS5_ATYP_IPV4: u8 = 0x01;
const SOCKS5_ATYP_DOMAIN: u8 = 0x03;
const SOCKS5_ATYP_IPV6: u8 = 0x04;
const SOCKS5_REP_SUCCESS: u8 = 0x00;
const SOCKS5_REP_FAILURE: u8 = 0x01;
const SOCKS5_REP_CONN_REFUSED: u8 = 0x05;

/// Handle a single SOCKS5 connection
pub async fn handle_socks_connection(
    mut stream: TcpStream,
    peer_addr: SocketAddr,
    client: Arc<TorClient<PreferredRuntime>>,
) -> io::Result<()> {
    // --- Greeting ---
    // Client sends: VER | NMETHODS | METHODS
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;

    if greeting[0] != SOCKS5_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Not SOCKS5",
        ));
    }

    let nmethods = greeting[1] as usize;
    let mut methods = vec![0u8; nmethods];
    stream.read_exact(&mut methods).await?;

    // We only support no-auth
    if !methods.contains(&SOCKS5_AUTH_NONE) {
        // Send failure: no acceptable methods
        stream.write_all(&[SOCKS5_VERSION, 0xFF]).await?;
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "No acceptable auth methods",
        ));
    }

    // Accept no-auth
    stream.write_all(&[SOCKS5_VERSION, SOCKS5_AUTH_NONE]).await?;

    // --- Request ---
    // Client sends: VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT
    let mut request_header = [0u8; 4];
    stream.read_exact(&mut request_header).await?;

    if request_header[0] != SOCKS5_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid SOCKS5 request version",
        ));
    }

    let cmd = request_header[1];
    let atyp = request_header[3];

    if cmd != SOCKS5_CMD_CONNECT {
        // We only support CONNECT
        send_reply(&mut stream, SOCKS5_REP_FAILURE).await?;
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Only CONNECT supported",
        ));
    }

    // Parse destination address
    let (dest_host, dest_port) = match atyp {
        SOCKS5_ATYP_IPV4 => {
            let mut addr = [0u8; 4];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            let host = format!("{}.{}.{}.{}", addr[0], addr[1], addr[2], addr[3]);
            (host, port)
        }
        SOCKS5_ATYP_DOMAIN => {
            let mut len_buf = [0u8; 1];
            stream.read_exact(&mut len_buf).await?;
            let len = len_buf[0] as usize;
            let mut domain = vec![0u8; len];
            stream.read_exact(&mut domain).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            let host = String::from_utf8_lossy(&domain).to_string();
            (host, port)
        }
        SOCKS5_ATYP_IPV6 => {
            let mut addr = [0u8; 16];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            // Format IPv6 address
            let segments: Vec<String> = addr
                .chunks(2)
                .map(|c| format!("{:02x}{:02x}", c[0], c[1]))
                .collect();
            let host = format!("[{}]", segments.join(":"));
            (host, port)
        }
        _ => {
            send_reply(&mut stream, SOCKS5_REP_FAILURE).await?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Unsupported address type",
            ));
        }
    };

    tracing::debug!("SOCKS5 CONNECT from {} to {}:{}", peer_addr, dest_host, dest_port);

    // Connect through Tor
    let tor_addr = format!("{}:{}", dest_host, dest_port);
    let tor_addr = match tor_addr.as_str().into_tor_addr() {
        Ok(a) => a,
        Err(e) => {
            tracing::debug!("Invalid Tor address: {}", e);
            send_reply(&mut stream, SOCKS5_REP_FAILURE).await?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Invalid Tor address: {}", e),
            ));
        }
    };

    let tor_stream = match client.connect(tor_addr).await {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!("Tor connect failed: {}", e);
            send_reply(&mut stream, SOCKS5_REP_CONN_REFUSED).await?;
            return Err(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                e.to_string(),
            ));
        }
    };

    // Send success reply
    // Reply: VER | REP | RSV | ATYP | BND.ADDR | BND.PORT
    // We use 0.0.0.0:0 as the bound address since we're proxying
    let reply = [
        SOCKS5_VERSION,
        SOCKS5_REP_SUCCESS,
        0x00, // RSV
        SOCKS5_ATYP_IPV4,
        0, 0, 0, 0, // BND.ADDR
        0, 0, // BND.PORT
    ];
    stream.write_all(&reply).await?;

    // Bidirectional copy
    let (mut client_read, mut client_write) = stream.into_split();
    let (mut tor_read, mut tor_write) = tor_stream.split();

    let client_to_tor = async {
        tokio::io::copy(&mut client_read, &mut tor_write).await
    };
    let tor_to_client = async {
        tokio::io::copy(&mut tor_read, &mut client_write).await
    };

    tokio::select! {
        result = client_to_tor => {
            if let Err(e) = result {
                tracing::debug!("Client to Tor copy error: {}", e);
            }
        }
        result = tor_to_client => {
            if let Err(e) = result {
                tracing::debug!("Tor to client copy error: {}", e);
            }
        }
    }

    Ok(())
}

async fn send_reply(stream: &mut TcpStream, rep: u8) -> io::Result<()> {
    let reply = [
        SOCKS5_VERSION,
        rep,
        0x00, // RSV
        SOCKS5_ATYP_IPV4,
        0, 0, 0, 0, // BND.ADDR
        0, 0, // BND.PORT
    ];
    stream.write_all(&reply).await
}
