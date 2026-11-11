#!/bin/sh
# Regenerates package.json and package-lock.json from a managed runtime image: the @aws-sdk
# packages it ships, at its versions, and npm's resolution of their dependencies, made with the
# image's own npm. Needs Docker, and network access to the image's registry and npm.
#
#   update.sh [IMAGE]    IMAGE defaults to public.ecr.aws/lambda/nodejs:26
set -eu
image=${1:-public.ecr.aws/lambda/nodejs:26}
dir=$(cd "$(dirname "$0")" && pwd)

docker pull -q --platform linux/arm64 "$image" > /dev/null
digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")

docker run --rm --platform linux/arm64 --entrypoint /var/lang/bin/node "$digest" -e '
  const fs = require("fs");
  const sdk = "/var/runtime/node_modules/@aws-sdk";
  const dependencies = {};
  for (const name of fs.readdirSync(sdk).filter((n) => n !== "node_modules").sort()) {
    dependencies[`@aws-sdk/${name}`] = JSON.parse(fs.readFileSync(`${sdk}/${name}/package.json`)).version;
  }
  const pkg = {
    name: "lambda-runtime-sdk",
    private: true,
    description: `The @aws-sdk packages ${process.argv[1]} ships, at its versions`,
    dependencies,
  };
  process.stdout.write(JSON.stringify(pkg, null, 2) + "\n");
' "$digest" > "$dir/package.json"

docker run --rm -i --platform linux/arm64 --entrypoint /bin/sh "$digest" -c '
  export PATH=/var/lang/bin:$PATH
  mkdir /tmp/sdk && cd /tmp/sdk && cat > package.json
  npm install --package-lock-only --ignore-scripts --no-audit --no-fund --loglevel=error >&2
  cat package-lock.json
' < "$dir/package.json" > "$dir/package-lock.json.new"
mv "$dir/package-lock.json.new" "$dir/package-lock.json"
echo "$digest: $(grep -c '"@aws-sdk/' "$dir/package.json") packages"
