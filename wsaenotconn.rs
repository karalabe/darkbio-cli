//! rustc -O wsaenotconn.rs; ./wsaenotconn TOTAL THREADS connect_timeout|connect
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{mpsc, Mutex};
use std::{env, thread, time::Duration};

/// Encodes success as its count (0 for EOF), or -OS error (-1 if absent).
fn code(result: io::Result<usize>) -> i32 {
    result.map_or_else(|e| -e.raw_os_error().unwrap_or(1), |n| n as i32)
}

/// Runs parallel clients and prints one histogram, including native errors.
fn main() {
    let args: Vec<_> = env::args().collect();
    assert_eq!(args.len(), 4);
    let (n, threads): (usize, usize) = (args[1].parse().unwrap(), args[2].parse().unwrap());
    assert!(n > 0 && threads > 0 && threads <= 256);
    let mode = args[3].as_str();
    assert!(matches!(mode, "connect_timeout" | "connect"));
    let counts = Mutex::new(BTreeMap::new());
    let timeout = Duration::from_secs(2);
    thread::scope(|scope| {
        for id in 0..threads {
            let counts = &counts;
            scope.spawn(move || {
                for _ in (id..n).step_by(threads) {
                    // Clone before writing on the original
                    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
                    let address = listener.local_addr().unwrap();
                    let mut client = match mode {
                        "connect" => TcpStream::connect(address),
                        _ => TcpStream::connect_timeout(&address, timeout),
                    }
                    .unwrap();
                    client.set_nodelay(true).unwrap();
                    let clone = client.try_clone().unwrap();
                    client.set_write_timeout(Some(timeout)).unwrap();
                    let (mut peer, _) = listener.accept().unwrap(); // already connected
                    peer.set_read_timeout(Some(timeout)).unwrap();
                    let (sent, received) = mpsc::channel();
                    let server = thread::spawn(move || {
                        peer.read_exact(&mut [0; 200]).unwrap();
                        sent.send(()).unwrap();
                        code(peer.read(&mut [0]))
                    });
                    client.write_all(&[b'x'; 200]).unwrap();
                    received.recv_timeout(timeout).unwrap();
                    let cloned = code(clone.shutdown(Shutdown::Both).map(|()| 0));
                    let original =
                        (cloned != 0).then(|| code(client.shutdown(Shutdown::Both).map(|()| 0)));
                    // Keep both handles alive until the server read finishes
                    let result = (cloned, original, server.join().unwrap());
                    *counts.lock().unwrap().entry(result).or_insert(0usize) += 1;
                }
            });
        }
    });
    let counts = counts.into_inner().unwrap();
    println!("{mode} n={n} threads={threads} (clone,original,peer)={counts:?}");
}
