(function(root){
"use strict";

const MAGIC="ZERO_SUM_FRAMES",VERSION=1;

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
    frames.push({tick,packet:bytes.slice(offset,offset+length)});
    previousTick=tick;
    offset+=length;
  }
  if(offset!==bytes.length)throw new Error("trailing Zero Sum replay bytes");
  return {tickRate,frames,durationTicks:frames[frames.length-1].tick};
}

async function inflate(artifact){
  const bytes=artifact instanceof Uint8Array?artifact:new Uint8Array(artifact);
  if(bytes.length<2||(bytes[0]&15)!==8||((bytes[0]<<8)+bytes[1])%31!==0){
    throw new Error("Zero Sum replay is not zlib-compressed");
  }
  const stream=new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function decode(artifact){return parse(await inflate(artifact))}

async function load(url){
  const response=await fetch(url,{credentials:"omit",mode:"cors"});
  if(!response.ok)throw new Error("replay download failed: HTTP "+response.status);
  return decode(await response.arrayBuffer());
}

const api={MAGIC,VERSION,parse,inflate,decode,load};
root.ZeroSumPresentationReplay=api;
if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof globalThis!=="undefined"?globalThis:this);
