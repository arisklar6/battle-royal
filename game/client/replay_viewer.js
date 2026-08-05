(function(root){
"use strict";

const MAGIC="ZERO_SUM_FRAMES",VERSION=1;

// Decompression bounds. A measured full-length match (9120 ticks, the hard
// cap) is 5.26 MiB compressed and 38.3 MiB raw, so these leave ~12x and ~5x
// headroom while still refusing a zip bomb before it takes the tab down.
const MAX_COMPRESSED_BYTES=64*1024*1024;
const MAX_INFLATED_BYTES=192*1024*1024;

function u16(view,offset){return view.getUint16(offset,true)}
function u32(view,offset){return view.getUint32(offset,true)}

function parse(raw){
  const bytes=raw instanceof Uint8Array?raw:new Uint8Array(raw);
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  let offset=0;
  if(bytes.length<MAGIC.length+8)throw new Error("truncated Zero Sum replay");
  for(let i=0;i<MAGIC.length;i++){
    if(bytes[i]!==MAGIC.charCodeAt(i))throw new Error("not a Zero Sum replay");
  }
  offset+=MAGIC.length;
  const version=u16(view,offset);offset+=2;
  if(version!==VERSION)throw new Error("unsupported Zero Sum replay version "+version);
  const tickRate=u16(view,offset);offset+=2;
  if(tickRate!==24)throw new Error("unsupported Zero Sum replay tick rate "+tickRate);
  const frameCount=u32(view,offset);offset+=4;
  if(frameCount===0||frameCount>100000)throw new Error("invalid Zero Sum replay frame count");
  const frames=[];
  let previousTick=0;
  for(let i=0;i<frameCount;i++){
    if(offset+8>bytes.length)throw new Error("truncated Zero Sum replay frame");
    const tick=u32(view,offset);offset+=4;
    const length=u32(view,offset);offset+=4;
    if(i>0&&tick<previousTick)throw new Error("out-of-order Zero Sum replay frame");
    if(offset+length>bytes.length)throw new Error("truncated Zero Sum replay packet");
    // subarray, not slice: a view costs nothing and the frames keep the
    // inflated buffer alive anyway, so copying would double peak memory.
    frames.push({tick,packet:bytes.subarray(offset,offset+length)});
    previousTick=tick;
    offset+=length;
  }
  if(offset!==bytes.length)throw new Error("trailing Zero Sum replay bytes");
  return {tickRate,frames,durationTicks:frames[frames.length-1].tick};
}

async function inflate(artifact){
  const bytes=artifact instanceof Uint8Array?artifact:new Uint8Array(artifact);
  if(bytes.length>MAX_COMPRESSED_BYTES){
    throw new Error("Zero Sum replay is too large: "+bytes.length+" bytes");
  }
  if(bytes.length<2||(bytes[0]&15)!==8||((bytes[0]<<8)+bytes[1])%31!==0){
    throw new Error("Zero Sum replay is not zlib-compressed");
  }
  // Read the inflated stream chunk by chunk so a crafted artifact cannot
  // expand without bound before we ever look at its contents.
  const reader=new Blob([bytes]).stream()
    .pipeThrough(new DecompressionStream("deflate")).getReader();
  const chunks=[];
  let total=0;
  for(;;){
    const {done,value}=await reader.read();
    if(done)break;
    total+=value.byteLength;
    if(total>MAX_INFLATED_BYTES){
      await reader.cancel();
      throw new Error("Zero Sum replay expands past the "+MAX_INFLATED_BYTES+
        " byte limit");
    }
    chunks.push(value);
  }
  const inflated=new Uint8Array(total);
  let offset=0;
  for(const chunk of chunks){
    inflated.set(chunk,offset);
    offset+=chunk.byteLength;
  }
  return inflated;
}

async function decode(artifact){return parse(await inflate(artifact))}

async function load(url){
  const response=await fetch(url,{credentials:"omit",mode:"cors"});
  if(!response.ok)throw new Error("replay download failed: HTTP "+response.status);
  const declared=Number(response.headers.get("content-length"));
  if(Number.isFinite(declared)&&declared>MAX_COMPRESSED_BYTES){
    throw new Error("Zero Sum replay is too large: "+declared+" bytes");
  }
  return decode(await response.arrayBuffer());
}

const api={MAGIC,VERSION,MAX_COMPRESSED_BYTES,MAX_INFLATED_BYTES,
  parse,inflate,decode,load};
root.ZeroSumPresentationReplay=api;
if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof globalThis!=="undefined"?globalThis:this);
