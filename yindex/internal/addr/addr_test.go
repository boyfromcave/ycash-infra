package addr

import "testing"

// Known answers. The transparent and ECC YED (P2PKH) pairs were computed independently (Python
// base58check, the version bytes of addr.go). The post-quantum pairs are rows of the node lines'
// shared vectors (testdata/pq_address_vectors.json, D-9: keyHash 000102…1f under every version);
// TestPQSharedVectors checks every row of that file.
func TestTransparent(t *testing.T) {
	ok := []struct{ in, want string }{
		// transparent: unchanged
		{"smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13", "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"},
		{"s1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT", "s1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT"},
		// YED P2PKH (35): -> the transparent twin
		{"yrECeEBFX2fNasJyBAYuCNJvsYwFnpWxLiL", "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"},
		{"ytEtf9ijxaZgxxUfcHeZnnwHohTYWN4Znit", "smLnehwqrMSzBeBhChcnh6MDvaYJXFTuy13"},
		{"ybLhKoADrkzEAcGoyG2aQRfrmGGitUvduVu", "s1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT"},
		// plain PQ (53, D-9): unchanged
		{"sqf2UdhNDw9wegXF2LBeiWyWQp84g4Bb4ojrg8XsjnMh14GF5jz8t", "sqf2UdhNDw9wegXF2LBeiWyWQp84g4Bb4ojrg8XsjnMh14GF5jz8t"},
		{"tqs2NtpVxfPKsVUMPRU52Hh8ZsX3nTbmQV9HcH4TZ1gUYR3oMuZA3", "tqs2NtpVxfPKsVUMPRU52Hh8ZsX3nTbmQV9HcH4TZ1gUYR3oMuZA3"},
		{"rqf2UsjFAdzsYwqphjSkcTigtzZv2jVWQc3F6XLvBUuVrY97KQTYq", "rqf2UsjFAdzsYwqphjSkcTigtzZv2jVWQc3F6XLvBUuVrY97KQTYq"},
		// YED PQ (53, D-9): -> the plain PQ form of the same network, scheme and key hash
		{"ybf2PMQCQ1tUQMqySGpsc9iwPLRNDkP6V7NAHWxVNR4Xt6wfqpxJT", "sqf2UdhNDw9wegXF2LBeiWyWQp84g4Bb4ojrg8XsjnMh14GF5jz8t"},
		{"ybs2HrZD5SxnXS7fUmNPosBk2aGCgq7CAb4ye4J7dLw8GwcJhYghz", "sqs2P8rNuNEFmknw4pjAvESK43xu98ugkHSg2fsVziEHPtvnuUCai"},
		{"ytf15UFmRUfu1fXGa4W6Gii5ohA5JfrVPSeNnc5Bp4DSbLeW9TMyV", "tqf2UPfVHEK1kRCfLvvYpaEKvdgDKNsfj1SUFjiqJ5ot9aPENmSAm"},
		{"yts2vib1YwbdoxvnCFxC6S8D3hv2PUEHuo8qDFexkt5gzZoorEU6H", "tqs2NtpVxfPKsVUMPRU52Hh8ZsX3nTbmQV9HcH4TZ1gUYR3oMuZA3"},
		{"yrf1M2hF2xLQGsrzJ4ws7UbCjTiHvJxJrsFGg1im6SnVT6iCwEd3r", "rqf2UsjFAdzsYwqphjSkcTigtzZv2jVWQc3F6XLvBUuVrY97KQTYq"},
		{"yrs1FXrFiPQiPx8gLZVPKC41NhZ8PPgQYLx62Z4PMNf5qwNuLHwoP", "rqs2PNtFr55Bg27WkDzGpBBVYEQkVpDc65k4T4gYSQn6FNop3aVFk"},
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
		// the pre-D-9 post-quantum form (2-byte version ‖ scheme byte): refused, a clean cut. These
		// were valid known answers here before D-9 (a q/attest regtest node and the node's
		// src/test/pq_standard_tests.cpp).
		"rq5LdfDfyggmkJz71M7AYoVsjiyhZMAMm7S2diguW13RF2d8n2Rc6",
		"sq4couNBfnJoRxqXF89SWjiPh5wktFi5bb5S4F89xMMsCrqRf2L4z",
		"tq3uz2dSJQZwKwgiMurAaowUceGWbVkNZQFd9bBy4pwJDEbVRn79A",
		"yr2UGYBxhHb8yzYYCjZ1HtJ8cNHP6tNJawkjC4L1wmRiGdFQVjNy5",
		"yb5taumpu5RVtFHRjsEgzLi1T33PqEcM3Ac2MipTj3qcLeGaSRJGu",
		"yt6a6fLGMD6rhJnx5Tx5gtitTf1VrEjXdtQfM54JcWsHC2LXjqjfL",
		"rqf2UsjFAdzsYwqphjSkcTigtzZv2jVWQc3F6XLvBUuVrY97KQTYr", // checksum
		"t1UwuP7MSxnUgVwVm2tUxEgZAyZDhkkfHJT",
		"zs1notatransparentaddress",
	}
	for _, a := range bad {
		if got, err := Transparent(a); err == nil {
			t.Errorf("Transparent(%q) = %q, want ErrInvalid", a, got)
		}
	}
}
