import {
  LambdaClient,
  InvokeCommand,
  waitUntilFunctionActiveV2,
} from "@aws-sdk/client-lambda";

const functionName = process.argv[2];
if (!functionName) {
  console.error("usage: node invoke.mjs FUNCTION_NAME");
  process.exit(2);
}

const client = new LambdaClient({});

console.log(`waiting for ${functionName} to become Active...`);
await waitUntilFunctionActiveV2({ client, maxWaitTime: 300 }, { FunctionName: functionName });

console.log(`invoking ${functionName}...`);
const response = await client.send(
  new InvokeCommand({
    FunctionName: functionName,
    Payload: Buffer.from(JSON.stringify({ source: "integration-test" })),
  }),
);

const payloadText = response.Payload ? Buffer.from(response.Payload).toString("utf8") : "";
console.log(`StatusCode:    ${response.StatusCode}`);
console.log(`FunctionError: ${response.FunctionError ?? "(none)"}`);
console.log(`Payload:       ${payloadText}`);

const failures = [];
if (response.StatusCode !== 200) {
  failures.push(`expected Invoke StatusCode 200, got ${response.StatusCode}`);
}
if (response.FunctionError) {
  failures.push(`function reported an error: ${response.FunctionError}`);
}

let payload;
try {
  payload = JSON.parse(payloadText);
} catch {
  failures.push(`response payload was not JSON: ${payloadText}`);
}
if (payload && payload.statusCode !== 200) {
  failures.push(`expected handler payload statusCode 200, got ${JSON.stringify(payload.statusCode)}`);
}

if (failures.length) {
  console.error("FAIL");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: invocation returned 200");
