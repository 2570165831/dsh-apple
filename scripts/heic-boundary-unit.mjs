import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
let inputs=0, outputs=0, outputCodecs=0;
for (const face of ['host','remote-client']) {
 for (const [pkg,method] of [['dsh-api-session-controller','prompt'],['dsh-commands','execute'],['dsh-subagent','prompt']]) {
  const module=await import(pathToFileURL(resolve(`payload/node_modules/@deepseek-ai/${pkg}/lib/typert.${face}.js`)));
  const invocations=module.TYPERT?.invocations ?? module.TYPERT_REMOTE.descriptors;
  const d=invocations.find(x=>x.method===method);
  const param=d.parameters.find(x=>x.name==='request'||x.name==='submittedAttachments');
  for (const codec of [param.codec,param.strictCodec]) {
   for (const type of ['image/heic','image/heif','image/svg+xml']) {
    const image={type:'image',mediaType:type,data:'AA=='};
    const value=pkg==='dsh-commands'?[image]:pkg==='dsh-subagent'?{requestId:'r',parentSessionId:'p',childSessionId:'c',mode:'continuable',delivery:'queue',content:[image]}:{requestId:'r',sessionId:'s',mode:'queue',content:[image]};
    assert.equal(codec.create().safeParse(value).success,type!=='image/svg+xml',`${pkg}/${face} ${type}`); inputs++;
   }
  }
  if (pkg==='dsh-api-session-controller') {
   const output=invocations.find(x=>x.method==='attachment').result.spec;
   assert.deepEqual(output.jsonSchema.properties.attachment.properties.mediaType.enum,
    ['image/png','image/jpeg','image/webp','image/gif']); outputs++;
   for (const mediaType of ['image/jpeg','image/heic','image/svg+xml']) {
    const stored={attachment:{attachmentId:'a',mediaType,bytes:1,width:1,height:1},data:'AA=='};
    assert.equal(output.create().safeParse(stored).success,mediaType==='image/jpeg'); outputCodecs++;
   }
  }
 }
}
console.log(`${inputs} runtime HEIC/HEIF/SVG input checks, ${outputCodecs} stored-image codec checks and ${outputs} output enums passed`);
