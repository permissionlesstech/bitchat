//! SOCKS5 protocol handler for Arti
//!
//! Implements a minimal SOCKS5 server that forwards connections through Tor.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use arti_client::{IntoTorAddr, TorClient};
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

/// How long a caller may take to finish the handshake before it is dropped.
///
/// Without this, a connection that opens and then says nothing pins a task and
/// a socket for as long as the process lives. Loopback on iOS is reachable by
/// any other app on the device, so that is a hold anyone can take. It bounds
/// only the handshake: building the circuit afterwards is allowed to be slow.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

/// Handle a single SOCKS5 connection
pub async fn handle_socks_connection(
    mut stream: TcpStream,
    peer_addr: SocketAddr,
    client: Arc<TorClient<PreferredRuntime>>,
) -> io::Result<()> {
    // Relay frames and directory requests are small and latency-sensitive, and
    // waiting on Nagle to coalesce them buys nothing over loopback.
    let _ = stream.set_nodelay(true);

    let (dest_host, dest_port) =
        match tokio::time::timeout(HANDSHAKE_TIMEOUT, negotiate(&mut stream)).await {
            Ok(request) => request?,
            Err(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "SOCKS5 handshake timed out",
                ))
            }
        };

    tracing::debug!(
        "SOCKS5 CONNECT from {} to {}:{}",
        peer_addr,
        dest_host,
        dest_port
    );

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
        0,
        0,
        0,
        0, // BND.ADDR
        0,
        0, // BND.PORT
    ];
    stream.write_all(&reply).await?;

    relay(stream, tor_stream).await
}

/// Shuttle bytes between the client and its Tor stream until the Tor side is
/// finished.
///
/// The two directions are deliberately not symmetric.
///
/// A client that half-closes after sending its request is ordinary: plenty of
/// HTTP clients do it. Ending the whole relay at that first EOF cancelled the
/// still-pending Tor-to-client copy and truncated the response, so this waits
/// for the Tor side before finishing.
///
/// It is equally wrong to answer that EOF by shutting the Tor writer down.
/// Tor streams cannot be half-closed: `DataWriter::poll_shutdown` flushes and
/// closes the stream target with `sent_end`, which puts a RELAY_END on the
/// wire, and an exit that receives END drops its connection to the
/// destination. Propagating the client's FIN that way would kill the response
/// at the exit instead of locally, which is worse, not better. C-tor's SOCKS
/// edge defers END until both directions are done, and so does this: the END
/// is emitted when the stream is dropped after the relay returns.
///
/// The client's write half *is* half-closeable, so a finished Tor side is
/// passed on as a FIN before returning.
async fn relay<C, T>(client: C, tor: T) -> io::Result<()>
where
    C: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let (mut client_read, mut client_write) = tokio::io::split(client);
    let (mut tor_read, mut tor_write) = tokio::io::split(tor);

    let upload = async {
        tokio::io::copy(&mut client_read, &mut tor_write).await?;
        // Flush, never shutdown: see above.
        tor_write.flush().await
    };
    let download = async {
        tokio::io::copy(&mut tor_read, &mut client_write).await?;
        client_write.shutdown().await
    };

    tokio::pin!(upload);
    tokio::pin!(download);

    let mut upload_finished = false;
    loop {
        tokio::select! {
            result = &mut upload, if !upload_finished => {
                // A failed upload has nothing left to send, but the response
                // to what did arrive may still be coming.
                if let Err(e) = result {
                    tracing::debug!("Client to Tor copy error: {}", e);
                }
                upload_finished = true;
            }
            result = &mut download => return result,
        }
    }
}

/// Read the greeting and the CONNECT request, returning the requested address.
async fn negotiate(stream: &mut TcpStream) -> io::Result<(String, u16)> {
    // --- Greeting ---
    // Client sends: VER | NMETHODS | METHODS
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;

    if greeting[0] != SOCKS5_VERSION {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Not SOCKS5"));
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
    stream
        .write_all(&[SOCKS5_VERSION, SOCKS5_AUTH_NONE])
        .await?;

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
        send_reply(stream, SOCKS5_REP_FAILURE).await?;
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Only CONNECT supported",
        ));
    }

    // Parse destination address
    Ok(match atyp {
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
            send_reply(stream, SOCKS5_REP_FAILURE).await?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Unsupported address type",
            ));
        }
    })
}

async fn send_reply(stream: &mut TcpStream, rep: u8) -> io::Result<()> {
    let reply = [
        SOCKS5_VERSION,
        rep,
        0x00, // RSV
        SOCKS5_ATYP_IPV4,
        0,
        0,
        0,
        0, // BND.ADDR
        0,
        0, // BND.PORT
    ];
    stream.write_all(&reply).await
}

