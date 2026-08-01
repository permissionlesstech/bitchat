//! Byte-transparent monitor between Arti's unmanaged pluggable-transport
//! client and IPtProxy's loopback SOCKS listener.
//!
//! Arti still owns the complete SOCKS handshake and bridge parameters. This
//! monitor only proves that Arti opened the transport and that IPtProxy's
//! listener accepted a TCP connection.

use std::io;
use std::net::SocketAddr;

use tokio::net::{TcpListener, TcpStream};
use tokio::task::{JoinHandle, JoinSet};

pub(crate) struct TransportMonitor {
    pub(crate) local_address: SocketAddr,
    task: JoinHandle<()>,
}

impl Drop for TransportMonitor {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub(crate) async fn start(upstream: SocketAddr) -> io::Result<TransportMonitor> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let local_address = listener.local_addr()?;
    super::advance_transport_stage(1, "Transport handoff monitor ready");

    let task = tokio::spawn(async move {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let Ok((mut arti_stream, _)) = accepted else {
                        break;
                    };
                    super::advance_transport_stage(2, "Tor opened transport proxy");
                    connections.spawn(async move {
                        let Ok(mut transport_stream) = TcpStream::connect(upstream).await else {
                            super::update_summary("Error: transport listener unavailable");
                            return;
                        };
                        super::advance_transport_stage(3, "Connected to transport listener");
                        let _ = tokio::io::copy_bidirectional(
                            &mut arti_stream,
                            &mut transport_stream,
                        ).await;
                    });
                }
                _ = connections.join_next(), if !connections.is_empty() => {}
            }
        }
    });

    Ok(TransportMonitor {
        local_address,
        task,
    })
}
