import assert from 'node:assert/strict';
import { continueCommand, continueProvider, continueLink } from '../src/app/chat/continue.ts';

// task R9A2: 「在终端里继续」 types ONE command, built from what the home said —
// a session id of the expected shape and an absolute directory, quoted.
assert.equal(continueCommand('claude', '5b1e0000-0000-4000-8000-0000000000a1', '/Users/lin xiao'),
  "bash ~/.claude/fleet/bin/fleet-webchat-handoff.sh to-terminal --agent claude --sid 5b1e0000-0000-4000-8000-0000000000a1 && cd '/Users/lin xiao' && fleet run claude --resume 5b1e0000-0000-4000-8000-0000000000a1");
assert.equal(continueCommand('codex', '01a15e12-ec43-7222-9fbc-6b6b19f3835a', "/Users/o'neil"),
  "bash ~/.claude/fleet/bin/fleet-webchat-handoff.sh to-terminal --agent codex --sid 01a15e12-ec43-7222-9fbc-6b6b19f3835a && cd '/Users/o'\\''neil' && fleet run codex resume 01a15e12-ec43-7222-9fbc-6b6b19f3835a");
assert.equal(continueCommand('claude', 'x; rm -rf ~', '/Users/a'), null, 'an id of another shape is refused');
assert.equal(continueCommand('codex', 'abc', 'relative/dir'), null, 'a relative directory is refused');
assert.equal(continueCommand('codex', 'abc', '/a\nb'), null, 'a newline in the directory is refused');
assert.equal(continueProvider('codex'), 'codex');
assert.equal(continueProvider('gemini'), null);
assert.equal(continueProvider(null), null);
assert.equal(continueLink('codex'), '/terminal?continue=codex');
console.log('chat-continue: ok');
