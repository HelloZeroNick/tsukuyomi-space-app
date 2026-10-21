// Policy and behavioural cases have one source; Dart must match every JS plan.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
const require = createRequire(import.meta.url);
const engine = require(path.join(root, 'shared/room-dialogue.cjs'));
const suite = JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/room-dialogue-cases.json'), 'utf8'));
fs.writeFileSync('test/fixtures/room_dialogue_web.json', JSON.stringify({
  version: engine.policy.version, now: suite.now,
  cases: suite.cases.map(item => ({ ...item, expected: engine.plan({ ...item.input, now: suite.now }) }))
}, null, 2) + '\n');
console.log(`${suite.cases.length} dialogue contracts synchronized.`);
