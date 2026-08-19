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

  // frames are views into one inflated buffer, never per-frame copies
  assert.equal(decoded.frames[0].packet.buffer,
               decoded.frames[1].packet.buffer);

  // an oversized artifact is refused before any decompression work
  await assert.rejects(
    replay.inflate(new Uint8Array(replay.MAX_COMPRESSED_BYTES+1)),
    /too large/);

  // a zip bomb is cut off at the inflated ceiling rather than taking the tab
  const bomb=zlib.deflateSync(Buffer.alloc(replay.MAX_INFLATED_BYTES+1024));
  assert.ok(bomb.length<1024*1024,"bomb fixture should be tiny compressed");
  await assert.rejects(replay.inflate(bomb),/expands past/);

  // a legacy-magic artifact (recorded before the Zero Sum -> Battle Royal
  // rename) still decodes
  const legacyRaw=Buffer.concat([
    Buffer.from(replay.LEGACY_MAGIC),u16(replay.VERSION),u16(24),u32(2),
    u32(0),u32(packets[0].length),packets[0],
    u32(24),u32(packets[1].length),packets[1],
  ]);
  const legacyDecoded=await replay.decode(zlib.deflateSync(legacyRaw));
  assert.equal(legacyDecoded.tickRate,24);
  assert.equal(legacyDecoded.durationTicks,24);
  assert.deepEqual([...legacyDecoded.frames[0].packet],[...packets[0]]);
  assert.deepEqual([...legacyDecoded.frames[1].packet],[...packets[1]]);
  assert.throws(
    ()=>replay.parse(Buffer.from("NEITHER_MAGIC_MATCHES_THIS_LONG_HEADER")),
    /not a Battle Royal replay/);

  console.log("t_replay_viewer ok");
}

main();
