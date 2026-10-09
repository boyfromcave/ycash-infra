// Package addr normalises Ycash transparent addresses. A YED address (ye…/yt…/yr…) is a
// transparent P2PKH address with other base58check version bytes and the same key hash, so the
// index stores the transparent form and maps a YED query to it exactly as lightwalletd-dd does
// (frontend/yellowback_addr.go, plan D-L-4).
package addr

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"regexp"

	"github.com/btcsuite/btcutil/base58"
)

var yedVersionMap = map[[2]byte][2]byte{
	{0x1F, 0xE4}: {0x1C, 0x28}, // mainnet  ye… -> s1…
	{0x20, 0x07}: {0x1C, 0x95}, // testnet  yt… -> sm…
	{0x20, 0x02}: {0x1C, 0x95}, // regtest  yr… -> sm…
}

var taddrRe = regexp.MustCompile(`\As[a-zA-Z0-9]{34}\z`)

var ErrInvalid = errors.New("invalid transparent address")

func checksum4(b []byte) []byte {
	h := sha256.Sum256(b)
	h = sha256.Sum256(h[:])
	return h[:4]
}

// Transparent returns the s… form of a transparent or YED address, or ErrInvalid.
func Transparent(a string) (string, error) {
	if len(a) == 35 && a[0] == 'y' {
		raw := base58.Decode(a)
		if len(raw) != 26 || !bytes.Equal(raw[22:], checksum4(raw[:22])) {
			return "", ErrInvalid
		}
		tv, ok := yedVersionMap[[2]byte{raw[0], raw[1]}]
		if !ok {
			return "", ErrInvalid
		}
		p := append([]byte{tv[0], tv[1]}, raw[2:22]...)
		return base58.Encode(append(p, checksum4(p)...)), nil
	}
	if !taddrRe.MatchString(a) {
		return "", ErrInvalid
	}
	return a, nil
}
