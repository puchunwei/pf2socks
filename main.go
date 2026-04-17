// pf2socks: Transparent proxy helper for macOS
// Translates pf rdr (DIOCNATLOOK) to SOCKS5, the macOS equivalent of ipt2socks.
//
// Receives connections redirected by pf, queries the original destination
// via DIOCNATLOOK ioctl on /dev/pf, then forwards through a SOCKS5 proxy.
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"syscall"
	"time"
	"unsafe"
)

// pf_state_xport is a union (4 bytes, largest member is uint32 spi)
type pfStateXport [4]byte

func (x *pfStateXport) setPort(port uint16) {
	binary.BigEndian.PutUint16(x[:2], port)
}

func (x *pfStateXport) getPort() uint16 {
	return binary.BigEndian.Uint16(x[:2])
}

// pf_addr is a 128-bit address (union, IPv4 uses first 4 bytes)
type pfAddr [16]byte

// pfiocNatlook matches XNU kernel's struct pfioc_natlook (84 bytes)
type pfiocNatlook struct {
	saddr     pfAddr       // 16 bytes
	daddr     pfAddr       // 16 bytes
	rsaddr    pfAddr       // 16 bytes
	rdaddr    pfAddr       // 16 bytes
	sxport    pfStateXport // 4 bytes (union pf_state_xport)
	dxport    pfStateXport // 4 bytes
	rsxport   pfStateXport // 4 bytes
	rdxport   pfStateXport // 4 bytes
	af        uint8        // 1 byte (sa_family_t)
	proto     uint8        // 1 byte
	protoVar  uint8        // 1 byte (proto_variant)
	direction uint8        // 1 byte
}

// DIOCNATLOOK ioctl number for macOS
// _IOWR('D', 23, struct pfioc_natlook)
// = 0xc0000000 | (84 << 16) | ('D' << 8) | 23
const DIOCNATLOOK = 0xc0544417

// PF direction constants (enum { PF_INOUT, PF_IN, PF_OUT, PF_FWD })
const (
	PF_INOUT = 0
	PF_IN    = 1
	PF_OUT   = 2
)

// getOriginalDst queries pf's NAT state table to find the original
// destination address before rdr redirect.
func getOriginalDst(conn net.Conn) (string, uint16, error) {
	localAddr := conn.LocalAddr().(*net.TCPAddr)
	remoteAddr := conn.RemoteAddr().(*net.TCPAddr)

	pf, err := os.OpenFile("/dev/pf", os.O_RDWR, 0)
	if err != nil {
		return "", 0, fmt.Errorf("open /dev/pf: %w", err)
	}
	defer pf.Close()

	var nl pfiocNatlook
	nl.af = syscall.AF_INET
	nl.proto = syscall.IPPROTO_TCP
	nl.direction = PF_OUT

	copy(nl.saddr[:4], remoteAddr.IP.To4())
	nl.sxport.setPort(uint16(remoteAddr.Port))
	copy(nl.daddr[:4], localAddr.IP.To4())
	nl.dxport.setPort(uint16(localAddr.Port))

	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, pf.Fd(), DIOCNATLOOK, uintptr(unsafe.Pointer(&nl)))
	if errno != 0 {
		return "", 0, fmt.Errorf("DIOCNATLOOK: %v", errno)
	}

	ip := net.IPv4(nl.rdaddr[0], nl.rdaddr[1], nl.rdaddr[2], nl.rdaddr[3])
	port := nl.rdxport.getPort()
	return ip.String(), port, nil
}

