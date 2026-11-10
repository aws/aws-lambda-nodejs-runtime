// Runs the smoke-test cases against a runtime image through the public Runtime Interface
// Emulator.
//
// Usage: node test/run.mjs IMAGE PLATFORM [CASES.json]
//   CASES.json defaults to test/cases.json. AWS credential and region variables set in the
//   environment (for example from `aws configure export-credentials --format env`) are passed
//   to the function, for cases that call AWS.

import { execFileSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Public RIE release assets, pinned by the digests GitHub publishes for them.
const RIE = {
  version: "v1.37",
  "linux/arm64": {
    asset: "aws-lambda-rie-arm64",
    sha256: "ec2e5d09633d853834c008b1ef264bf834b258a94d551d2b2074966494b39a21",
  },
  "linux/amd64": {
    asset: "aws-lambda-rie-x86_64",
    sha256: "6b1e686e62ab2baf5759c412c4864276ef2a88b094fca53ec070637ccba9b9a5",
  },
};
const STARTUP_TIMEOUT_MS = 15000;

const [image, platform, casesFile] = process.argv.slice(2);
if (!image || !RIE[platform]) {
  console.error("usage: node test/run.mjs IMAGE linux/arm64|linux/amd64");
  process.exit(2);
}

const testDir = dirname(fileURLToPath(import.meta.url));
const cases = JSON.parse(readFileSync(casesFile ?? join(testDir, "cases.json"), "utf8"));
const AWS_ENV = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION"];
const awsEnv = AWS_ENV.filter((name) => process.env[name]).flatMap((name) => ["-e", name]);
const rie = RIE[platform];
const testImage = `lambda-runtime/test:${platform.replace("linux/", "")}`;

function docker(...args) {
  return execFileSync("docker", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

// Every key in expected must be present in actual with an equal value.
function contains(actual, expected) {
  if (typeof expected !== "object" || expected === null) return isDeepStrictEqual(actual, expected);
  if (typeof actual !== "object" || actual === null) return false;
  return Object.entries(expected).every(([k, v]) => contains(actual[k], v));
}

async function invoke(port, event) {
  const deadline = Date.now() + STARTUP_TIMEOUT_MS;
  for (;;) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/2015-03-31/functions/function/invocations`, {
        method: "POST",
        body: JSON.stringify(event),
      });
      return await response.json();
    } catch (error) {
      if (Date.now() > deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
}

docker(
  "buildx", "build", "--platform", platform, "--load", "--tag", testImage,
  "--build-arg", `IMAGE=${image}`,
  "--build-arg", `RIE_URL=https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/${RIE.version}/${rie.asset}`,
  "--build-arg", `RIE_SHA256=${rie.sha256}`,
  testDir,
);

let failures = 0;
for (const testCase of cases) {
  const container = docker("run", "-d", "--platform", platform, ...awsEnv, "-p", "127.0.0.1::8080", testImage, testCase.handler);
  try {
    const port = docker("port", container, "8080/tcp").split(":").pop();
    const actual = await invoke(port, testCase.event);
    if (contains(actual, testCase.expect)) {
      console.log(`pass  ${testCase.name}`);
      if (actual.userAgent) console.log(`      user agent: ${actual.userAgent}`);
    } else {
      failures++;
      console.log(`FAIL  ${testCase.name}\n  expected ${JSON.stringify(testCase.expect)}\n  actual   ${JSON.stringify(actual)}`);
      console.log(docker("logs", container).replace(/^/gm, "  | "));
    }
  } finally {
    docker("rm", "-f", container);
  }
}

console.log(`${cases.length - failures}/${cases.length} passed`);
process.exit(failures ? 1 : 0);
