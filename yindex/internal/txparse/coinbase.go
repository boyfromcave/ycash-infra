// Package txparse reads the few fields yindex needs from a serialized transaction.
package txparse

import (
	"encoding/binary"
	"errors"
)

// PrefixLen is enough of a transaction for IsCoinbase in every version: the v5 header (20 bytes),
// tx_in_count (at most 5 bytes) and the first prevout (36 bytes). The store reads only this much
// of a stored transaction when it backfills or answers for an output without a stored flag.
const PrefixLen = 64

// maxCompactSize is lightwalletd's bound (parser/internal/bytestring): a larger count is an error.
const maxCompactSize uint64 = 0x02000000

var errShort = errors.New("truncated transaction prefix")

// IsCoinbase reports whether the serialized transaction is a coinbase: exactly one transparent
// input whose prevout is null (all-zero hash, index 0xffffffff), as CTransaction::IsCoinBase.
// It is lightwalletd-dd's parser.IsCoinbase (beta4, GetAddressUtxosReply.coinbase) line for line,
// so the flag yindex serves is the flag lightwalletd-dd computes from the same bytes: only the
// prefix up to the first input is read, for every transaction version (v1..v4, and v5's header
// order), and a truncated prefix is an error, not a verdict.
func IsCoinbase(data []byte) (bool, error) {
	if len(data) < 4 {
		return false, errors.New("could not read header")
	}
	header := binary.LittleEndian.Uint32(data)
	p := 4
	overwintered := header>>31 == 1
	version := header & 0x7FFFFFFF
	if overwintered && version >= 3 {
		if len(data) < p+4 {
			return false, errors.New("could not read nVersionGroupId")
		}
		p += 4
		if version >= 5 {
			// nConsensusBranchId, nLockTime, nExpiryHeight precede the transparent bundle.
			if len(data) < p+12 {
				return false, errors.New("could not read the v5 header")
			}
			p += 12
		}
	}
	inCount, n, err := compactSize(data[p:])
	if err != nil {
		return false, err
	}
	p += n
	if inCount != 1 {
		return false, nil
	}
	if len(data) < p+36 {
		return false, errors.New("could not read the first input's prevout")
	}
	if binary.LittleEndian.Uint32(data[p+32:]) != 0xffffffff {
		return false, nil
	}
	for _, b := range data[p : p+32] {
		if b != 0 {
			return false, nil
		}
	}
	return true, nil
}

// compactSize reads a canonical CompactSize as lightwalletd's bytestring.ReadCompactSize does.
func compactSize(d []byte) (uint64, int, error) {
	if len(d) < 1 {
		return 0, 0, errors.New("could not read tx_in_count")
	}
	var length, minSize uint64
	lenLen := 0
	switch b := d[0]; {
	case b < 253:
		length = uint64(b)
	case b == 253:
		lenLen, minSize = 2, 253
	case b == 254:
		lenLen, minSize = 4, 0x10000
	default:
		return 0, 0, errors.New("could not read tx_in_count")
	}
	if len(d) < 1+lenLen {
		return 0, 0, errShort
	}
	for i := lenLen; i >= 1; i-- {
		length = length<<8 | uint64(d[i])
	}
	if length > maxCompactSize || length < minSize {
		return 0, 0, errors.New("could not read tx_in_count")
	}
	return length, 1 + lenLen, nil
}
