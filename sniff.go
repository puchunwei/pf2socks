package main

import (
	"bytes"
	"encoding/binary"
	"strings"
)

// sniffDomain tries to extract a domain name from the first bytes of a TCP stream.
// Supports TLS SNI and HTTP Host header. Returns empty string if no domain is found.
func sniffDomain(buf []byte) string {
	if len(buf) < 5 {
		return ""
	}
	// TLS handshake starts with 0x16 (ContentType.handshake)
	if buf[0] == 0x16 {
		return sniffTLS(buf)
	}
	return sniffHTTP(buf)
}

// sniffTLS parses a TLS ClientHello and extracts the SNI value.
// TLS record format: type(1) + version(2) + length(2) + handshake
// Handshake format: type(1) + length(3) + version(2) + random(32)
//                 + session_id_len(1) + session_id + cipher_suites_len(2) + cipher_suites
//                 + compression_methods_len(1) + compression_methods
//                 + extensions_len(2) + extensions
func sniffTLS(buf []byte) string {
	if len(buf) < 5 || buf[0] != 0x16 {
		return ""
	}
	// Skip TLS record header (5 bytes)
	p := buf[5:]
	if len(p) < 4 || p[0] != 0x01 { // handshake type: ClientHello
		return ""
	}
	// Skip handshake header (1 type + 3 length) + version (2) + random (32)
	if len(p) < 4+2+32 {
		return ""
	}
	p = p[4+2+32:]

	// session_id
	if len(p) < 1 {
		return ""
	}
	sidLen := int(p[0])
	if len(p) < 1+sidLen {
		return ""
	}
	p = p[1+sidLen:]

	// cipher_suites
	if len(p) < 2 {
		return ""
	}
	csLen := int(binary.BigEndian.Uint16(p[:2]))
	if len(p) < 2+csLen {
		return ""
	}
	p = p[2+csLen:]

	// compression_methods
	if len(p) < 1 {
		return ""
	}
	cmLen := int(p[0])
	if len(p) < 1+cmLen {
		return ""
	}
	p = p[1+cmLen:]

	// extensions
	if len(p) < 2 {
		return ""
	}
	extLen := int(binary.BigEndian.Uint16(p[:2]))
	p = p[2:]
	if len(p) < extLen {
		return ""
	}
	p = p[:extLen]

	// iterate extensions
	for len(p) >= 4 {
		extType := binary.BigEndian.Uint16(p[:2])
		extDataLen := int(binary.BigEndian.Uint16(p[2:4]))
		if len(p) < 4+extDataLen {
			return ""
		}
		extData := p[4 : 4+extDataLen]
		p = p[4+extDataLen:]

		if extType == 0x0000 { // server_name extension
			// server_name_list_len (2) + [name_type (1) + name_len (2) + name]
			if len(extData) < 5 {
				continue
			}
			nameType := extData[2]
			if nameType != 0x00 { // host_name
				continue
			}
			nameLen := int(binary.BigEndian.Uint16(extData[3:5]))
			if len(extData) < 5+nameLen {
				continue
			}
			return string(extData[5 : 5+nameLen])
		}
	}
	return ""
}

// sniffHTTP looks for a Host header in the buffer.
func sniffHTTP(buf []byte) string {
	// Must start with a known HTTP method
	methods := []string{"GET ", "POST ", "HEAD ", "PUT ", "DELETE ", "OPTIONS ", "CONNECT ", "PATCH "}
	ok := false
	for _, m := range methods {
		if bytes.HasPrefix(buf, []byte(m)) {
			ok = true
			break
		}
	}
	if !ok {
		return ""
	}
	idx := bytes.Index(buf, []byte("\r\nHost: "))
	if idx < 0 {
		return ""
	}
	start := idx + len("\r\nHost: ")
	end := bytes.Index(buf[start:], []byte("\r\n"))
	if end < 0 {
		return ""
	}
	host := string(buf[start : start+end])
	// strip port if present
	if colon := strings.LastIndex(host, ":"); colon > 0 && !strings.Contains(host, "]") {
		host = host[:colon]
	}
	return host
}
