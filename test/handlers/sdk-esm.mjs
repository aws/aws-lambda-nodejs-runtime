import { S3Client } from "@aws-sdk/client-s3";

export const handler = async () => ({ s3Client: typeof S3Client });
