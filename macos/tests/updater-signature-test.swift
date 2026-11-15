// Run: swiftc macos/Updater.swift macos/tests/updater-signature-test.swift -o /tmp/st && /tmp/st
import Foundation

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

/// Test vector made with a throwaway key: `openssl genpkey -algorithm ed25519` + `openssl pkeyutl -sign -rawin`.
@main struct SignatureTest {
    static func main() {
        let pub = "ss0shiIYFY5K9Mb+w1M5x2MMxRzrmwYp8VkFH60eHFs="
        let sig = "1gBkkwWQtSG6HSUSagYQRywdD11XN5mgQqbkRkv5A0rh315NLsfqEnJ2nHSB/N4xxDT2b56SuV1wdenVGY/UDA=="
        let msg = Data("Nexview-0.9.9.zip test bytes".utf8)
        check(Updater.verifySignature(data: msg, signatureBase64: sig, publicKeyBase64: pub), "valid signature")
        check(Updater.verifySignature(data: msg, signatureBase64: sig + "\n", publicKeyBase64: pub), "trailing newline in .sig file")
        check(!Updater.verifySignature(data: Data("Nexview-0.9.9.zip test bytez".utf8), signatureBase64: sig, publicKeyBase64: pub), "tampered message")
        var bad = Data(base64Encoded: sig)!; bad[0] ^= 1
        check(!Updater.verifySignature(data: msg, signatureBase64: bad.base64EncodedString(), publicKeyBase64: pub), "bad signature")
        check(!Updater.verifySignature(data: msg, signatureBase64: "", publicKeyBase64: pub), "empty signature")
        check(!Updater.verifySignature(data: msg, signatureBase64: sig, publicKeyBase64: Updater.signingPublicKey), "wrong key")
        print("ok")
    }
}
