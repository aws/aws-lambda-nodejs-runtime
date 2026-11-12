// Reports security-relevant properties of the runtime, for test/security-cases.json.
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const tls = require("node:tls");

// Algorithms the runtime's OpenSSL is configured without (OPENSSL_CONFIGURE_OPTS in lang.env).
const EXCLUDED_CIPHERS = /^(idea|cast|seed|sm4|rc2|rc5)/i;
const EXCLUDED_HASHES = /^(md2|mdc2|sm3)/i;
const EXCLUDED_CURVES = /^(sm2|sect|c2pnb|c2tnb)/i;
const WEAK_TLS_CIPHERS = /rc4|null|exp|des|md5|adh|aecdh|psk|srp|seed|idea|camellia|aria/i;

const PT_DYNAMIC = 2;
const PT_GNU_STACK = 0x6474e551;
const PT_GNU_RELRO = 0x6474e552;
const PF_X = 1;
const ET_DYN = 3;
const DT_BIND_NOW = 24n;
const DT_FLAGS = 30n;
const DT_FLAGS_1 = 0x6ffffffbn;
const DF_BIND_NOW = 8n;
const DF_1_NOW = 1n;

// elf returns the hardening properties of a 64-bit little-endian ELF file, or null if the file
// is not one.
function elf(file) {
  const fd = fs.openSync(file, "r");
  try {
    const read = (length, position) => {
      const buffer = Buffer.alloc(length);
      fs.readSync(fd, buffer, 0, length, position);
      return buffer;
    };
    const header = read(64, 0);
    if (header.readUInt32BE(0) !== 0x7f454c46 || header[4] !== 2 || header[5] !== 1) return null;
    const phoff = Number(header.readBigUInt64LE(32));
    const phentsize = header.readUInt16LE(54);
    const phnum = header.readUInt16LE(56);
    const result = {
      positionIndependent: header.readUInt16LE(16) === ET_DYN,
      relro: false,
      bindNow: false,
      nonExecutableStack: false,
    };
    for (let i = 0; i < phnum; i++) {
      const ph = read(phentsize, phoff + i * phentsize);
      const type = ph.readUInt32LE(0);
      if (type === PT_GNU_RELRO) result.relro = true;
      if (type === PT_GNU_STACK) result.nonExecutableStack = (ph.readUInt32LE(4) & PF_X) === 0;
      if (type === PT_DYNAMIC) {
        const dynamic = read(Number(ph.readBigUInt64LE(32)), Number(ph.readBigUInt64LE(8)));
        for (let offset = 0; offset + 16 <= dynamic.length; offset += 16) {
          const tag = dynamic.readBigInt64LE(offset);
          const value = dynamic.readBigUInt64LE(offset + 8);
          if (tag === DT_BIND_NOW) result.bindNow = true;
          if (tag === DT_FLAGS && value & DF_BIND_NOW) result.bindNow = true;
          if (tag === DT_FLAGS_1 && value & DF_1_NOW) result.bindNow = true;
        }
      }
    }
    return result;
  } finally {
    fs.closeSync(fd);
  }
}

// files lists the regular files under root, without following symbolic links.
function files(root) {
  const found = [];
  const pending = [root];
  while (pending.length) {
    const current = pending.pop();
    const stat = fs.lstatSync(current);
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(current)) pending.push(path.join(current, name));
    } else if (stat.isFile()) {
      found.push({ file: current, mode: stat.mode });
    }
  }
  return found;
}

function ffi() {
  try {
    require("node:ffi");
    return "enabled";
  } catch {
    return "disabled";
  }
}

exports.handler = async () => {
  const shipped = ["/var/lang", "/var/runtime", "/lambda-entrypoint.sh"].flatMap(files);
  // The SDK's dependencies include addons for other operating systems, which are not ELF files.
  const libraries = shipped
    .filter(({ file }) => /\.(so(\.[0-9.]+)?|node)$/.test(file))
    .map(({ file }) => ({ file, properties: elf(file) }))
    .filter(({ properties }) => properties !== null);
  const node = "/var/lang/bin/node";

  return {
    excludedCiphers: crypto.getCiphers().filter((name) => EXCLUDED_CIPHERS.test(name)),
    excludedHashes: crypto.getHashes().filter((name) => EXCLUDED_HASHES.test(name)),
    excludedCurves: crypto.getCurves().filter((name) => EXCLUDED_CURVES.test(name)),
    tlsMinVersion: tls.DEFAULT_MIN_VERSION,
    weakTlsCiphers: tls.getCiphers().filter((name) => WEAK_TLS_CIPHERS.test(name)),
    tlsCipherList: tls.DEFAULT_CIPHERS,
    opensslConf: process.env.OPENSSL_CONF ?? null,
    tlsProfile: process.env._AWS_LAMBDA_RESOLVED_TLS_PROFILE ?? null,
    ffi: ffi(),
    node: { ...elf(node), stackProtector: fs.readFileSync(node).includes("__stack_chk_fail") },
    librariesChecked: libraries.length > 0,
    executableStackLibraries: libraries.filter((l) => !l.properties.nonExecutableStack).map((l) => l.file),
    worldWritableFiles: shipped.filter(({ mode }) => mode & 0o002).map(({ file }) => file),
  };
};
