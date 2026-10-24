// mariner-ss: a local SOCKS5 server (CONNECT + UDP ASSOCIATE) that relays through
// an Outline/Shadowsocks server using the Outline SDK, including the "prefix"
// disguise that shadowsocks-rust's sslocal doesn't support.
//
// It reads the same JSON file Mariner writes for sslocal, plus an optional
// base64 "prefix" per server:
//
//	{"servers": [{"server", "server_port", "method", "password", "prefix"}],
//	 "locals":  [{"local_address", "local_port"}]}
package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.getoutline.org/sdk/transport"
	"golang.getoutline.org/sdk/transport/shadowsocks"
)

type config struct {
	Servers []struct {
		Server     string `json:"server"`
		ServerPort int    `json:"server_port"`
		Method     string `json:"method"`
		Password   string `json:"password"`
		Prefix     string `json:"prefix"`
	} `json:"servers"`
	Locals []struct {
		LocalAddress string `json:"local_address"`
		LocalPort    int    `json:"local_port"`
	} `json:"locals"`
}

// version is set at build time (-ldflags "-X main.version=...") for releases.
var version = "dev"

var (
	streamDialer   *shadowsocks.StreamDialer
	packetListener transport.PacketListener
	errLog         = newLimitedLogger(time.Second)
)

func main() {
	log.SetFlags(0)
	cfgPath := flag.String("c", "", "config file (sslocal-style JSON)")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("mariner-ss", version)
		return
	}
	raw, err := os.ReadFile(*cfgPath)
	if err != nil {
		log.Fatalf("reading config: %v", err)
	}
	var cfg config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		log.Fatalf("parsing config: %v", err)
	}
	if len(cfg.Servers) != 1 || len(cfg.Locals) != 1 {
		log.Fatal("config needs exactly one server and one local")
	}
	s, l := cfg.Servers[0], cfg.Locals[0]
	key, err := shadowsocks.NewEncryptionKey(s.Method, s.Password)
	if err != nil {
		log.Fatalf("encryption key: %v", err)
	}
	server := net.JoinHostPort(s.Server, strconv.Itoa(s.ServerPort))
	streamDialer, err = shadowsocks.NewStreamDialer(&transport.TCPEndpoint{Address: server}, key)
	if err != nil {
		log.Fatalf("stream dialer: %v", err)
	}
	prefixNote := "no prefix"
	if s.Prefix != "" {
		prefix, err := base64.StdEncoding.DecodeString(s.Prefix)
		if err != nil {
			log.Fatalf("prefix is not base64: %v", err)
		}
		if len(prefix) > key.SaltSize() {
			log.Fatalf("prefix is %d bytes, longer than the %d-byte salt", len(prefix), key.SaltSize())
		}
		streamDialer.SaltGenerator = shadowsocks.NewPrefixSaltGenerator(prefix)
		prefixNote = fmt.Sprintf("%d-byte prefix", len(prefix))
	}
	packetListener, err = shadowsocks.NewPacketListener(&transport.UDPEndpoint{Address: server}, key)
	if err != nil {
		log.Fatalf("packet listener: %v", err)
	}
	listen := net.JoinHostPort(l.LocalAddress, strconv.Itoa(l.LocalPort))
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("mariner-ss: SOCKS5 on %s via %s (%s, %s)", listen, server, s.Method, prefixNote)
	for {
		c, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			errLog.Printf("accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go handle(c.(*net.TCPConn))
	}
}

// --- SOCKS5 ---------------------------------------------------------------------

const (
	cmdConnect      = 1
	cmdUDPAssociate = 3
	atypIPv4        = 1
	atypDomain      = 3
	atypIPv6        = 4
)

func handle(c *net.TCPConn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, 262)
	if _, err := io.ReadFull(c, buf[:2]); err != nil || buf[0] != 5 {
		return
	}
	if _, err := io.ReadFull(c, buf[:buf[1]]); err != nil {
		return
	}
	if _, err := c.Write([]byte{5, 0}); err != nil { // no authentication
		return
	}
	if _, err := io.ReadFull(c, buf[:3]); err != nil || buf[0] != 5 {
		return
	}
	cmd := buf[1]
	target, err := readAddr(c)
	if err != nil {
		reply(c, 8, nil)
		return
	}
	switch cmd {
	case cmdConnect:
		handleConnect(c, target)
	case cmdUDPAssociate:
		handleUDP(c)
	default:
		reply(c, 7, nil)
	}
}

func readAddr(r io.Reader) (string, error) {
	var b [256]byte
	if _, err := io.ReadFull(r, b[:1]); err != nil {
		return "", err
	}
	var host string
	switch b[0] {
	case atypIPv4:
		if _, err := io.ReadFull(r, b[:4]); err != nil {
			return "", err
		}
		host = net.IP(b[:4]).String()
	case atypIPv6:
		if _, err := io.ReadFull(r, b[:16]); err != nil {
			return "", err
		}
		host = net.IP(b[:16]).String()
	case atypDomain:
		if _, err := io.ReadFull(r, b[:1]); err != nil {
			return "", err
		}
		n := int(b[0])
		if _, err := io.ReadFull(r, b[:n]); err != nil {
			return "", err
		}
		host = string(b[:n])
	default:
		return "", errors.New("bad address type")
	}
	if _, err := io.ReadFull(r, b[:2]); err != nil {
		return "", err
	}
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(b[:2])))), nil
}

