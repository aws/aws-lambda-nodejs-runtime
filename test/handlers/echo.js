exports.handler = async (event) => ({
  event,
  executionEnv: process.env.AWS_EXECUTION_ENV,
  node: process.version,
});
