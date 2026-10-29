/* eslint-disable @typescript-eslint/no-explicit-any */
// Ported from family-planner tests/authenticator.ts.
// A software passkey for tests: makes WebAuthn answers (ES256, "none" attestation) the way a
// browser and an authenticator would, so the server's real checks run on them.

const enc = new TextEncoder();

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromB64url(s: string): Uint8Array {
  const bin = atob(s.replaceAll("-", "+").replaceAll("_", "/"));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) {
    out.set(p, i);
    i += p.length;
  }
  return out;
}

/** Just enough CBOR for attestation objects and COSE keys. */
type Cbor = number | string | Uint8Array | Map<Cbor, Cbor>;

function cborHead(major: number, n: number): Uint8Array {
  if (n < 24) return Uint8Array.of((major << 5) | n);
  if (n < 256) return Uint8Array.of((major << 5) | 24, n);
  return Uint8Array.of((major << 5) | 25, n >> 8, n & 255);
}

function cbor(v: Cbor): Uint8Array {
  if (typeof v === "number") return v >= 0 ? cborHead(0, v) : cborHead(1, -1 - v);
  if (typeof v === "string") {
    const bytes = enc.encode(v);
    return concat(cborHead(3, bytes.length), bytes);
  }
  if (v instanceof Uint8Array) return concat(cborHead(2, v.length), v);
  const parts = [cborHead(5, v.size)];
  for (const [k, val] of v) parts.push(cbor(k), cbor(val));
  return concat(...parts);
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
}

function u32(n: number): Uint8Array {
  return Uint8Array.of(n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255);
}

/** ECDSA signatures from WebCrypto are r‖s; WebAuthn wants them DER-encoded. */
function derSignature(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    const v = b.slice(i);
    const body = v[0] & 0x80 ? concat(Uint8Array.of(0), v) : v;
    return concat(Uint8Array.of(0x02, body.length), body);
  };
  const seq = concat(int(raw.slice(0, 32)), int(raw.slice(32)));
  return concat(Uint8Array.of(0x30, seq.length), seq);
}

export class Authenticator {
  private keys!: CryptoKeyPair;
  readonly credentialId = crypto.getRandomValues(new Uint8Array(16));
  private counter = 0;
  private userHandle = "";

  constructor(readonly origin: string) {}

  get id(): string {
    return b64url(this.credentialId);
  }

  private async authData(rpId: string, flags: number, extra: Uint8Array = new Uint8Array()) {
    return concat(await sha256(enc.encode(rpId)), Uint8Array.of(flags), u32(this.counter), extra);
  }

  private clientData(type: string, challenge: string, origin = this.origin) {
    return enc.encode(JSON.stringify({ type, challenge, origin, crossOrigin: false }));
  }

  /** Answers registration options (navigator.credentials.create). */
  async register(options: any, origin = this.origin) {
    this.keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
      "verify",
    ]) as CryptoKeyPair;
    this.userHandle = options.user.id;
    const jwk = await crypto.subtle.exportKey("jwk", this.keys.publicKey);
    const cose = cbor(
      new Map<Cbor, Cbor>([
        [1, 2], // kty: EC2
        [3, -7], // alg: ES256
        [-1, 1], // crv: P-256
        [-2, fromB64url(jwk.x!)],
        [-3, fromB64url(jwk.y!)],
      ]),
    );
    const attested = concat(
      new Uint8Array(16), // AAGUID
      Uint8Array.of(0, this.credentialId.length),
      this.credentialId,
      cose,
    );
    // User present + verified + attested credential data.
    const authData = await this.authData(options.rp.id, 0x45, attested);
    const attestationObject = cbor(
      new Map<Cbor, Cbor>([["fmt", "none"], ["attStmt", new Map()], ["authData", authData]]),
    );
    return {
      id: this.id,
      rawId: this.id,
      type: "public-key",
      response: {
        clientDataJSON: b64url(this.clientData("webauthn.create", options.challenge, origin)),
        attestationObject: b64url(attestationObject),
        transports: ["internal"],
      },
      clientExtensionResults: {},
    };
  }

  /** Answers authentication options (navigator.credentials.get). */
  async signIn(options: any, origin = this.origin) {
    this.counter++;
    const authData = await this.authData(options.rpId, 0x05);
    const clientData = this.clientData("webauthn.get", options.challenge, origin);
    const signed = concat(authData, await sha256(clientData));
    const raw = new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        this.keys.privateKey,
        signed as BufferSource,
      ),
    );
    return {
      id: this.id,
      rawId: this.id,
      type: "public-key",
      response: {
        clientDataJSON: b64url(clientData),
        authenticatorData: b64url(authData),
        signature: b64url(derSignature(raw)),
        userHandle: this.userHandle,
      },
      clientExtensionResults: {},
    };
  }
}