// encodeAddr renders host:port in SOCKS5 address form (ATYP + address + port).
func encodeAddr(hostport string) []byte {
	host, portStr, err := net.SplitHostPort(hostport)
	if err != nil {
		return []byte{atypIPv4, 0, 0, 0, 0, 0, 0}
	}
	port, _ := strconv.Atoi(portStr)
	var out []byte
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			out = append([]byte{atypIPv4}, ip4...)
		} else {
			out = append([]byte{atypIPv6}, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			host = host[:255]
		}
		out = append([]byte{atypDomain, byte(len(host))}, host...)
	}
	return binary.BigEndian.AppendUint16(out, uint16(port))
}

func reply(c net.Conn, code byte, bound net.Addr) error {
	addr := []byte{atypIPv4, 0, 0, 0, 0, 0, 0}
	if bound != nil {
		addr = encodeAddr(bound.String())
	}
	_, err := c.Write(append([]byte{5, code, 0}, addr...))
	return err
}

func handleConnect(c *net.TCPConn, target string) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	remote, err := streamDialer.DialStream(ctx, target)
	cancel()
	if err != nil {
		errLog.Printf("connect %s: %v", target, err)
		reply(c, 5, nil)
		return
	}
	defer remote.Close()
	if reply(c, 0, nil) != nil {
		return
	}
	c.SetDeadline(time.Time{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		io.Copy(remote, c)
		remote.CloseWrite()
	}()
	if _, err := io.Copy(c, remote); err != nil && !isClosed(err) {
		errLog.Printf("relay %s: %v", target, err)
	}
	c.CloseWrite()
	wg.Wait()
}

func isClosed(err error) bool {
	return errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF)
}

// handleUDP serves one UDP association for as long as its TCP control connection stays open.
func handleUDP(c *net.TCPConn) {
	localIP := c.LocalAddr().(*net.TCPAddr).IP
	relay, err := net.ListenUDP("udp", &net.UDPAddr{IP: localIP})
	if err != nil {
		reply(c, 1, nil)
		return
	}
	defer relay.Close()
	remote, err := packetListener.ListenPacket(context.Background())
	if err != nil {
		errLog.Printf("udp listen: %v", err)
		reply(c, 1, nil)
		return
	}
	defer remote.Close()
	if reply(c, 0, relay.LocalAddr()) != nil {
		return
	}
	c.SetDeadline(time.Time{})

	var client atomic.Pointer[net.UDPAddr]
	clientIP := c.RemoteAddr().(*net.TCPAddr).IP
	done := make(chan struct{})
	go func() { // control connection closed -> association ends
		io.Copy(io.Discard, c)
		close(done)
		relay.Close()
		remote.Close()
	}()
	go func() { // server -> client
		buf := make([]byte, 65535)
		for {
			n, from, err := remote.ReadFrom(buf)
			if err != nil {
				return
			}
			to := client.Load()
			if to == nil {
				continue
			}
			pkt := append(append([]byte{0, 0, 0}, encodeAddr(from.String())...), buf[:n]...)
			relay.WriteToUDP(pkt, to)
		}
	}()
	buf := make([]byte, 65535)
	for { // client -> server
		n, from, err := relay.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if !from.IP.Equal(clientIP) || n < 4 || buf[2] != 0 { // wrong sender, or fragmented
			continue
		}
		client.Store(from)
		r := &byteReader{b: buf[3:n]}
		target, err := readAddr(r)
		if err != nil {
			continue
		}
		if _, err := remote.WriteTo(r.b, hostPortAddr(target)); err != nil {
			select {
			case <-done:
				return
			default:
				errLog.Printf("udp send %s: %v", target, err)
			}
		}
	}
}

type byteReader struct{ b []byte }

func (r *byteReader) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}

type hostPortAddr string

func (a hostPortAddr) Network() string { return "udp" }
func (a hostPortAddr) String() string  { return string(a) }

// --- logging -----------------------------------------------------------------------

// limitedLogger logs at most one line per interval and reports how many it dropped.
type limitedLogger struct {
	mu       sync.Mutex
	every    time.Duration
	last     time.Time
	dropped  int
}

func newLimitedLogger(every time.Duration) *limitedLogger { return &limitedLogger{every: every} }

func (l *limitedLogger) Printf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if time.Since(l.last) < l.every {
		l.dropped++
		return
	}
	msg := fmt.Sprintf(format, args...)
	if l.dropped > 0 {
		msg += fmt.Sprintf(" (+%d similar suppressed)", l.dropped)
		l.dropped = 0
	}
	l.last = time.Now()
	log.Print(msg)
}