#[cfg(test)]
mod relay_tests {
    use super::relay;
    use std::pin::Pin;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::task::{Context, Poll};
    use std::time::Duration;
    use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream, ReadBuf};

    const REQUEST: &[u8] = b"GET / HTTP/1.0\r\n\r\n";
    const RESPONSE: &[u8] = b"HTTP/1.0 200 OK\r\n\r\nbody";

    /// Stands in for the Tor stream and records a shutdown that arrives before
    /// this side has itself reached EOF.
    ///
    /// A duplex genuinely supports half-close, so a relay that shuts the Tor
    /// writer down on the client's FIN still looks correct over one. Only on a
    /// real Tor stream does that shutdown become a RELAY_END that kills the
    /// response at the exit, which is why the property is asserted directly
    /// rather than inferred from the bytes that arrive.
    struct TorSideProbe {
        inner: DuplexStream,
        reached_eof: Arc<AtomicBool>,
        shutdown_before_eof: Arc<AtomicBool>,
    }

    impl AsyncRead for TorSideProbe {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            let before = buf.filled().len();
            let polled = Pin::new(&mut self.inner).poll_read(cx, buf);
            if let Poll::Ready(Ok(())) = &polled {
                if buf.filled().len() == before {
                    self.reached_eof.store(true, Ordering::SeqCst);
                }
            }
            polled
        }
    }

    impl AsyncWrite for TorSideProbe {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            Pin::new(&mut self.inner).poll_write(cx, buf)
        }

        fn poll_flush(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<std::io::Result<()>> {
            Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<std::io::Result<()>> {
            if !self.reached_eof.load(Ordering::SeqCst) {
                self.shutdown_before_eof.store(true, Ordering::SeqCst);
            }
            Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }

    #[tokio::test]
    async fn a_client_that_half_closes_still_receives_the_whole_response() {
        let (client, mut client_peer) = tokio::io::duplex(4096);
        let (tor, mut exit) = tokio::io::duplex(4096);
        let reached_eof = Arc::new(AtomicBool::new(false));
        let shutdown_before_eof = Arc::new(AtomicBool::new(false));
        let probe = TorSideProbe {
            inner: tor,
            reached_eof: Arc::clone(&reached_eof),
            shutdown_before_eof: Arc::clone(&shutdown_before_eof),
        };

        let relaying = tokio::spawn(async move { relay(client, probe).await });

        // The shape this exists for: request, FIN, and only then a response.
        client_peer.write_all(REQUEST).await.unwrap();
        client_peer.shutdown().await.unwrap();

        let mut seen = vec![0u8; REQUEST.len()];
        exit.read_exact(&mut seen).await.unwrap();
        assert_eq!(seen, REQUEST);
        tokio::time::sleep(Duration::from_millis(50)).await;
        exit.write_all(RESPONSE).await.unwrap();
        exit.shutdown().await.unwrap();

        let mut response = Vec::new();
        client_peer.read_to_end(&mut response).await.unwrap();

        assert_eq!(response, RESPONSE);
        relaying.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn the_tor_writer_is_never_shut_down_before_the_tor_side_is_done() {
        let (client, mut client_peer) = tokio::io::duplex(4096);
        let (tor, mut exit) = tokio::io::duplex(4096);
        let reached_eof = Arc::new(AtomicBool::new(false));
        let shutdown_before_eof = Arc::new(AtomicBool::new(false));
        let probe = TorSideProbe {
            inner: tor,
            reached_eof: Arc::clone(&reached_eof),
            shutdown_before_eof: Arc::clone(&shutdown_before_eof),
        };

        let relaying = tokio::spawn(async move { relay(client, probe).await });

        client_peer.write_all(REQUEST).await.unwrap();
        client_peer.shutdown().await.unwrap();

        let mut seen = vec![0u8; REQUEST.len()];
        exit.read_exact(&mut seen).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;

        // On a real Tor stream this shutdown is a RELAY_END, and the exit drops
        // its connection to the destination while the response is still in
        // flight.
        assert!(
            !shutdown_before_eof.load(Ordering::SeqCst),
            "relay closed the tor stream while the exit was still answering"
        );

        exit.write_all(RESPONSE).await.unwrap();
        exit.shutdown().await.unwrap();
        let mut response = Vec::new();
        client_peer.read_to_end(&mut response).await.unwrap();
        assert_eq!(response, RESPONSE);
        relaying.await.unwrap().unwrap();
    }
}
