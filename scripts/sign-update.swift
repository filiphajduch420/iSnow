// Signs iSnow release DMGs for the in-app updater (Ed25519, CryptoKit).
//   swift scripts/sign-update.swift keygen        create the signing key (once), print the public key
//   swift scripts/sign-update.swift sign <file>   write <file>.sig (base64 signature of the file's bytes)
//   swift scripts/sign-update.swift pubkey        print the public key (base64) to embed in Updates.swift
//   swift scripts/sign-update.swift verify <file> check <file>.sig against the stored key
// The private key lives only in the login Keychain (generic password, service "iSnow update signing",
// account "ed25519"). It is never printed or written to a file.
import CryptoKit
import Foundation

let service = "iSnow update signing"
let account = "ed25519"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

/// Runs /usr/bin/security; returns its exit status and standard output (standard error is discarded).
@discardableResult
func security(_ args: [String], stdin: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let input = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do { try p.run() } catch { fail("cannot run security: \(error.localizedDescription)") }
    if let stdin {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The signing key from the Keychain, or nil when there is none.
func storedKey() -> Curve25519.Signing.PrivateKey? {
    let (status, out) = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard status == 0 else { return nil }
    guard let raw = Data(base64Encoded: out.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("the Keychain item \"\(service)\" exists but does not hold a valid Ed25519 key")
    }
    return key
}

func requireKey() -> Curve25519.Signing.PrivateKey {
    guard let key = storedKey() else {
        fail("no update signing key in the login Keychain (service \"\(service)\"). "
             + "Create one with: swift scripts/sign-update.swift keygen", code: 2)
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    if storedKey() != nil {
        fail("a signing key already exists in the Keychain – refusing to replace it "
             + "(updates signed with a new key would be rejected by installed copies)")
    }
    let key = Curve25519.Signing.PrivateKey()
    // Through stdin (security -i), so the key never shows up in the process list.
    let command = "add-generic-password -s \"\(service)\" -a \"\(account)\" -l \"\(service)\" "
        + "-D \"application password\" -w \"\(key.rawRepresentation.base64EncodedString())\"\n"
    let (status, _) = security(["-i"], stdin: command)
    guard status == 0, let stored = storedKey(), stored.rawRepresentation == key.rawRepresentation else {
        fail("could not store the key in the login Keychain")
    }
    print("Stored the private key in the login Keychain (service \"\(service)\", account \"\(account)\").")
    print("Public key (embed in Sources/iSnow/Updates.swift):")
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    print(requireKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: swift scripts/sign-update.swift sign <file>", code: 64) }
    let key = requireKey()
    let url = URL(fileURLWithPath: args[1])
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { fail("cannot read \(args[1])") }
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("signature self-check failed") }
    let sigURL = URL(fileURLWithPath: args[1] + ".sig")
    do {
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: sigURL, options: .atomic)
    } catch {
        fail("cannot write \(sigURL.path): \(error.localizedDescription)")
    }
    print("Signed: \(sigURL.path)")
case "verify":
    guard args.count == 2 else { fail("usage: swift scripts/sign-update.swift verify <file>", code: 64) }
    let key = requireKey().publicKey
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe),
          let text = try? String(contentsOfFile: args[1] + ".sig", encoding: .utf8),
          let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("cannot read \(args[1]) or \(args[1]).sig")
    }
    guard key.isValidSignature(sig, for: data) else { fail("INVALID signature for \(args[1])") }
    print("Valid signature: \(args[1])")
default:
    fail("usage: swift scripts/sign-update.swift keygen | pubkey | sign <file> | verify <file>", code: 64)
}
