// Moves an `npm ci` of this directory into the managed runtime's layout under OUT: the packages
// package.json depends on as OUT/@aws-sdk/<name>, and everything else npm installed beside them
// as OUT/@aws-sdk/node_modules/<name>. Every package then resolves its dependencies to the same
// copies as in npm's tree.
import { mkdirSync, readFileSync, readdirSync, renameSync } from 'node:fs';
const [dir, out] = process.argv.slice(2);
const nm = `${dir}/node_modules`;
const deps = `${out}/@aws-sdk/node_modules`;
const { dependencies } = JSON.parse(readFileSync(`${dir}/package.json`, 'utf8'));
mkdirSync(`${deps}/@aws-sdk`, { recursive: true });
for (const name of Object.keys(dependencies)) renameSync(`${nm}/${name}`, `${out}/${name}`);
for (const name of readdirSync(`${nm}/@aws-sdk`)) renameSync(`${nm}/@aws-sdk/${name}`, `${deps}/@aws-sdk/${name}`);
for (const entry of readdirSync(nm)) {
  if (entry !== '@aws-sdk' && entry !== '.package-lock.json') renameSync(`${nm}/${entry}`, `${deps}/${entry}`);
}
