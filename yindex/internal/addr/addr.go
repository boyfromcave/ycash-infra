// Package addr normalises Ycash transparent addresses to the key the index stores, which is the
// address the node renders in getblock's scriptPubKey.addresses:
//
//   - a P2PKH/P2SH address (s1…/s3…/sm…/s2…) is stored as is;
//   - a YED P2PKH address (yb…/yt…/yr…, 35 characters) is a P2PKH address with other base58check
//     version bytes and the same key hash, so it maps to the transparent form exactly as
//     lightwalletd-dd does (frontend/yellowback_addr.go, plan D-L-4);
//   - a plain-YEC post-quantum address (53 characters, D-Q-20) names a TX_PQPKH output,
//     `0x20 <keyHash:32> OP_1|OP_2 OP_CHECKPQSIG`, keyHash = SHA256(scheme ‖ pk); it is stored as is;
//   - a YED post-quantum address (53 characters) names the same TX_PQPKH script under the YED
//     versions (quantum spec §4), so it maps to the plain form of the same network and scheme.
//
// Post-quantum addresses follow decision D-9 (quantum spec §4.1): Base58Check(version(3) ‖
// keyHash(32)), one 3-byte version per (network, coin, scheme), so the prefix shows the scheme:
// plain YEC sqf…/sqs… (main), tqf…/tqs… (test), rqf…/rqs… (regtest); YED ybf…/ybs…, ytf…/yts…,
// yrf…/yrs… (f FN-DSA-512, scheme 2; s SLH-DSA-SHA2-128s, scheme 1). The pre-D-9 form (2-byte
// version ‖ scheme byte, sq…/tq…/rq… and yb…/yt…/yr… under 4DD9/4F61/4C51, 56AB/571E/5710) is
// refused: a clean cut, as the node refuses it.
//
// Version bytes are the node's: ycash-dd/ycash6 src/key_io.cpp PlainPQAddressVersions,
// src/yellowback/params.cpp addressVersion / pqAddressVersions, chainparams.cpp PUBKEY_ADDRESS.
// The mainnet ECC YED prefix is yb… (P2PKH 0x1FDD, D-Q-21); the old ye… (0x1FE4) is gone on the
// post-quantum line and is refused here, as the node refuses it. The post-quantum table is the
// same as lightwalletd-dd's (frontend/yellowback_addr.go pqVersions), written here independently
// (this repository reaches lightwalletd-dd only by running its image) and checked against the
// node lines' shared vectors file (testdata/pq_address_vectors.json).
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

// pqVersion is what one post-quantum address version names (D-9): the network ("main", "test",
// "regtest"), whether it is the YED holder form rather than plain YEC, and the signature scheme
// (OP_CHECKPQSIG, crypto/pq/scheme.h: 1 SLH-DSA-SHA2-128s, 2 FN-DSA-512).
type pqVersion struct {
	network string
	yed     bool
	scheme  byte
}

// pqVersions: every post-quantum address version, the one table decode and encode read. Any
// other version, the pre-D-9 2-byte forms among them, is not a post-quantum address.
var pqVersions = map[[3]byte]pqVersion{
	{0x4D, 0xDD, 0x04}: {"main", false, 2},    // sqf… FN-DSA-512
	{0x4D, 0xDE, 0x6A}: {"main", false, 1},    // sqs… SLH-DSA-SHA2-128s
	{0x4F, 0x65, 0x19}: {"test", false, 2},    // tqf…
	{0x4F, 0x66, 0x7F}: {"test", false, 1},    // tqs…
	{0x4C, 0x54, 0xEF}: {"regtest", false, 2}, // rqf…
	{0x4C, 0x56, 0x55}: {"regtest", false, 1}, // rqs…
	{0x56, 0xAE, 0xDE}: {"main", true, 2},     // ybf…
	{0x56, 0xB0, 0x44}: {"main", true, 1},     // ybs…
	{0x57, 0x21, 0xC9}: {"test", true, 2},     // ytf…
	{0x57, 0x23, 0x30}: {"test", true, 1},     // yts…
	{0x57, 0x14, 0x44}: {"regtest", true, 2},  // yrf…
	{0x57, 0x15, 0xAA}: {"regtest", true, 1},  // yrs…
}

// pqVersionOf is pqVersions read the other way.
var pqVersionOf = func() map[pqVersion][3]byte {
	m := make(map[pqVersion][3]byte, len(pqVersions))
	for v, k := range pqVersions {
		m[k] = v
	}
	return m
}()

const (
	p2pkhLen = 35 // base58check of version(2) + hash160(20)
	pqLen    = 53 // base58check of version(3) + keyHash(32) (D-9)
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

// decodePQ returns what a well-formed 53-character post-quantum address names (its version's
// entry and the 32-byte key hash), and ok. The length is checked before the base58 decode (audit
// E-1); the checksum and the version, which must be one of pqVersions, after it.
func decodePQ(a string) (pqVersion, []byte, bool) {
	if len(a) != pqLen {
		return pqVersion{}, nil, false
	}
	p, ok := decode(a, 35)
	if !ok {
		return pqVersion{}, nil, false
	}
	k, ok := pqVersions[[3]byte{p[0], p[1], p[2]}]
	if !ok {
		return pqVersion{}, nil, false
	}
	return k, p[3:], true
}

// encodePQ is decodePQ's inverse: Base58Check(version(k) ‖ keyHash), or ErrInvalid for a version
// that does not exist or a key hash that is not 32 bytes.
func encodePQ(k pqVersion, keyHash []byte) (string, error) {
	v, ok := pqVersionOf[k]
	if !ok || len(keyHash) != 32 {
		return "", ErrInvalid
	}
	return encode(append(append([]byte{}, v[:]...), keyHash...)), nil
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
		k, keyHash, ok := decodePQ(a)
		if !ok {
			return "", ErrInvalid
		}
		if !k.yed {
			return a, nil
		}
		k.yed = false
		return encodePQ(k, keyHash)
	}
	if !taddrRe.MatchString(a) {
		return "", ErrInvalid
	}
	return a, nil
}
