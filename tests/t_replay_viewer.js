"use strict";

const assert=require("node:assert/strict");
const zlib=require("node:zlib");
const replay=require("../game/client/replay_viewer.js");

function u16(value){
  const bytes=Buffer.alloc(2);
  bytes.writeUInt16LE(value);
  return bytes;
}

function u32(value){
  const bytes=Buffer.alloc(4);
  bytes.writeUInt32LE(value);
  return bytes;
}

const packets=[Buffer.from([5,0,32,0,32,0]),Buffer.from([4])];
const raw=Buffer.concat([
  Buffer.from(replay.MAGIC),u16(replay.VERSION),u16(24),u32(2),
  u32(0),u32(packets[0].length),packets[0],
  u32(24),u32(packets[1].length),packets[1],
]);

async function main(){
  const decoded=await replay.decode(zlib.deflateSync(raw));
  assert.equal(decoded.tickRate,24);
  assert.equal(decoded.durationTicks,24);
  assert.deepEqual([...decoded.frames[0].packet],[...packets[0]]);
  assert.deepEqual([...decoded.frames[1].packet],[...packets[1]]);
  assert.throws(()=>replay.parse(raw.subarray(0,raw.length-1)),/truncated/);
  await assert.rejects(replay.decode(Buffer.from("not zlib")),/not zlib/);
  console.log("t_replay_viewer ok");
}

main();
