// Package addr normalises Ycash transparent addresses to the key the index stores, which is the
// address the node renders in getblock's scriptPubKey.addresses:
//
//   - a P2PKH/P2SH address (s1…/s3…/sm…/s2…) is stored as is;
//   - a YED P2PKH address (yb…/yt…/yr…, 35 characters) is a P2PKH address with other base58check
//     version bytes and the same key hash, so it maps to the transparent form exactly as
//     lightwalletd-dd does (frontend/yellowback_addr.go, plan D-L-4);
//   - a plain-YEC post-quantum address (sq…/tq…/rq…, 53 characters, owner decision D-Q-20) names a
//     TX_PQPKH output, `0x20 <keyHash:32> OP_1|OP_2 OP_CHECKPQSIG`, keyHash = SHA256(scheme ‖ pk),
//     as Base58Check(version ‖ scheme ‖ keyHash); it is stored as is;
//   - a YED post-quantum address (yb…/yt…/yr…, 53 characters) names the same TX_PQPKH script
//     under the YED PQ version bytes (quantum spec §4), so it maps to the sq/tq/rq form.
//
// Version bytes are the node's (post-quantum line): ycash-dd src/key_io.cpp PlainPQAddressVersion,
// src/yellowback/params.cpp addressVersion / pqAddressVersion, chainparams.cpp PUBKEY_ADDRESS.
// The mainnet YED prefix is yb… (P2PKH 0x1FDD, PQ 0x56AB, D-Q-21); the old ye… (0x1FE4) is gone
// on the post-quantum line and is refused here, as the node refuses it.
package addr

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"regexp"

	"github.com/btcsuite/btcutil/base58"
)

// yedVersionMap: YED P2PKH version bytes -> transparent P2PKH version bytes.
var yedVersionMap = map[[2]byte][2]byte{
	{0x1F, 0xDD}: {0x1C, 0x28}, // mainnet  yb… -> s1… (D-Q-21)
	{0x20, 0x07}: {0x1C, 0x95}, // testnet  yt… -> sm…
	{0x20, 0x02}: {0x1C, 0x95}, // regtest  yr… -> sm…
}

// yedPQVersionMap: YED PQ version bytes -> plain-YEC PQ version bytes.
var yedPQVersionMap = map[[2]byte][2]byte{
	{0x56, 0xAB}: {0x4D, 0xD9}, // mainnet  yb… -> sq…
	{0x57, 0x1E}: {0x4F, 0x61}, // testnet  yt… -> tq…
	{0x57, 0x10}: {0x4C, 0x51}, // regtest  yr… -> rq…
}

// plainPQVersions: the plain-YEC PQ version bytes (D-Q-20).
var plainPQVersions = map[[2]byte]bool{
	{0x4D, 0xD9}: true, // mainnet  sq…
	{0x4F, 0x61}: true, // testnet  tq…
	{0x4C, 0x51}: true, // regtest  rq…
}

// Registered OP_CHECKPQSIG schemes (crypto/pq/scheme.h): 0x01 SLH-DSA-SHA2-128s, 0x02 FN-DSA-512.
func knownScheme(s byte) bool { return s == 0x01 || s == 0x02 }

const (
	p2pkhLen = 35 // base58check of version(2) + hash160(20)
	pqLen    = 53 // base58check of version(2) + scheme(1) + keyHash(32)
)

var taddrRe = regexp.MustCompile(`\As[a-zA-Z0-9]{34}\z`)

var ErrInvalid = errors.New("invalid transparent address")

func checksum4(b []byte) []byte {
	h := sha256.Sum256(b)
	h = sha256.Sum256(h[:])
	return h[:4]
}

func encode(payload []byte) string {
	return base58.Encode(append(append([]byte{}, payload...), checksum4(payload)...))
}

// decode returns the payload (without checksum) of a base58check string of exactly n payload bytes.
func decode(a string, n int) ([]byte, bool) {
	raw := base58.Decode(a)
	if len(raw) != n+4 || !bytes.Equal(raw[n:], checksum4(raw[:n])) {
		return nil, false
	}
	return raw[:n], true
}

// Transparent returns the index key of a transparent, YED, plain PQ or YED PQ address, or
// ErrInvalid. The length and first character are checked before any base58 decode (decoding is
// quadratic in the input length; lightwalletd-dd audit E-1).
func Transparent(a string) (string, error) {
	switch len(a) {
	case p2pkhLen:
		if a[0] != 'y' {
			break
		}
		p, ok := decode(a, 22)
		if !ok {
			return "", ErrInvalid
		}
		tv, ok := yedVersionMap[[2]byte{p[0], p[1]}]
		if !ok {
			return "", ErrInvalid
		}
		return encode(append([]byte{tv[0], tv[1]}, p[2:]...)), nil
	case pqLen:
		p, ok := decode(a, 35)
		if !ok || !knownScheme(p[2]) {
			return "", ErrInvalid
		}
		v := [2]byte{p[0], p[1]}
		if plainPQVersions[v] {
			return a, nil
		}
		if pv, ok := yedPQVersionMap[v]; ok {
			return encode(append([]byte{pv[0], pv[1]}, p[2:]...)), nil
		}
		return "", ErrInvalid
	}
	if !taddrRe.MatchString(a) {
		return "", ErrInvalid
	}
	return a, nil
}