// connectViaSocks5 establishes a connection to the target through a SOCKS5 proxy.
func connectViaSocks5(socksAddr, targetHost string, targetPort uint16) (net.Conn, error) {
	conn, err := net.Dial("tcp", socksAddr)
	if err != nil {
		return nil, fmt.Errorf("connect socks5: %w", err)
	}

	// SOCKS5 handshake: no auth
	conn.Write([]byte{0x05, 0x01, 0x00})
	resp := make([]byte, 2)
	if _, err := io.ReadFull(conn, resp); err != nil {
		conn.Close()
		return nil, fmt.Errorf("socks5 handshake: %w", err)
	}
	if resp[0] != 0x05 || resp[1] != 0x00 {
		conn.Close()
		return nil, fmt.Errorf("socks5 auth failed: %v", resp)
	}

	// SOCKS5 CONNECT request
	ip := net.ParseIP(targetHost).To4()
	req := []byte{0x05, 0x01, 0x00, 0x01} // VER, CMD=CONNECT, RSV, ATYP=IPv4
	req = append(req, ip...)
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, targetPort)
	req = append(req, portBytes...)
	conn.Write(req)

	// Read response
	resp = make([]byte, 10)
	if _, err := io.ReadFull(conn, resp); err != nil {
		conn.Close()
		return nil, fmt.Errorf("socks5 connect: %w", err)
	}
	if resp[1] != 0x00 {
		conn.Close()
		return nil, fmt.Errorf("socks5 connect refused: status=%d", resp[1])
	}

	return conn, nil
}

// peekFirstBytes reads up to maxLen bytes from conn with a timeout.
// Returns what was read; the bytes are NOT consumed from the connection
// (they will be replayed by prepending to the forwarding stream).
func peekFirstBytes(conn net.Conn, maxLen int, timeout time.Duration) []byte {
	conn.SetReadDeadline(time.Now().Add(timeout))
	defer conn.SetReadDeadline(time.Time{})

	buf := make([]byte, maxLen)
	n, _ := conn.Read(buf)
	return buf[:n]
}

func handleConn(conn net.Conn, socksAddr string) {
	defer conn.Close()

	host, port, err := getOriginalDst(conn)
	if err != nil {
		log.Printf("[%s] failed to get original dst: %v", conn.RemoteAddr(), err)
		return
	}

	// Peek first bytes to sniff domain (TLS SNI or HTTP Host).
	// 200ms timeout — non-HTTP/TLS protocols won't send first, so we fall through.
	peeked := peekFirstBytes(conn, 4096, 200*time.Millisecond)
	domain := sniffDomain(peeked)

	if domain != "" {
		log.Printf("[%s] -> %s:%d (%s)", conn.RemoteAddr(), host, port, domain)
	} else {
		log.Printf("[%s] -> %s:%d", conn.RemoteAddr(), host, port)
	}

	remote, err := connectViaSocks5(socksAddr, host, port)
	if err != nil {
		log.Printf("[%s] socks5 failed: %v", conn.RemoteAddr(), err)
		return
	}
	defer remote.Close()

	// Replay the peeked bytes first, then stream the rest.
	if len(peeked) > 0 {
		if _, err := remote.Write(peeked); err != nil {
			log.Printf("[%s] replay failed: %v", conn.RemoteAddr(), err)
			return
		}
	}

	done := make(chan struct{})
	go func() {
		io.Copy(remote, conn)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(conn, remote)
		done <- struct{}{}
	}()
	<-done
}

func main() {
	listenAddr := "127.0.0.1:1234"
	socksAddr := "127.0.0.1:1080"

	if len(os.Args) >= 2 {
		listenAddr = os.Args[1]
	}
	if len(os.Args) >= 3 {
		socksAddr = os.Args[2]
	}

	if _, _, err := net.SplitHostPort(listenAddr); err != nil {
		log.Fatalf("invalid listen address: %s", listenAddr)
	}
	if _, _, err := net.SplitHostPort(socksAddr); err != nil {
		log.Fatalf("invalid socks5 address: %s", socksAddr)
	}

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("listen failed: %v", err)
	}

	log.Printf("pf2socks started: listen %s, socks5 proxy %s", listenAddr, socksAddr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept failed: %v", err)
			continue
		}
		go handleConn(conn, socksAddr)
	}
}
