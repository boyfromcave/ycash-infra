package addr

import "testing"

// Known answers. The regtest PQ pairs are from a q/attest regtest node (ycash-dd 4.5.0 line,
// Falcon active): vault_getnewowner 1|2 returned the yr… address, and validateaddress accepted the
// rq… form with the same pqkeyhash and a TX_PQPKH scriptPubKey (20 <keyHash> 51|52 c2); getblock 2
// renders a payment to it as that rq… address. The mainnet yb… PQ vectors are the node's own
// (src/test/pq_standard_tests.cpp: scheme 1|2, keyHash 32×0x5a); their sq… forms, and the P2PKH
// YED forms, were computed independently (Python base58check, the version bytes of addr.go).
func TestTransparent(t *testing.T) {
	ok := []struct{ in, want string }{
		// transparent: unchanged
		{"smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13", "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"},
		{"s1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT", "s1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT"},
		// YED P2PKH (35): -> the transparent twin
		{"yrECeEBFX2fNasJyBAYuCNJvsYwFnpWxLiL", "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"},
		{"ytEtf9ijxaZgxxUfcHeZnnwHohTYWN4Znit", "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"},
		{"ybLhKoADrkzEAcGoyG2aQRfrmGGitUvduVu", "s1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT"},
		// plain PQ (53): unchanged
		{"rq5LdfDfyggmkJz71M7AYoVsjiyhZMAMm7S2diguW13RF2d8n2Rc6", "rq5LdfDfyggmkJz71M7AYoVsjiyhZMAMm7S2diguW13RF2d8n2Rc6"},
		{"sq4couNBfnJoRxqXF89SWjiPh5wktFi5bb5S4F89xMMsCrqRf2L4z", "sq4couNBfnJoRxqXF89SWjiPh5wktFi5bb5S4F89xMMsCrqRf2L4z"},
		{"tq3uz2dSJQZwKwgiMurAaowUceGWbVkNZQFd9bBy4pwJDEbVRn79A", "tq3uz2dSJQZwKwgiMurAaowUceGWbVkNZQFd9bBy4pwJDEbVRn79A"},
		// YED PQ (53): -> the plain PQ form of the same TX_PQPKH script
		{"yr2UGYBxhHb8yzYYCjZ1HtJ8cNHP6tNJawkjC4L1wmRiGdFQVjNy5", "rq5LdfDfyggmkJz71M7AYoVsjiyhZMAMm7S2diguW13RF2d8n2Rc6"}, // SLH-DSA
		{"yr2VA5rANyC4wfgx6kmvLPy2LxuhHYitwJ8xazzFCdXa1gEZSXSRH", "rq5MXCssfNHhhz8WuNL5bKAmUKc1k1Wx7TpG2fM8ks9Gz5cPeCqKa"}, // Falcon
		{"yb5taumpu5RVtFHRjsEgzLi1T33PqEcM3Ac2MipTj3qcLeGaSRJGu", "sq4couNBfnJoRxqXF89SWjiPh5wktFi5bb5S4F89xMMsCrqRf2L4z"},
		{"yb5vXex4M7GvZURFKa9GcLfL3oxWSxG3t3PfRq4cQwqGM2mH4L3Kg", "sq4ekeYR7pAE7ByLpq428jfiHrrsVyMnSTs58MNJeFMXDFL63vTbT"},
		{"yt6a6fLGMD6rhJnx5Tx5gtitTf1VrEjXdtQfM54JcWsHC2LXjqjfL", "tq3uz2dSJQZwKwgiMurAaowUceGWbVkNZQFd9bBy4pwJDEbVRn79A"},
	}
	for _, c := range ok {
		got, err := Transparent(c.in)
		if err != nil || got != c.want {
			t.Errorf("Transparent(%s) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	bad := []string{
		"",
		"yeA4YgvJsjFUJLJnaRxudpYmGfoXVTFbqAo", // ye… (0x1FE4): gone on the post-quantum line (D-Q-21)
		"yrECeEBFX2fNasJyBAYuCNJvsYwFnpWxLiM", // checksum
		"rq5LdfDfyggmkJz71M7AYoVsjiyhZMAMm7S2diguW13RF2d8n2Rc7", // checksum
		"rq5PXGTPwDkWtSFyHkFsgfPwy5TEQSyCKXUX77YeDfmkDG4jGurKL", // scheme 0x03: not registered
		"t1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT",
		"zs1notatransparentaddress",
	}
	for _, a := range bad {
		if got, err := Transparent(a); err == nil {
			t.Errorf("Transparent(%q) = %q, want ErrInvalid", a, got)
		}
	}
}
