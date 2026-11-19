const { S3Client } = require("@aws-sdk/client-s3");

exports.handler = async () => ({ s3Client: typeof S3Client });
