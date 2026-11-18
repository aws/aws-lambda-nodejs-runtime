exports.handler = async (event) => {
  console.log("integration-test handler invoked:", JSON.stringify(event));
  return {
    statusCode: 200,
    body: JSON.stringify({ message: "hello world", node: process.version }),
  };
};
