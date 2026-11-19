// Runs test cases against a runtime image through the public Runtime Interface Emulator.
//
// Usage: node test/run.mjs IMAGE PLATFORM [CASES.json]
//   CASES.json defaults to test/cases.json, the smoke tests; test/security-cases.json holds the
//   security tests. AWS credential and region variables set in the environment (for example
//   from `aws configure export-credentials --format env`) are passed to the function, for
//   cases that call AWS.
//
// A case has:
//   name, handler, event
//   env         optional: environment variables for the function
//   expect      optional: the invocation's response must contain these keys with equal values
//   expectLogs  optional: the container's log must contain this text

import { execFileSync, spawnSync } from "node:child_process";
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

// The container's stdout and stderr.
function logs(container) {
  const result = spawnSync("docker", ["logs", container], { encoding: "utf8" });
  return result.stdout + result.stderr;
}

// Every key in expected must be present in actual with an equal value. Arrays must have the
// same length.
function contains(actual, expected) {
  if (typeof expected !== "object" || expected === null) return isDeepStrictEqual(actual, expected);
  if (Array.isArray(expected) && !(Array.isArray(actual) && actual.length === expected.length)) return false;
  if (typeof actual !== "object" || actual === null) return false;
  return Object.entries(expected).every(([k, v]) => contains(actual[k], v));
}

// invoke returns the function's response, parsed as JSON when it is JSON.
async function invoke(port, event) {
  const deadline = Date.now() + STARTUP_TIMEOUT_MS;
  for (;;) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/2015-03-31/functions/function/invocations`, {
        method: "POST",
        body: JSON.stringify(event),
      });
      const body = await response.text();
      try {
        return JSON.parse(body);
      } catch {
        return body;
      }
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
  const env = Object.entries(testCase.env ?? {}).flatMap(([name, value]) => ["-e", `${name}=${value}`]);
  const container = docker("run", "-d", "--platform", platform, ...awsEnv, ...env, "-p", "127.0.0.1::8080", testImage, testCase.handler);
  try {
    const port = docker("port", container, "8080/tcp").split(":").pop();
    const actual = await invoke(port, testCase.event);
    const output = logs(container);
    const responseOk = testCase.expect === undefined || contains(actual, testCase.expect);
    const logsOk = testCase.expectLogs === undefined || output.includes(testCase.expectLogs);
    if (responseOk && logsOk) {
      console.log(`pass  ${testCase.name}`);
      if (actual?.userAgent) console.log(`      user agent: ${actual.userAgent}`);
    } else {
      failures++;
      console.log(`FAIL  ${testCase.name}`);
      if (!responseOk) console.log(`  expected ${JSON.stringify(testCase.expect)}\n  actual   ${JSON.stringify(actual)}`);
      if (!logsOk) console.log(`  expected the log to contain ${JSON.stringify(testCase.expectLogs)}`);
      console.log(output.replace(/^/gm, "  | "));
    }
  } finally {
    docker("rm", "-f", container);
  }
}

console.log(`${cases.length - failures}/${cases.length} passed`);
process.exit(failures ? 1 : 0);
