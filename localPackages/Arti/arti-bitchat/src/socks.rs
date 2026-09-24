//! SOCKS5 protocol handler for Arti
//!
//! Implements a minimal SOCKS5 server that forwards connections through Tor.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;

use arti_client::{TorClient, IntoTorAddr};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
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

    relay(stream, tor_stream).await
}

/// Relay bytes between the local SOCKS `client` and the `tor` stream until the
/// response is fully delivered.
///
/// Tor streams are not half-closeable: shutting down the Tor writer emits a
/// RELAY_END cell that tears the whole stream down at the exit. So a client
/// half-close (EOF on client->tor) must not be propagated as a shutdown, or a
/// response still in flight is lost at the exit. Only the client's write half
/// is closed on EOF; the Tor stream's END is deferred until both halves drop at
/// the end of the relay. (`copy_bidirectional` cannot be used here: it shuts
/// down the peer writer at the first EOF, which for Tor is exactly this bug.)
async fn relay<C, T>(client: C, tor: T) -> io::Result<()>
where
    C: AsyncRead + AsyncWrite + Unpin,
    T: AsyncRead + AsyncWrite + Unpin,
{
    let (mut client_read, mut client_write) = tokio::io::split(client);
    let (mut tor_read, mut tor_write) = tokio::io::split(tor);

    // Request path: on EOF, flush the Tor writer but do not shut it down.
    let upload = async {
        tokio::io::copy(&mut client_read, &mut tor_write).await?;
        tor_write.flush().await
    };
    // Response path: on EOF (the exit sent END, or the destination finished),
    // half-close the client's write side and finish.
    let download = async {
        tokio::io::copy(&mut tor_read, &mut client_write).await?;
        client_write.shutdown().await
    };
    tokio::pin!(upload, download);

    // The relay ends when the response path finishes or either path errors. The
    // request path finishing only stops that copy; it never cuts the response
    // short.
    let mut upload_done = false;
    loop {
        tokio::select! {
            result = &mut download => return result,
            result = &mut upload, if !upload_done => {
                result?;
                upload_done = true;
            }
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::task::{Context, Poll};
    use std::time::Duration;
    use tokio::io::ReadBuf;

    // The client half-closes its write side after sending a request; the far
    // side replies only afterward. A relay that stops at the first EOF loses
    // the response. The timeout turns that into a failure rather than a hang.
    #[tokio::test]
    async fn relay_delivers_response_after_client_half_close() {
        let (mut client, a) = tokio::io::duplex(64);
        let (mut server, b) = tokio::io::duplex(64);

        let server_task = tokio::spawn(async move {
            let mut req = [0u8; 3];
            server.read_exact(&mut req).await.unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
            server.write_all(b"RESPONSE").await.unwrap();
            server.shutdown().await.unwrap();
        });

        let client_task = tokio::spawn(async move {
            client.write_all(b"REQ").await.unwrap();
            client.shutdown().await.unwrap();
            let mut got = Vec::new();
            let _ =
                tokio::time::timeout(Duration::from_secs(2), client.read_to_end(&mut got)).await;
            got
        });

        relay(a, b).await.unwrap();

        assert_eq!(client_task.await.unwrap(), b"RESPONSE");
        server_task.await.unwrap();
    }

    // A Tor writer shutdown emits a stream-killing END, so the relay must never
    // shut down the Tor side before that side has itself reached EOF. This wraps
    // the Tor stream and flags a shutdown that happens too early — the property
    // `copy_bidirectional` violates and the asymmetric relay upholds.
    struct FlagEarlyShutdown<S> {
        inner: S,
        read_eof: bool,
        early_shutdown: Arc<AtomicBool>,
    }

    impl<S: AsyncRead + Unpin> AsyncRead for FlagEarlyShutdown<S> {
        fn poll_read(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let this = self.get_mut();
            let before = buf.filled().len();
            let result = Pin::new(&mut this.inner).poll_read(cx, buf);
            if let Poll::Ready(Ok(())) = &result {
                if buf.filled().len() == before {
                    this.read_eof = true;
                }
            }
            result
        }
    }

    impl<S: AsyncWrite + Unpin> AsyncWrite for FlagEarlyShutdown<S> {
        fn poll_write(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
        }

        fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.get_mut().inner).poll_flush(cx)
        }

        fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            let this = self.get_mut();
            if !this.read_eof {
                this.early_shutdown.store(true, Ordering::SeqCst);
            }
            Pin::new(&mut this.inner).poll_shutdown(cx)
        }
    }

    #[tokio::test]
    async fn relay_does_not_shut_down_tor_writer_before_response() {
        let (mut client, a) = tokio::io::duplex(64);
        let (mut server, b) = tokio::io::duplex(64);

        let early_shutdown = Arc::new(AtomicBool::new(false));
        let tor = FlagEarlyShutdown {
            inner: b,
            read_eof: false,
            early_shutdown: early_shutdown.clone(),
        };

        let server_task = tokio::spawn(async move {
            let mut req = [0u8; 3];
            server.read_exact(&mut req).await.unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
            server.write_all(b"RESPONSE").await.unwrap();
            server.shutdown().await.unwrap();
        });

        let client_task = tokio::spawn(async move {
            client.write_all(b"REQ").await.unwrap();
            client.shutdown().await.unwrap();
            let mut got = Vec::new();
            let _ =
                tokio::time::timeout(Duration::from_secs(2), client.read_to_end(&mut got)).await;
            got
        });

        relay(a, tor).await.unwrap();

        assert!(
            !early_shutdown.load(Ordering::SeqCst),
            "relay shut down the Tor writer before the response arrived"
        );
        assert_eq!(client_task.await.unwrap(), b"RESPONSE");
        server_task.await.unwrap();
    }
}
